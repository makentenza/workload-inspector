# Workload Inspector

[![Build and Push](https://github.com/makentenza/workload-inspector/actions/workflows/build-push.yaml/badge.svg)](https://github.com/makentenza/workload-inspector/actions/workflows/build-push.yaml)

Nginx-based probe that detects the sandboxing and confidential computing
context of a Kubernetes workload, plus a self-discovering **aggregator
dashboard** that pulls every probe pod's results into one comparison view.

## What it detects

| Category | Details |
|----------|---------|
| **Runtime** | VM detection (hypervisor flag, DMI/SMBIOS), kata agent presence, runtime class |
| **Execution mode** | On-node kata VM vs peer pod (GCP / AWS / Azure metadata) |
| **CPU TEE** | Intel TDX, AMD SEV, AMD SEV-SNP — via devices, ACPI tables, CPU flags, kernel cmdline |
| **GPU TEE** | NVIDIA GPU presence, model, driver, and confidential-compute (CC) mode + device nodes |
| **Attestation** | KBS URL, KBC type, CDH socket/config, Attestation Agent process, initdata |

## Build

```bash
export IMAGE=quay.io/youruser/workload-inspector
make build
make push
```

## Architecture: aggregator + probes

A single image runs in one of two roles, chosen by the `WI_ROLE` env var:

- **`WI_ROLE=probe`** (default) — runs `probe.sh` once at startup, writes its own
  `data/probe.json`, and serves it on `:8080`. One probe pod per runtime variant.
- **`WI_ROLE=dashboard`** — the aggregator. A background loop (`discover.sh`)
  asks the Kubernetes API for sibling probe pods and pulls each one's
  `probe.json` into a combined index that the dashboard renders.

```
            ┌────────────────────── Route / Service (wi-role=dashboard) ─────────┐
            │                                                                     │
            ▼                                                                     │
   ┌──────────────────┐   every ~15s, via in-cluster ServiceAccount              │
   │  dashboard pod   │──── GET /api/v1/.../pods?labelSelector=wi-role=probe ──┐  │
   │  (discover.sh)   │                                                        │  │
   │                  │──── curl http://<podIP>:8080/data/probe.json ──┐       │  │
   └──────────────────┘                                                ▼       ▼  │
        serves:                                            ┌───────────────────────┐
        data/instances.json        ◀───────────────────────│ probe pods            │
        data/instances/<id>.json                           │ standard / kata /     │
                                                            │ kata-remote / kata-cc │
                                                            └───────────────────────┘
```

Only the **dashboard** is exposed through the Route/Service. Probe pods are
reached in-cluster by IP, so a page load shows *all* instances side by side
instead of one random pod behind a load balancer.

### Discovery & RBAC

`discover.sh` uses the dashboard pod's mounted ServiceAccount token
(`/var/run/secrets/kubernetes.io/serviceaccount/`) to call the Kubernetes API.
`k8s/rbac.yaml` grants that SA (`workload-inspector-dashboard`) a namespaced
Role with `get,list,watch` on `pods` — nothing more. For each `Running` probe
pod with a pod IP, it fetches `http://<podIP>:8080/data/probe.json` and writes:

- `data/instances/<id>.json` — one probe document per instance
  (`<id>` = the pod's `wi-variant` label, sanitised; falls back to the pod name)
- `data/instances.json` — an index of `{id, variant, podName, node, phase, ok}`

The loop is resilient: every `curl` has a timeout, individual probe failures
don't abort the sweep, and the index is rewritten on every pass (so unreachable
pods show up as `ok:false` rather than disappearing). `jq` parses the API JSON.

## Deploy

```bash
# Aggregator dashboard + RBAC + Service + Route (deploy this once)
make deploy-dashboard IMAGE=quay.io/youruser/workload-inspector

# Probe variants (each one self-registers via its wi-role=probe label)
make deploy-standard    IMAGE=quay.io/youruser/workload-inspector  # baseline — no kata
make deploy-kata        IMAGE=quay.io/youruser/workload-inspector  # kata on-node
make deploy-kata-remote IMAGE=quay.io/youruser/workload-inspector  # peer pods
make deploy-kata-cc     IMAGE=quay.io/youruser/workload-inspector  # confidential containers

# Dashboard + all four probes at once
make deploy-all IMAGE=quay.io/youruser/workload-inspector
```

The Route now targets the dashboard only (`wi-role=dashboard`). Open it and you
get a comparison strip across every probe variant; click a variant to inspect it.
Probe deployments no longer create their own Service or Route — the dashboard
owns those.

## How it works

1. **Probe pods:** `entrypoint.sh` (with `WI_ROLE=probe`) runs `probe.sh`, which
   inspects `/proc`, `/sys`, `/dev`, cloud metadata endpoints, and process lists,
   then writes `data/probe.json`. Nginx serves it on `:8080`.
2. **Dashboard pod:** `entrypoint.sh` (with `WI_ROLE=dashboard`) starts
   `discover.sh` in the background and serves the static UI. Discovery pulls each
   probe's `probe.json` into `data/instances.json` + `data/instances/<id>.json`.
3. **UI:** `app.js` fetches `data/instances.json`, then each instance's probe,
   computes a plain-English verdict per instance, and renders a comparison strip
   plus six detail cards (Pod identity, Runtime, Execution mode, CPU TEE, GPU TEE,
   Attestation). If `data/instances.json` is absent (e.g. you open a probe pod
   directly), it falls back to that pod's own `data/probe.json` as a single
   instance.

Each probe runs once at its pod's startup; restart a probe pod for fresh data.
The dashboard re-discovers every ~15s (`WI_DISCOVER_INTERVAL`).

## Project structure

```
├── Containerfile           UBI9-minimal + nginx + jq
├── entrypoint.sh           Branches on WI_ROLE: probe vs dashboard
├── probe.sh                Environment detection → JSON (probe role)
├── discover.sh             In-cluster pod discovery loop (dashboard role)
├── nginx.conf              Serves on :8080, OpenShift-friendly
├── static/
│   ├── index.html          Dashboard shell
│   ├── app.js              Fetch + verdict + render logic
│   └── styles.css          Light-theme dashboard
├── k8s/
│   ├── namespace.yaml
│   ├── rbac.yaml                   SA + Role + RoleBinding for the dashboard
│   ├── deployment-dashboard.yaml   Aggregator (WI_ROLE=dashboard)
│   ├── deployment-standard.yaml
│   ├── deployment-kata.yaml
│   ├── deployment-kata-remote.yaml
│   ├── deployment-kata-cc.yaml
│   ├── service.yaml                Targets wi-role=dashboard
│   └── route.yaml
└── Makefile
```

## CI/CD

Pushing to `main` on GitHub automatically builds the container image and pushes
it to `quay.io/makentenza/workload-inspector:latest`.

### Setup (one-time)

1. Create a [Quay.io robot account](https://quay.io/repository/makentenza/workload-inspector?tab=settings)
   with write access to the repository.
2. In your GitHub repo, go to **Settings > Secrets and variables > Actions** and add:
   - `QUAY_USERNAME` — robot account name (e.g. `makentenza+github_ci`)
   - `QUAY_PASSWORD` — robot account token

Pull requests build the image (no push) to catch build failures early.

## Cleanup

```bash
make clean
```
