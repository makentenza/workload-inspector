#!/bin/bash
# Aggregator discovery loop. Runs only when WI_ROLE=dashboard.
#
# Every WI_DISCOVER_INTERVAL seconds it asks the in-cluster Kubernetes API for
# pods labelled wi-role=probe in its own namespace, fetches each pod's
# data/probe.json over :8080, and writes:
#   data/instances/<id>.json   one probe document per instance
#   data/instances.json        index: [{id,variant,podName,node,phase,ok}, ...]
# where <id> is the pod's wi-variant label (sanitised), falling back to podName.
#
# Resilient by design: every curl has a timeout, individual probe failures do
# not abort the sweep, and the index is always rewritten — even when some (or
# all) probes are unreachable. The loop never exits on a transient error.

set -uo pipefail

WEB_ROOT="/usr/share/nginx/html"
DATA_DIR="$WEB_ROOT/data"
INSTANCE_DIR="$DATA_DIR/instances"
INTERVAL="${WI_DISCOVER_INTERVAL:-15}"
PROBE_PORT="${WI_PROBE_PORT:-8080}"

SA_DIR="/var/run/secrets/kubernetes.io/serviceaccount"
TOKEN_FILE="$SA_DIR/token"
CA_FILE="$SA_DIR/ca.crt"
NS_FILE="$SA_DIR/namespace"
APISERVER="https://kubernetes.default.svc"

mkdir -p "$INSTANCE_DIR"

# Sanitise an id for use as a filename: keep [a-z0-9._-], collapse the rest.
sanitize() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g; s/^-*//; s/-*$//'
}

discover_once() {
    local ns token
    ns="$(cat "$NS_FILE" 2>/dev/null || echo "")"
    token="$(cat "$TOKEN_FILE" 2>/dev/null || echo "")"

    if [ -z "$ns" ] || [ -z "$token" ]; then
        echo "[discover] no in-cluster service account credentials; writing empty index" >&2
        echo '[]' > "$DATA_DIR/instances.json"
        return 0
    fi

    # Query the API for probe pods in our namespace.
    local pods_json
    pods_json="$(curl -sf --max-time 8 \
        --cacert "$CA_FILE" \
        -H "Authorization: Bearer $token" \
        "$APISERVER/api/v1/namespaces/$ns/pods?labelSelector=wi-role=probe" 2>/dev/null || echo "")"

    if [ -z "$pods_json" ]; then
        echo "[discover] kube API query failed; keeping previous index" >&2
        return 0
    fi

    # Flatten each pod to one base64-encoded compact JSON object per line. Going
    # through base64 keeps fields intact regardless of empty values or odd
    # characters (a plain tab/space split mangles rows whose leading fields are
    # empty, e.g. pods missing the wi-variant label).
    local rows
    rows="$(printf '%s' "$pods_json" | jq -r '
        .items[]? | {
          variant: (.metadata.labels["wi-variant"] // ""),
          pod:     (.metadata.name // ""),
          node:    (.spec.nodeName // ""),
          phase:   (.status.phase // ""),
          ip:      (.status.podIP // "")
        } | @base64
    ' 2>/dev/null || echo "")"

    # Build the index incrementally as we probe each pod.
    local index="[]"
    local row obj id variant pod node phase ip ok seen=""

    while IFS= read -r row; do
        [ -z "$row" ] && continue
        obj="$(printf '%s' "$row" | base64 -d 2>/dev/null || echo "")"
        [ -z "$obj" ] && continue

        variant="$(printf '%s' "$obj" | jq -r '.variant // ""')"
        pod="$(printf '%s' "$obj" | jq -r '.pod // ""')"
        node="$(printf '%s' "$obj" | jq -r '.node // ""')"
        phase="$(printf '%s' "$obj" | jq -r '.phase // ""')"
        ip="$(printf '%s' "$obj" | jq -r '.ip // ""')"
        [ -z "$pod" ] && continue

        # Choose a stable id: variant label, else pod name.
        if [ -n "$variant" ]; then
            id="$(sanitize "$variant")"
        else
            id="$(sanitize "$pod")"
        fi
        [ -z "$id" ] && id="$(sanitize "$pod")"
        [ -z "$variant" ] && variant="$pod"

        # Guard against duplicate ids (e.g. two pods of the same variant):
        # suffix collisions so each instance keeps its own file.
        local base="$id" n=2
        while printf '%s' "$seen" | grep -qx "$id"; do
            id="${base}-${n}"
            n=$((n + 1))
        done
        seen="${seen}${id}"$'\n'

        ok="false"
        if [ "$phase" = "Running" ] && [ -n "$ip" ]; then
            local probe
            probe="$(curl -sf --max-time 5 \
                "http://${ip}:${PROBE_PORT}/data/probe.json" 2>/dev/null || echo "")"
            if [ -n "$probe" ] && printf '%s' "$probe" | jq -e . >/dev/null 2>&1; then
                printf '%s' "$probe" > "$INSTANCE_DIR/${id}.json"
                ok="true"
            fi
        fi

        index="$(printf '%s' "$index" | jq \
            --arg id "$id" --arg variant "$variant" --arg pod "$pod" \
            --arg node "$node" --arg phase "$phase" --argjson ok "$ok" \
            '. + [{id:$id, variant:$variant, podName:$pod, node:$node, phase:$phase, ok:$ok}]' \
            2>/dev/null || printf '%s' "$index")"
    done <<< "$rows"

    # Atomic-ish swap so the dashboard never reads a half-written index.
    printf '%s' "$index" > "$DATA_DIR/instances.json.tmp" && \
        mv -f "$DATA_DIR/instances.json.tmp" "$DATA_DIR/instances.json"

    # Drop stale per-instance files for pods that no longer exist.
    local f base
    for f in "$INSTANCE_DIR"/*.json; do
        [ -e "$f" ] || continue
        base="$(basename "$f" .json)"
        if ! printf '%s' "$seen" | grep -qx "$base"; then
            rm -f "$f"
        fi
    done
}

echo "[discover] starting — interval=${INTERVAL}s probe-port=${PROBE_PORT}"
while true; do
    discover_once || echo "[discover] sweep error (continuing)" >&2
    sleep "$INTERVAL"
done
