# Workload Inspector

[![Build and Push](https://github.com/makentenza/workload-inspector/actions/workflows/build-push.yaml/badge.svg)](https://github.com/makentenza/workload-inspector/actions/workflows/build-push.yaml)

Nginx-based probe that detects the sandboxing and confidential computing
context of a Kubernetes workload and displays a visual dashboard.

## What it detects

| Category | Details |
|----------|---------|
| **Runtime** | VM detection (hypervisor flag, DMI/SMBIOS), kata agent presence, runtime class |
| **Execution mode** | On-node kata VM vs peer pod (GCP / AWS / Azure metadata) |
| **TEE** | Intel TDX, AMD SEV, AMD SEV-SNP — via devices, ACPI tables, CPU flags, kernel cmdline |
| **Attestation** | KBS URL, KBC type, CDH socket/config, Attestation Agent process, initdata |

## Build

```bash
export IMAGE=quay.io/youruser/workload-inspector
make build
make push
```

## Deploy

Each target creates the namespace, injects the image, and applies the service + route:

```bash
# Standard container (baseline — no kata)
make deploy-standard IMAGE=quay.io/youruser/workload-inspector

# Kata on-node
make deploy-kata IMAGE=quay.io/youruser/workload-inspector

# Peer pods (kata-remote)
make deploy-kata-remote IMAGE=quay.io/youruser/workload-inspector

# Confidential containers (kata-remote with CC)
make deploy-kata-cc IMAGE=quay.io/youruser/workload-inspector

# All four at once
make deploy-all IMAGE=quay.io/youruser/workload-inspector
```

The service selects `app: workload-inspector`, so all variants are reachable
through the same route — the route load-balances across whichever pods are
running. To compare side by side, use `oc port-forward` to each pod individually.

## How it works

1. At container startup, `entrypoint.sh` runs `probe.sh`
2. `probe.sh` inspects `/proc`, `/sys`, `/dev`, cloud metadata endpoints, and
   process lists, then writes a JSON document to `/usr/share/nginx/html/data/probe.json`
3. Nginx serves the static dashboard (`index.html` + `app.js` + `styles.css`)
4. The JavaScript fetches `data/probe.json` and renders the result cards

Probe runs once at startup. Restart the pod for fresh data.

## Project structure

```
├── Containerfile           UBI9-minimal + nginx
├── entrypoint.sh           Runs probe, starts nginx
├── probe.sh                Environment detection → JSON
├── nginx.conf              Serves on :8080, OpenShift-friendly
├── static/
│   ├── index.html          Dashboard shell
│   ├── app.js              Fetch + render logic
│   └── styles.css          Dark-theme dashboard
├── k8s/
│   ├── namespace.yaml
│   ├── deployment-standard.yaml
│   ├── deployment-kata.yaml
│   ├── deployment-kata-remote.yaml
│   ├── deployment-kata-cc.yaml
│   ├── service.yaml
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
