/* Workload Inspector — dashboard renderer */

document.addEventListener("DOMContentLoaded", () => {
    fetch("data/probe.json")
        .then(r => { if (!r.ok) throw new Error(r.status); return r.json(); })
        .then(render)
        .catch(err => {
            document.getElementById("dashboard").innerHTML =
                `<div class="error-banner">Failed to load probe data: ${err.message}</div>`;
        });
});

function render(d) {
    document.getElementById("timestamp").textContent =
        `probed ${new Date(d.probeTimestamp).toLocaleString()}`;
    document.getElementById("probe-version").textContent = `probe ${d.probeVersion || "?"}`;
    document.getElementById("dashboard").innerHTML = [
        cardIdentity(d.identity),
        cardRuntime(d.runtime),
        cardExecution(d.executionMode),
        cardTEE(d.tee),
        cardAttestation(d.attestation),
    ].join("");
}

/* ── helpers ─────────────────────────────────────────── */

function card(title, badge, body, cls) {
    return `<div class="card${cls ? " " + cls : ""}">
        <div class="card-header">
            <span class="card-title">${title}</span>${badge}
        </div>
        <div class="card-body">${body}</div></div>`;
}

function field(label, value, cls) {
    const v = value || "—";
    return `<div class="field">
        <span class="field-label">${label}</span>
        <span class="field-value${cls ? " " + cls : ""}">${v}</span></div>`;
}

function badge(text, color) {
    return `<span class="badge badge-${color}">${text}</span>`;
}

/* ── cards ───────────────────────────────────────────── */

function cardIdentity(id) {
    if (!id) return "";
    return card("Pod Identity", "", [
        field("Hostname", id.hostname, "mono"),
        field("Pod", id.podName, "mono"),
        field("Namespace", id.namespace, "highlight"),
        field("Node", id.nodeName, "mono"),
        field("Pod IP", id.podIP, "mono"),
        field("Service Account", id.serviceAccount),
        field("Kernel", id.kernel, "mono"),
    ].join(""));
}

function cardRuntime(rt) {
    if (!rt) return "";
    const inVM = rt.inVM;
    const kata = rt.kataDetected;
    let b;
    if (kata) b = badge("KATA", "green");
    else if (inVM) b = badge("VM", "cyan");
    else b = badge("STANDARD", "purple");

    let note = "";
    if (rt.runtimeClassHint && rt.runtimeClassHint !== "not injected") {
        note = `<div class="section-note">Runtime class from Downward API: <strong>${rt.runtimeClassHint}</strong></div>`;
    } else {
        note = `<div class="section-note">Set <code>RUNTIME_CLASS</code> env via Downward API to show the runtime class name here.</div>`;
    }

    return card("Runtime Environment", b, [
        field("In VM", inVM ? "Yes" : "No", inVM ? "success" : ""),
        field("Kata Detected", kata ? "Yes" : "No", kata ? "success" : ""),
        field("Hypervisor Flag", rt.hypervisorFlag || "—"),
        field("DMI Vendor", rt.dmiVendor || "—", "mono"),
        field("DMI Product", rt.dmiProduct || "—", "mono"),
        field("Board", rt.dmiBoardName || "—", "mono"),
        field("Kata Evidence", rt.kataEvidence || "—"),
        field("Runtime Class", rt.runtimeClassHint, rt.runtimeClassHint !== "not injected" ? "highlight" : ""),
        note,
    ].join(""));
}

function cardExecution(em) {
    if (!em) return "";
    let b, modeLabel;
    switch (em.mode) {
        case "peer-pod":
            b = badge("PEER POD", "cyan");
            modeLabel = "Peer Pod (cloud VM)";
            break;
        case "on-node":
            b = badge("ON-NODE", "green");
            modeLabel = "On-node kata VM";
            break;
        default:
            b = badge("STANDARD", "purple");
            modeLabel = "Standard container";
    }
    let cloudFields = "";
    if (em.cloudProvider === "gcp") {
        cloudFields = [
            field("Machine Type", em.gcp.machineType, "highlight"),
            field("Zone", em.gcp.zone, "mono"),
            field("Instance Name", em.gcp.instanceName, "highlight"),
            field("Instance ID", em.gcp.instanceId, "mono"),
            field("Project", em.gcp.project, "mono"),
        ].join("");
    } else if (em.cloudProvider === "aws") {
        cloudFields = [
            field("Instance Type", em.aws.instanceType, "highlight"),
            field("AZ", em.aws.availabilityZone, "mono"),
            field("Instance ID", em.aws.instanceId, "mono"),
        ].join("");
    } else if (em.cloudProvider === "azure") {
        cloudFields = [
            field("VM Size", em.azure.vmSize, "highlight"),
            field("Location", em.azure.location, "mono"),
            field("VM ID", em.azure.vmId, "mono"),
        ].join("");
    }

    return card("Execution Mode", b, [
        field("Mode", modeLabel),
        field("Cloud Provider", em.cloudProvider !== "none" ? em.cloudProvider.toUpperCase() : "None"),
        cloudFields,
    ].join(""));
}

function cardTEE(t) {
    if (!t) return "";
    let b;
    if (t.detected) {
        if (t.type.includes("TDX")) b = badge("TDX", "green");
        else if (t.type.includes("SNP")) b = badge("SEV-SNP", "green");
        else if (t.type.includes("SEV")) b = badge("SEV", "green");
        else b = badge("ACTIVE", "green");
    } else {
        b = badge("NOT DETECTED", "red");
    }

    return card("Confidential Computing", b, [
        field("TEE Detected", t.detected ? "Yes" : "No", t.detected ? "success" : "danger"),
        field("TEE Type", t.type !== "none" ? t.type : "—", t.type !== "none" ? "highlight" : ""),
        field("Evidence", t.evidence || "—"),
        field("/dev/tdx_guest", t.devices.tdxGuest ? "Present" : "Not found", t.devices.tdxGuest ? "success" : ""),
        field("/dev/sev-guest", t.devices.sevGuest ? "Present" : "Not found", t.devices.sevGuest ? "success" : ""),
        field("CoCo Secrets Dir", t.cocoSecrets ? "Present" : "Not found", t.cocoSecrets ? "success" : ""),
        field("CC Event Log", t.ccEventLog ? "Present" : "Not found", t.ccEventLog ? "success" : ""),
        field("CPU Model", t.cpuModel, "mono"),
        t.cmdlineCC ? field("Cmdline CC Params", t.cmdlineCC) : "",
    ].join(""), "wide");
}

function cardAttestation(a) {
    if (!a) return "";
    const b = a.detected ? badge("CONFIGURED", "green") : badge("NOT FOUND", "amber");

    return card("Attestation", b, [
        field("Attestation Detected", a.detected ? "Yes" : "No", a.detected ? "success" : "warn"),
        field("KBC Type", a.kbcType || "—", a.kbcType ? "highlight" : ""),
        field("KBS URL", a.kbsUrl || "—", a.kbsUrl ? "mono" : ""),
        field("AA KBC Params", a.kbcParams || "—", "mono"),
        field("CDH Socket", a.cdhSocket ? "Present" : "Not found", a.cdhSocket ? "success" : ""),
        field("CDH Config", a.cdhConfigPath || "Not found", a.cdhConfigPath ? "mono" : ""),
        field("Initdata", a.initdataPresent ? "Present" : "Not found", a.initdataPresent ? "success" : ""),
        field("AA Process", a.aaProcess ? "Running" : "Not seen", a.aaProcess ? "success" : ""),
        field("CDH Process", a.cdhProcess ? "Running" : "Not seen", a.cdhProcess ? "success" : ""),
    ].join(""), "wide");
}
