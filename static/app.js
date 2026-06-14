/* Workload Inspector — aggregator dashboard renderer.
 *
 * Loads data/instances.json (written by the in-cluster discovery loop), then
 * fetches each instance's probe document from data/instances/<id>.json. If the
 * index is absent — e.g. this page is served directly by a standalone probe pod
 * rather than the dashboard — it falls back to the pod's own data/probe.json and
 * renders that single instance.
 */

const state = {
    instances: [],   // [{ id, variant, meta, probe, error }]
    selectedId: null,
};

document.addEventListener("DOMContentLoaded", init);

async function init() {
    try {
        const index = await fetchJSON("data/instances.json");
        if (Array.isArray(index) && index.length > 0) {
            await loadFromIndex(index);
        } else {
            await loadStandalone();
        }
    } catch (e) {
        // No index served → behave as a single probe pod.
        await loadStandalone();
    }

    if (state.instances.length === 0) {
        document.getElementById("detail").innerHTML =
            `<div class="error-banner">No workload instances found. ` +
            `If you deployed the dashboard, give the discovery loop a few seconds ` +
            `and refresh; otherwise check that probe pods are Running.</div>`;
        return;
    }

    state.selectedId = pickDefault(state.instances);
    renderCompareStrip();
    renderSelected();
}

/* ── data loading ───────────────────────────────────── */

async function loadFromIndex(index) {
    const results = await Promise.all(index.map(async (entry) => {
        const inst = { id: entry.id, variant: entry.variant || entry.id, meta: entry, probe: null, error: null };
        if (entry.ok === false) {
            inst.error = "Probe unreachable" + (entry.phase ? ` (pod ${entry.phase})` : "");
            return inst;
        }
        try {
            inst.probe = await fetchJSON(`data/instances/${encodeURIComponent(entry.id)}.json`);
        } catch (e) {
            inst.error = `Could not load probe data (${e.message})`;
        }
        return inst;
    }));
    state.instances = results;
    setTimestamp(results.map(r => r.probe).filter(Boolean));
}

async function loadStandalone() {
    try {
        const probe = await fetchJSON("data/probe.json");
        const variant = (probe.runtime && probe.runtime.runtimeClassHint &&
                         probe.runtime.runtimeClassHint !== "not injected")
            ? probe.runtime.runtimeClassHint
            : (probe.identity && probe.identity.podName) || "this pod";
        state.instances = [{
            id: "self", variant,
            meta: { id: "self", variant, podName: probe.identity && probe.identity.podName,
                    node: probe.identity && probe.identity.nodeName,
                    phase: "Running", ok: true },
            probe, error: null,
        }];
        setTimestamp([probe]);
    } catch (e) {
        state.instances = [];
    }
}

function fetchJSON(url) {
    return fetch(url, { cache: "no-store" }).then((r) => {
        if (!r.ok) throw new Error(r.status);
        return r.json();
    });
}

function setTimestamp(probes) {
    const stamps = probes.map(p => p && p.probeTimestamp).filter(Boolean).sort();
    const latest = stamps[stamps.length - 1];
    if (latest) {
        document.getElementById("timestamp").textContent =
            `probed ${new Date(latest).toLocaleString()}`;
    }
    const v = probes.find(p => p && p.probeVersion);
    document.getElementById("probe-version").textContent =
        v ? `probe ${v.probeVersion}` : "";
}

/* ── verdict computation ────────────────────────────── */

// Map a raw TEE type string to a short, friendly label.
function teeLabel(type) {
    if (!type || type === "none") return "";
    if (/Intel TDX/i.test(type)) return "Intel TDX";
    if (/SNP/i.test(type)) return "AMD SEV-SNP";
    if (/SEV/i.test(type)) return "AMD SEV";
    return type;
}

// Compute the per-instance verdict from its probe document.
function computeVerdict(probe) {
    const rt = probe.runtime || {};
    const tee = probe.tee || {};
    const gpu = probe.gpu || {};
    const att = probe.attestation || {};
    const gpuCC = !!gpu.present && gpu.ccMode === "on";

    let color, headline;
    if (tee.detected && gpuCC) {
        color = "green"; headline = "Confidential VM + confidential GPU";
    } else if (tee.detected) {
        color = "green"; headline = "Confidential VM — " + (teeLabel(tee.type) || "hardware TEE");
    } else if (gpuCC) {
        color = "green"; headline = "Confidential GPU";
    } else if (rt.kataDetected) {
        color = "amber"; headline = "Sandboxed VM (kata) — no hardware TEE";
    } else if (rt.inVM) {
        color = "amber"; headline = "Virtualized — no hardware TEE";
    } else {
        color = "gray"; headline = "Standard container — no isolation";
    }

    let sub = "";
    if (att.detected) sub = "attestation configured";

    return { color, headline, sub, attested: !!att.detected, gpuCC };
}

// Pick the "most confidential" instance to select by default.
function pickDefault(instances) {
    const rank = (inst) => {
        if (!inst.probe) return -1;
        const v = computeVerdict(inst.probe);
        let r = 0;
        if (v.color === "green") r = 3;
        else if (v.color === "amber") r = 1;
        if (v.gpuCC && (inst.probe.tee || {}).detected) r += 1; // VM + GPU beats VM only
        if (v.attested) r += 0.5;
        return r;
    };
    let best = instances[0];
    let bestRank = rank(best);
    for (const inst of instances) {
        const r = rank(inst);
        if (r > bestRank) { best = inst; bestRank = r; }
    }
    return best.id;
}

/* ── comparison strip ───────────────────────────────── */

function renderCompareStrip() {
    if (state.instances.length <= 1) {
        document.getElementById("compare").hidden = true;
        return;
    }
    document.getElementById("compare").hidden = false;
    const strip = document.getElementById("compare-strip");
    strip.innerHTML = "";

    for (const inst of state.instances) {
        const chip = document.createElement("button");
        chip.className = "chip" + (inst.id === state.selectedId ? " selected" : "") +
            (inst.probe ? "" : " unreachable");
        chip.type = "button";

        let color = "gray", verdictText = "Unavailable";
        if (inst.probe) {
            const v = computeVerdict(inst.probe);
            color = v.color;
            verdictText = v.headline;
        }
        const node = inst.meta && inst.meta.node ? inst.meta.node : "";

        chip.innerHTML =
            `<span class="chip-dot pill-${color}" style="background:var(--${dotColor(color)})"></span>` +
            `<span class="chip-body">` +
            `<span class="chip-name">${esc(inst.variant)}</span>` +
            `<span class="chip-meta">${esc(node || verdictText)}</span>` +
            `</span>` +
            `<span class="pill pill-${color}">${esc(shortVerdict(color, inst.probe))}</span>`;

        chip.addEventListener("click", () => {
            state.selectedId = inst.id;
            renderCompareStrip();
            renderSelected();
            document.getElementById("detail").scrollIntoView({ behavior: "smooth", block: "nearest" });
        });
        strip.appendChild(chip);
    }
}

function dotColor(color) {
    return { green: "green", amber: "amber", red: "red", blue: "blue", gray: "text-faint" }[color] || "text-faint";
}

function shortVerdict(color, probe) {
    if (!probe) return "Offline";
    const tee = probe.tee || {};
    const gpu = probe.gpu || {};
    if (tee.detected && gpu.present && gpu.ccMode === "on") return "Confidential + GPU";
    if (tee.detected) return teeLabel(tee.type) || "Confidential";
    if (gpu.present && gpu.ccMode === "on") return "Confidential GPU";
    if ((probe.runtime || {}).kataDetected) return "Sandboxed";
    if ((probe.runtime || {}).inVM) return "Virtualized";
    return "Standard";
}

/* ── selected instance view ─────────────────────────── */

function renderSelected() {
    const inst = state.instances.find(i => i.id === state.selectedId) || state.instances[0];
    const root = document.getElementById("detail");

    if (!inst.probe) {
        root.innerHTML =
            `<div class="error-banner">${esc(inst.variant)}: ${esc(inst.error || "no probe data")}.</div>`;
        return;
    }

    const d = inst.probe;
    const v = computeVerdict(d);

    root.innerHTML =
        verdictBanner(v) +
        statusStrip(d) +
        `<div class="cards">` +
        cardIdentity(d.identity) +
        cardRuntime(d.runtime) +
        cardExecution(d.executionMode) +
        cardTEE(d.tee) +
        cardGPU(d.gpu) +
        cardAttestation(d.attestation) +
        `</div>`;
}

function verdictBanner(v) {
    const sub = v.sub ? `<div class="verdict-sub">${esc(v.sub)}</div>` : "";
    return `<div class="verdict ${v.color}">
        <div class="verdict-line">
            <span class="verdict-headline">${esc(v.headline)}</span>
            ${v.attested ? `<span class="pill pill-blue">Attested</span>` : ""}
        </div>${sub}</div>`;
}

function statusStrip(d) {
    const rt = d.runtime || {}, em = d.executionMode || {}, tee = d.tee || {},
          gpu = d.gpu || {}, att = d.attestation || {};

    const runtime = rt.kataDetected
        ? { v: "Kata", c: "blue" }
        : rt.inVM ? { v: "VM", c: "amber" } : { v: "Standard", c: "gray" };

    const exec = em.mode === "peer-pod"
        ? { v: "Peer pod" + (em.cloudProvider && em.cloudProvider !== "none" ? ` (${em.cloudProvider.toUpperCase()})` : ""), c: "blue" }
        : em.mode === "on-node" ? { v: "On-node", c: "amber" } : { v: "Standard", c: "gray" };

    const cpuTee = tee.detected
        ? { v: teeLabel(tee.type) || "Active", c: "green" }
        : { v: "None", c: "gray" };

    const gpuTee = !gpu.present
        ? { v: "No GPU", c: "gray" }
        : gpu.ccMode === "on" ? { v: "GPU CC on", c: "green" }
        : gpu.ccMode === "off" ? { v: "GPU CC off", c: "amber" }
        : { v: "GPU CC unknown", c: "amber" };

    const attest = att.detected
        ? { v: "Configured", c: "blue" } : { v: "None", c: "gray" };

    return `<div class="status-strip">
        ${statusChip("Runtime", runtime)}
        ${statusChip("Execution", exec)}
        ${statusChip("CPU TEE", cpuTee)}
        ${statusChip("GPU TEE", gpuTee)}
        ${statusChip("Attestation", attest)}
    </div>`;
}

function statusChip(label, s) {
    return `<span class="status-chip ${s.c}">
        <span class="sc-label">${esc(label)}</span>
        <span class="sc-value">${esc(s.v)}</span></span>`;
}

/* ── cards ──────────────────────────────────────────── */

function card(title, icon, pill, body, cls) {
    return `<div class="card${cls ? " " + cls : ""}">
        <div class="card-header">
            <span class="card-title"><span class="ic">${icon}</span>${esc(title)}</span>
            ${pill || ""}
        </div>
        <div class="card-body">${body}</div></div>`;
}

function field(label, value, cls) {
    const v = (value === undefined || value === null || value === "") ? "—" : value;
    return `<div class="field">
        <span class="field-label">${esc(label)}</span>
        <span class="field-value${cls ? " " + cls : ""}">${esc(v)}</span></div>`;
}

function pill(text, color) {
    return `<span class="pill pill-${color}">${esc(text)}</span>`;
}

function yn(b) { return b ? "Yes" : "No"; }
function presence(b) { return b ? "Present" : "Not found"; }

function cardIdentity(id) {
    if (!id) return "";
    return card("Pod identity", "&#x1f4e6;", "", [
        field("Hostname", id.hostname, "mono"),
        field("Pod", id.podName, "mono"),
        field("Namespace", id.namespace),
        field("Node", id.nodeName, "mono"),
        field("Pod IP", id.podIP, "mono"),
        field("Service account", id.serviceAccount),
        field("Kernel", id.kernel, "mono"),
    ].join(""));
}

function cardRuntime(rt) {
    if (!rt) return "";
    const p = rt.kataDetected ? pill("Kata", "blue")
        : rt.inVM ? pill("Virtualized", "amber") : pill("Standard", "gray");

    let note;
    if (rt.runtimeClassHint && rt.runtimeClassHint !== "not injected") {
        note = `<div class="note">Runtime class (Downward API): <code>${esc(rt.runtimeClassHint)}</code></div>`;
    } else {
        note = `<div class="note">Set <code>RUNTIME_CLASS</code> via the Downward API to surface the runtime class name here.</div>`;
    }

    return card("Runtime", "&#x2699;&#xfe0f;", p, [
        field("In VM", yn(rt.inVM), rt.inVM ? "amber" : "dim"),
        field("Kata detected", yn(rt.kataDetected), rt.kataDetected ? "blue" : "dim"),
        field("Hypervisor flag", rt.hypervisorFlag || "—"),
        field("DMI vendor", rt.dmiVendor, "mono"),
        field("DMI product", rt.dmiProduct, "mono"),
        field("Board", rt.dmiBoardName, "mono"),
        field("Kata evidence", rt.kataEvidence),
        note,
    ].join(""));
}

function cardExecution(em) {
    if (!em) return "";
    let p, modeLabel;
    switch (em.mode) {
        case "peer-pod": p = pill("Peer pod", "blue"); modeLabel = "Peer pod (cloud VM)"; break;
        case "on-node":  p = pill("On-node", "amber"); modeLabel = "On-node kata VM"; break;
        default:         p = pill("Standard", "gray"); modeLabel = "Standard container";
    }

    let cloud = "";
    if (em.cloudProvider === "gcp" && em.gcp) {
        cloud = [
            field("Machine type", em.gcp.machineType, "blue"),
            field("Zone", em.gcp.zone, "mono"),
            field("Instance name", em.gcp.instanceName, "mono"),
            field("Instance ID", em.gcp.instanceId, "mono"),
            field("Project", em.gcp.project, "mono"),
        ].join("");
    } else if (em.cloudProvider === "aws" && em.aws) {
        cloud = [
            field("Instance type", em.aws.instanceType, "blue"),
            field("Availability zone", em.aws.availabilityZone, "mono"),
            field("Instance ID", em.aws.instanceId, "mono"),
        ].join("");
    } else if (em.cloudProvider === "azure" && em.azure) {
        cloud = [
            field("VM size", em.azure.vmSize, "blue"),
            field("Location", em.azure.location, "mono"),
            field("VM ID", em.azure.vmId, "mono"),
        ].join("");
    }

    return card("Execution mode", "&#x1f5fa;&#xfe0f;", p, [
        field("Mode", modeLabel),
        field("Cloud provider", em.cloudProvider && em.cloudProvider !== "none"
            ? em.cloudProvider.toUpperCase() : "None"),
        cloud,
    ].join(""));
}

function cardTEE(t) {
    if (!t) return "";
    const p = t.detected ? pill(teeLabel(t.type) || "Active", "green") : pill("Not detected", "gray");
    return card("CPU TEE", "&#x1f512;", p, [
        field("TEE detected", yn(t.detected), t.detected ? "green" : "dim"),
        field("TEE type", t.type !== "none" ? teeLabel(t.type) || t.type : "—", t.detected ? "green" : ""),
        field("Evidence", t.evidence),
        field("/dev/tdx_guest", presence(t.devices && t.devices.tdxGuest), (t.devices && t.devices.tdxGuest) ? "green" : "dim"),
        field("/dev/sev-guest", presence(t.devices && t.devices.sevGuest), (t.devices && t.devices.sevGuest) ? "green" : "dim"),
        field("CoCo secrets dir", presence(t.cocoSecrets), t.cocoSecrets ? "green" : "dim"),
        field("CC event log", presence(t.ccEventLog), t.ccEventLog ? "green" : "dim"),
        field("Memory encryption", t.memEncryption),
        field("CPU model", t.cpuModel, "mono"),
        t.cmdlineCC ? field("Cmdline CC params", t.cmdlineCC, "mono") : "",
    ].join(""));
}

function cardGPU(g) {
    if (!g) return "";
    let p;
    if (!g.present) p = pill("No GPU", "gray");
    else if (g.ccMode === "on") p = pill("CC on", "green");
    else if (g.ccMode === "off") p = pill("CC off", "amber");
    else p = pill("CC unknown", "amber");

    if (!g.present) {
        return card("GPU TEE", "&#x1f9ee;", p,
            `<div class="empty">No NVIDIA GPU detected on this workload.</div>`, "accent");
    }

    const ccLabel = g.ccMode === "on" ? "On" : g.ccMode === "off" ? "Off" : "Unknown";
    const ccCls = g.ccMode === "on" ? "green" : g.ccMode === "off" ? "amber" : "amber";
    const dev = g.devices || {};

    return card("GPU TEE", "&#x1f9ee;", p, [
        field("GPU present", yn(g.present), "green"),
        field("Vendor", g.vendor),
        field("Model", g.model, "mono"),
        field("Count", g.count != null ? String(g.count) : "—"),
        field("Confidential mode", ccLabel, ccCls),
        field("Driver version", g.driverVersion, "mono"),
        field("/dev/nvidia0", presence(dev.nvidia0), dev.nvidia0 ? "green" : "dim"),
        field("/dev/nvidiactl", presence(dev.nvidiactl), dev.nvidiactl ? "green" : "dim"),
        field("/dev/nvidia-uvm", presence(dev.nvidiaUvm), dev.nvidiaUvm ? "green" : "dim"),
        field("/dev/nvidia-caps", presence(dev.nvidiaCaps), dev.nvidiaCaps ? "green" : "dim"),
        field("CC evidence", g.ccEvidence),
    ].join(""), "accent");
}

function cardAttestation(a) {
    if (!a) return "";
    const p = a.detected ? pill("Configured", "blue") : pill("Not found", "gray");
    return card("Attestation", "&#x1f4dc;", p, [
        field("Attestation detected", yn(a.detected), a.detected ? "blue" : "dim"),
        field("KBC type", a.kbcType, a.kbcType ? "blue" : ""),
        field("KBS URL", a.kbsUrl, a.kbsUrl ? "mono" : ""),
        field("AA KBC params", a.kbcParams, "mono"),
        field("CDH socket", presence(a.cdhSocket), a.cdhSocket ? "green" : "dim"),
        field("CDH config", a.cdhConfigPath || "Not found", a.cdhConfigPath ? "mono" : "dim"),
        field("Initdata", presence(a.initdataPresent), a.initdataPresent ? "green" : "dim"),
        field("AA process", a.aaProcess ? "Running" : "Not seen", a.aaProcess ? "green" : "dim"),
        field("CDH process", a.cdhProcess ? "Running" : "Not seen", a.cdhProcess ? "green" : "dim"),
    ].join(""));
}

/* ── util ───────────────────────────────────────────── */

function esc(s) {
    return String(s).replace(/[&<>"']/g, (c) => ({
        "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
    }[c]));
}
