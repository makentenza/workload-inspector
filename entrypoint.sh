#!/bin/bash
set -euo pipefail

DATA_DIR="/usr/share/nginx/html/data"
mkdir -p "$DATA_DIR"

echo "[workload-inspector] running environment probe..."
/opt/workload-inspector/probe.sh > "$DATA_DIR/probe.json" 2>/dev/null || \
    echo '{"error":"probe failed","probeTimestamp":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}' > "$DATA_DIR/probe.json"

echo "[workload-inspector] probe complete — starting nginx on :8080"
exec nginx -g 'daemon off;'
