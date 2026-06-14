#!/bin/bash
# Probes the runtime environment for sandboxing and confidential computing
# context. Outputs a JSON document to stdout.

set -euo pipefail

safe_read() { cat "$1" 2>/dev/null || echo ""; }
safe_read_trim() { cat "$1" 2>/dev/null | tr -d '\0' | head -1 | xargs 2>/dev/null || echo ""; }
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g' | tr '\n' ' '; }

# ---------------------------------------------------------------------------
# 1. Pod / host identity
# ---------------------------------------------------------------------------
probe_identity() {
    local hostname pod_name namespace node_name pod_ip sa_name uid
    hostname="$(hostname 2>/dev/null || echo unknown)"
    pod_name="${POD_NAME:-$hostname}"
    namespace="${POD_NAMESPACE:-unknown}"
    node_name="${NODE_NAME:-unknown}"
    pod_ip="${POD_IP:-unknown}"
    sa_name="${SA_NAME:-default}"
    uid="${POD_UID:-unknown}"
    local kernel
    kernel="$(uname -r 2>/dev/null || echo unknown)"

    cat <<EOJSON
  "identity": {
    "hostname": "$(json_escape "$hostname")",
    "podName": "$(json_escape "$pod_name")",
    "podUid": "$(json_escape "$uid")",
    "namespace": "$(json_escape "$namespace")",
    "nodeName": "$(json_escape "$node_name")",
    "podIP": "$(json_escape "$pod_ip")",
    "serviceAccount": "$(json_escape "$sa_name")",
    "kernel": "$(json_escape "$kernel")"
  }
EOJSON
}

# ---------------------------------------------------------------------------
# 2. Runtime environment  (VM? hypervisor? kata?)
# ---------------------------------------------------------------------------
probe_runtime() {
    local in_vm="false" hypervisor_flag="" hypervisor_vendor="" hypervisor_product=""
    local kata_detected="false" kata_evidence="" runtime_hint=""

    # CPU hypervisor flag
    if grep -qw hypervisor /proc/cpuinfo 2>/dev/null; then
        in_vm="true"
        hypervisor_flag="present"
    fi

    # DMI / SMBIOS
    hypervisor_vendor="$(safe_read_trim /sys/class/dmi/id/sys_vendor)"
    hypervisor_product="$(safe_read_trim /sys/class/dmi/id/product_name)"
    local board_name
    board_name="$(safe_read_trim /sys/class/dmi/id/board_name)"

    if [ -n "$hypervisor_vendor" ] || [ -n "$hypervisor_product" ]; then
        in_vm="true"
    fi

    # Kata detection — kernel cmdline carries kata agent params
    local cmdline
    cmdline="$(safe_read /proc/cmdline)"
    if echo "$cmdline" | grep -q 'agent\.'; then
        kata_detected="true"
        kata_evidence="kernel cmdline contains kata agent parameters"
    fi
    if [ -d /run/kata-containers ] 2>/dev/null; then
        kata_detected="true"
        kata_evidence="${kata_evidence:+$kata_evidence; }/run/kata-containers exists"
    fi

    # Runtime class hint injected via Downward API label
    runtime_hint="${RUNTIME_CLASS:-not injected}"

    cat <<EOJSON
  "runtime": {
    "inVM": $in_vm,
    "hypervisorFlag": "$(json_escape "$hypervisor_flag")",
    "dmiVendor": "$(json_escape "$hypervisor_vendor")",
    "dmiProduct": "$(json_escape "$hypervisor_product")",
    "dmiBoardName": "$(json_escape "$board_name")",
    "kataDetected": $kata_detected,
    "kataEvidence": "$(json_escape "$kata_evidence")",
    "runtimeClassHint": "$(json_escape "$runtime_hint")"
  }
EOJSON
}

# ---------------------------------------------------------------------------
# 3. Execution mode — on-node kata vs peer pod
# ---------------------------------------------------------------------------
probe_execution_mode() {
    local mode="unknown" cloud_provider="none"
    local gcp_machine_type="" gcp_zone="" gcp_instance_id="" gcp_project=""
    local aws_instance_type="" aws_az="" aws_instance_id=""
    local azure_vm_size="" azure_location="" azure_vm_id=""

    # GCP metadata
    local gcp_ok="false" gcp_instance_name=""
    gcp_machine_type="$(curl -sf -m 2 -H 'Metadata-Flavor: Google' \
        http://metadata.google.internal/computeMetadata/v1/instance/machine-type 2>/dev/null || echo "")"
    if [ -n "$gcp_machine_type" ]; then
        gcp_ok="true"
        cloud_provider="gcp"
        mode="peer-pod"
        # extract short machine type (last path segment)
        gcp_machine_type="${gcp_machine_type##*/}"
        gcp_zone="$(curl -sf -m 2 -H 'Metadata-Flavor: Google' \
            http://metadata.google.internal/computeMetadata/v1/instance/zone 2>/dev/null || echo "")"
        gcp_zone="${gcp_zone##*/}"
        gcp_instance_id="$(curl -sf -m 2 -H 'Metadata-Flavor: Google' \
            http://metadata.google.internal/computeMetadata/v1/instance/id 2>/dev/null || echo "")"
        gcp_instance_name="$(curl -sf -m 2 -H 'Metadata-Flavor: Google' \
            http://metadata.google.internal/computeMetadata/v1/instance/name 2>/dev/null || echo "")"
        gcp_project="$(curl -sf -m 2 -H 'Metadata-Flavor: Google' \
            http://metadata.google.internal/computeMetadata/v1/project/project-id 2>/dev/null || echo "")"
    fi

    # AWS metadata (IMDSv2)
    if [ "$cloud_provider" = "none" ]; then
        local aws_token
        aws_token="$(curl -sf -m 2 -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' \
            http://169.254.169.254/latest/api/token 2>/dev/null || echo "")"
        if [ -n "$aws_token" ]; then
            aws_instance_type="$(curl -sf -m 2 -H "X-aws-ec2-metadata-token: $aws_token" \
                http://169.254.169.254/latest/meta-data/instance-type 2>/dev/null || echo "")"
        else
            aws_instance_type="$(curl -sf -m 2 \
                http://169.254.169.254/latest/meta-data/instance-type 2>/dev/null || echo "")"
        fi
        if [ -n "$aws_instance_type" ]; then
            cloud_provider="aws"
            mode="peer-pod"
            aws_az="$(curl -sf -m 2 -H "X-aws-ec2-metadata-token: ${aws_token}" \
                http://169.254.169.254/latest/meta-data/placement/availability-zone 2>/dev/null || echo "")"
            aws_instance_id="$(curl -sf -m 2 -H "X-aws-ec2-metadata-token: ${aws_token}" \
                http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || echo "")"
        fi
    fi

    # Azure metadata
    if [ "$cloud_provider" = "none" ]; then
        local azure_json
        azure_json="$(curl -sf -m 2 -H 'Metadata: true' \
            'http://169.254.169.254/metadata/instance/compute?api-version=2021-02-01' 2>/dev/null || echo "")"
        if [ -n "$azure_json" ] && echo "$azure_json" | grep -q '"vmSize"'; then
            cloud_provider="azure"
            mode="peer-pod"
            azure_vm_size="$(echo "$azure_json" | grep -o '"vmSize":"[^"]*"' | head -1 | cut -d'"' -f4)"
            azure_location="$(echo "$azure_json" | grep -o '"location":"[^"]*"' | head -1 | cut -d'"' -f4)"
            azure_vm_id="$(echo "$azure_json" | grep -o '"vmId":"[^"]*"' | head -1 | cut -d'"' -f4)"
        fi
    fi

    # If we're in a VM but no cloud metadata → on-node kata
    local in_vm="false"
    grep -qw hypervisor /proc/cpuinfo 2>/dev/null && in_vm="true"
    if [ "$in_vm" = "true" ] && [ "$mode" = "unknown" ]; then
        mode="on-node"
    fi
    # Not in a VM at all → standard container
    if [ "$in_vm" = "false" ] && [ "$mode" = "unknown" ]; then
        mode="standard"
    fi

    cat <<EOJSON
  "executionMode": {
    "mode": "$(json_escape "$mode")",
    "cloudProvider": "$(json_escape "$cloud_provider")",
    "gcp": {
      "machineType": "$(json_escape "$gcp_machine_type")",
      "zone": "$(json_escape "$gcp_zone")",
      "instanceId": "$(json_escape "$gcp_instance_id")",
      "instanceName": "$(json_escape "$gcp_instance_name")",
      "project": "$(json_escape "$gcp_project")"
    },
    "aws": {
      "instanceType": "$(json_escape "$aws_instance_type")",
      "availabilityZone": "$(json_escape "$aws_az")",
      "instanceId": "$(json_escape "$aws_instance_id")"
    },
    "azure": {
      "vmSize": "$(json_escape "$azure_vm_size")",
      "location": "$(json_escape "$azure_location")",
      "vmId": "$(json_escape "$azure_vm_id")"
    }
  }
EOJSON
}

# ---------------------------------------------------------------------------
# 4. Confidential Computing / TEE
# ---------------------------------------------------------------------------
probe_tee() {
    local tee_detected="false" tee_type="none" tee_evidence=""
    local tdx_guest_dev="false" sev_guest_dev="false"
    local coco_secrets="false" cc_eventlog="false"

    # Intel TDX
    if [ -e /dev/tdx_guest ] || [ -e /dev/tdx-guest ]; then
        tee_detected="true"; tee_type="Intel TDX"; tdx_guest_dev="true"
        tee_evidence="TDX guest device present"
    fi
    if [ -f /sys/firmware/acpi/tables/CCEL ] 2>/dev/null; then
        tee_detected="true"; tee_type="Intel TDX"; cc_eventlog="true"
        tee_evidence="${tee_evidence:+$tee_evidence; }CC Event Log (CCEL) table present"
    fi
    if [ -f /sys/firmware/acpi/tables/TDEL ] 2>/dev/null; then
        tee_detected="true"; tee_type="Intel TDX"
        tee_evidence="${tee_evidence:+$tee_evidence; }TDX Event Log (TDEL) table present"
    fi

    # AMD SEV / SEV-SNP
    if [ -e /dev/sev-guest ] || [ -e /dev/sev ]; then
        tee_detected="true"; sev_guest_dev="true"
        if grep -qw sev_snp /proc/cpuinfo 2>/dev/null; then
            tee_type="AMD SEV-SNP"
            tee_evidence="${tee_evidence:+$tee_evidence; }SEV-SNP cpu flag + guest device"
        else
            tee_type="AMD SEV"
            tee_evidence="${tee_evidence:+$tee_evidence; }SEV guest device present"
        fi
    fi
    # Also check cpuinfo flags even without device
    if [ "$tee_type" = "none" ]; then
        if grep -qw sev_snp /proc/cpuinfo 2>/dev/null; then
            tee_detected="true"; tee_type="AMD SEV-SNP"
            tee_evidence="${tee_evidence:+$tee_evidence; }sev_snp flag in cpuinfo"
        elif grep -qw sev /proc/cpuinfo 2>/dev/null; then
            tee_detected="true"; tee_type="AMD SEV"
            tee_evidence="${tee_evidence:+$tee_evidence; }sev flag in cpuinfo"
        fi
    fi

    # Kernel cmdline cc-related params
    local cmdline
    cmdline="$(safe_read /proc/cmdline)"
    local cc_blob=""
    if echo "$cmdline" | grep -q 'confidential'; then
        cc_blob="confidential parameter in cmdline"
    fi
    if echo "$cmdline" | grep -q 'mem_encrypt=on'; then
        cc_blob="${cc_blob:+$cc_blob; }mem_encrypt=on in cmdline"
        if [ "$tee_type" = "none" ]; then
            tee_detected="true"; tee_type="AMD SEV (inferred)"
            tee_evidence="${tee_evidence:+$tee_evidence; }mem_encrypt=on"
        fi
    fi
    if echo "$cmdline" | grep -q 'tdx_guest'; then
        cc_blob="${cc_blob:+$cc_blob; }tdx_guest in cmdline"
        if [ "$tee_type" = "none" ]; then
            tee_detected="true"; tee_type="Intel TDX (inferred)"
            tee_evidence="${tee_evidence:+$tee_evidence; }tdx_guest in cmdline"
        fi
    fi

    # CoCo sealed secrets directory
    if [ -d /sys/kernel/security/secrets/coco ]; then
        coco_secrets="true"
        tee_evidence="${tee_evidence:+$tee_evidence; }CoCo secrets directory present"
        [ "$tee_detected" = "false" ] && tee_detected="true"
    fi

    # CPU model for context
    local cpu_model
    cpu_model="$(grep 'model name' /proc/cpuinfo 2>/dev/null | head -1 | cut -d: -f2 | xargs || echo unknown)"

    # Memory encryption (dmesg is usually inaccessible; try /proc/crypto)
    local mem_encryption="unknown"
    if grep -q 'ccp' /proc/crypto 2>/dev/null || grep -q 'aesni' /proc/crypto 2>/dev/null; then
        mem_encryption="hardware crypto present"
    fi

    cat <<EOJSON
  "tee": {
    "detected": $tee_detected,
    "type": "$(json_escape "$tee_type")",
    "evidence": "$(json_escape "$tee_evidence")",
    "devices": {
      "tdxGuest": $tdx_guest_dev,
      "sevGuest": $sev_guest_dev
    },
    "cocoSecrets": $coco_secrets,
    "ccEventLog": $cc_eventlog,
    "cmdlineCC": "$(json_escape "$cc_blob")",
    "cpuModel": "$(json_escape "$cpu_model")",
    "memEncryption": "$(json_escape "$mem_encryption")"
  }
EOJSON
}

# ---------------------------------------------------------------------------
# 5. GPU TEE — NVIDIA confidential computing
# ---------------------------------------------------------------------------
probe_gpu() {
    local present="false" vendor="" count=0 model="" driver=""
    local cc_mode="unknown" cc_evidence=""
    local dev_nvidia0="false" dev_nvidiactl="false" dev_uvm="false" dev_caps="false"

    # NVIDIA kernel driver
    if [ -f /proc/driver/nvidia/version ]; then
        present="true"; vendor="NVIDIA"
        driver="$(grep -oE 'Kernel Module +[0-9][0-9.]+' /proc/driver/nvidia/version 2>/dev/null \
            | grep -oE '[0-9][0-9.]+' | head -1)"
    fi

    # GPU device nodes
    [ -e /dev/nvidia0 ]       && { dev_nvidia0="true"; present="true"; vendor="NVIDIA"; }
    [ -e /dev/nvidiactl ]     && dev_nvidiactl="true"
    [ -e /dev/nvidia-uvm ]    && dev_uvm="true"
    [ -e /dev/nvidia-caps ]   && dev_caps="true"

    # Count + model from /proc
    if [ -d /proc/driver/nvidia/gpus ]; then
        count="$(ls -1 /proc/driver/nvidia/gpus 2>/dev/null | wc -l | tr -d ' ')"
        local g
        g="$(ls -1 /proc/driver/nvidia/gpus 2>/dev/null | head -1)"
        if [ -n "$g" ] && [ -f "/proc/driver/nvidia/gpus/$g/information" ]; then
            model="$(grep -i '^Model:' "/proc/driver/nvidia/gpus/$g/information" 2>/dev/null \
                | cut -d: -f2- | xargs)"
        fi
    fi
    [ "$count" = "0" ] && count="$(ls -1 /dev/nvidia[0-9]* 2>/dev/null | wc -l | tr -d ' ')"

    # Confidential Compute mode — best effort via nvidia-smi if present
    if command -v nvidia-smi >/dev/null 2>&1; then
        local cc_out
        cc_out="$(nvidia-smi conf-compute -f 2>/dev/null | tr -d '\r' || echo "")"
        if echo "$cc_out" | grep -qiE 'status:[[:space:]]*(ON|ENABLED|DEVTOOLS)'; then
            cc_mode="on"; cc_evidence="nvidia-smi conf-compute: $(echo "$cc_out" | head -1 | xargs)"
        elif echo "$cc_out" | grep -qiE 'status:[[:space:]]*(OFF|DISABLED)'; then
            cc_mode="off"; cc_evidence="nvidia-smi conf-compute: off"
        fi
        [ -z "$model" ] && model="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 | xargs)"
    fi
    # CC capability device present but nvidia-smi unavailable to confirm status
    if [ "$cc_mode" = "unknown" ] && [ "$dev_caps" = "true" ]; then
        cc_evidence="/dev/nvidia-caps present (CC capability device); install nvidia-smi to confirm CC status"
    fi

    cat <<EOJSON
  "gpu": {
    "present": $present,
    "vendor": "$(json_escape "$vendor")",
    "count": ${count:-0},
    "model": "$(json_escape "$model")",
    "driverVersion": "$(json_escape "$driver")",
    "ccMode": "$(json_escape "$cc_mode")",
    "ccEvidence": "$(json_escape "$cc_evidence")",
    "devices": {
      "nvidia0": $dev_nvidia0,
      "nvidiactl": $dev_nvidiactl,
      "nvidiaUvm": $dev_uvm,
      "nvidiaCaps": $dev_caps
    }
  }
EOJSON
}

# ---------------------------------------------------------------------------
# 6. Attestation
# ---------------------------------------------------------------------------
probe_attestation() {
    local aa_detected="false" aa_kbc_params="" kbs_url="" kbc_type=""

    # Kernel cmdline: aa_kbc_params=<kbc>::<kbs_url>
    local cmdline
    cmdline="$(safe_read /proc/cmdline)"
    aa_kbc_params="$(echo "$cmdline" | grep -o 'aa_kbc_params=[^ ]*' | head -1 | cut -d= -f2- || echo "")"
    if [ -n "$aa_kbc_params" ]; then
        aa_detected="true"
        kbc_type="$(echo "$aa_kbc_params" | cut -d: -f1)"
        kbs_url="$(echo "$aa_kbc_params" | sed 's/^[^:]*:://')"
    fi

    # CDH socket
    local cdh_socket="false"
    if [ -S /run/confidential-containers/cdh.sock ] 2>/dev/null; then
        cdh_socket="true"
        aa_detected="true"
    fi

    # CDH config files
    local cdh_config=""
    for f in /etc/confidential-containers/cdh.toml \
             /run/confidential-containers/cdh.toml \
             /etc/attestation-agent/config.toml; do
        if [ -f "$f" ]; then
            cdh_config="$f"
            aa_detected="true"
            break
        fi
    done

    # initdata
    local initdata_present="false"
    if [ -f /sys/kernel/security/secrets/coco/initdata ] 2>/dev/null; then
        initdata_present="true"
        aa_detected="true"
    fi

    # Attestation Agent process
    local aa_process="false"
    if pgrep -x attestation-agent >/dev/null 2>&1 || pgrep -x 'attestation_agent' >/dev/null 2>&1; then
        aa_process="true"
        aa_detected="true"
    fi

    # Confidential Data Hub process
    local cdh_process="false"
    if pgrep -x confidential-data-hub >/dev/null 2>&1 || pgrep -x cdh >/dev/null 2>&1; then
        cdh_process="true"
    fi

    cat <<EOJSON
  "attestation": {
    "detected": $aa_detected,
    "kbcParams": "$(json_escape "$aa_kbc_params")",
    "kbcType": "$(json_escape "$kbc_type")",
    "kbsUrl": "$(json_escape "$kbs_url")",
    "cdhSocket": $cdh_socket,
    "cdhConfigPath": "$(json_escape "$cdh_config")",
    "initdataPresent": $initdata_present,
    "aaProcess": $aa_process,
    "cdhProcess": $cdh_process
  }
EOJSON
}

# ---------------------------------------------------------------------------
# Assemble
# ---------------------------------------------------------------------------
echo "{"
echo "  \"probeTimestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
echo "  \"probeVersion\": \"2.0.0\","
probe_identity
echo ","
probe_runtime
echo ","
probe_execution_mode
echo ","
probe_tee
echo ","
probe_gpu
echo ","
probe_attestation
echo "}"
