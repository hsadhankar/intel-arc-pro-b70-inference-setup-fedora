#!/usr/bin/env bash
# xe_tuning.sh — Intel xe driver tuning for Battlemage inference workloads
#
# NOTE: Must be run as root (sudo). Writes to /sys/devices/... files.
#
# Raises job timeouts, disables DVFS, and optimizes PCIe ASPM for
# long-running LLM inference workloads on Intel Arc Pro B70 GPUs.
set -u
LOG_TAG="xe-tuning"

JOB_TIMEOUT_MS=30000

log() { logger -t "$LOG_TAG" -- "$*"; echo "[xe-tuning] $*"; }
log "starting xe driver tuning"

# 1. Per-engine job_timeout_ms
count=0
while IFS= read -r f; do
    [ -z "$f" ] && continue
    case "$f" in *".defaults"*) continue ;; esac
    max_file="$(dirname "$f")/job_timeout_max"
    target=$JOB_TIMEOUT_MS
    if [ -r "$max_file" ]; then
        engine_max=$(cat "$max_file" 2>/dev/null || echo 0)
        if [ "${engine_max:-0}" -gt 0 ] && [ "$target" -gt "$engine_max" ]; then
            target=$engine_max
        fi
    fi
    echo "$target" > "$f" 2>/dev/null && count=$((count + 1)) || log "WARN: failed to write $target to $f"
done < <(find /sys/devices -name job_timeout_ms 2>/dev/null)
log "job_timeout_ms: updated $count engines to ${JOB_TIMEOUT_MS}ms (clamped to engine max where needed)"

# 2. Per-engine preempt_timeout_us (disable preemption timeout)
count=0
while IFS= read -r f; do
    [ -z "$f" ] && continue
    case "$f" in *".defaults"*) continue ;; esac
    max_file="$(dirname "$f")/preempt_timeout_max"
    target=$(cat "$max_file" 2>/dev/null || echo 0)
    [ "${target:-0}" -le 0 ] && continue
    echo "$target" > "$f" 2>/dev/null && count=$((count + 1)) || log "WARN: failed to write $target to $f"
done < <(find /sys/devices -name preempt_timeout_us 2>/dev/null)
log "preempt_timeout_us: raised $count engines to their max"

# 3. Pin GT frequency (DVFS off)
count=0
while IFS= read -r freq_dir; do
    [ -d "$freq_dir" ] || continue
    rp0=$(cat "$freq_dir/rp0_freq" 2>/dev/null || echo "")
    [ -z "$rp0" ] && continue
    echo "$rp0" > "$freq_dir/max_freq" 2>/dev/null || true
    echo "$rp0" > "$freq_dir/min_freq" 2>/dev/null || true
    count=$((count + 1))
done < <(find /sys/devices -type d -path "*tile0/gt*/freq0" 2>/dev/null)
log "gt frequency: pinned min=max=rp0 on $count GTs"

# 4. PCIe ASPM
if [ -w /sys/module/pcie_aspm/parameters/policy ]; then
    echo performance > /sys/module/pcie_aspm/parameters/policy 2>/dev/null || true
    log "pcie_aspm policy: $(cat /sys/module/pcie_aspm/parameters/policy 2>/dev/null)"
fi

log "xe tuning complete"
