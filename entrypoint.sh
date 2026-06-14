#!/bin/bash
set -euo pipefail

WEB_ROOT="/usr/share/nginx/html"
DATA_DIR="$WEB_ROOT/data"
WI_ROLE="${WI_ROLE:-probe}"

mkdir -p "$DATA_DIR"

case "$WI_ROLE" in
  dashboard)
    # Aggregator: discover sibling probe pods in-cluster and pull their
    # probe.json documents. Discovery runs in the background; nginx serves the
    # static dashboard plus the aggregated data/instances.json index.
    echo "[workload-inspector] role=dashboard — starting discovery loop"
    mkdir -p "$DATA_DIR/instances"
    # Seed an empty index so the dashboard renders before the first sweep lands.
    [ -f "$DATA_DIR/instances.json" ] || echo '[]' > "$DATA_DIR/instances.json"
    /opt/workload-inspector/discover.sh &

    echo "[workload-inspector] starting nginx on :8080"
    exec nginx -g 'daemon off;'
    ;;

  probe|*)
    # Probe: inspect this pod's own environment once, then serve its result.
    echo "[workload-inspector] role=probe — running environment probe..."
    /opt/workload-inspector/probe.sh > "$DATA_DIR/probe.json" 2>/dev/null || \
        echo '{"error":"probe failed","probeTimestamp":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}' > "$DATA_DIR/probe.json"

    echo "[workload-inspector] probe complete — starting nginx on :8080"
    exec nginx -g 'daemon off;'
    ;;
esac
