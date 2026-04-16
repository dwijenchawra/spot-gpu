#!/bin/bash
#
# llm_watchdog.sh - Run LLM server on idle GPUs, yield to Slurm jobs
#
# Detection strategy (node-local only, zero cgroupfs touches):
#   - Primary:  NVML compute-apps (foreign CUDA context => yield)
#   - Optional: /proc/<pid>/cgroup scan for slurmstepd/job_<id> ancestry
#               (hybrid mode; earlier detection, one scontrol per new job)
#
# Manages: vLLM + cloudflared tunnel
# Notifies: ntfy.sh
#

set -uo pipefail

# =============================================================================
# Configuration
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${1:-$SCRIPT_DIR/config.env}"
MODEL_FILE="${2:-$SCRIPT_DIR/active-model.env}"
AVAILABLE_NODES_ARG="${3:-}"

if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    echo "ERROR: Config file not found: $CONFIG_FILE"
    exit 1
fi

if [[ -f "$MODEL_FILE" ]]; then
    source "$MODEL_FILE"
else
    echo "ERROR: No active model. Run: ./switch-model.sh <model-name>"
    exit 1
fi

AVAILABLE_NODES=""
if [[ -n "$AVAILABLE_NODES_ARG" ]]; then
    AVAILABLE_NODES="${AVAILABLE_NODES_ARG//,/ }"
elif [[ -n "${AVAILABLE_NODES:-}" ]]; then
    AVAILABLE_NODES="${AVAILABLE_NODES//,/ }"
fi

# Test mode: artificially trigger migration after N seconds
TEST_MODE=false
TEST_DELAY=0
for arg in "$@"; do
    if [[ "$arg" == --test* ]]; then
        TEST_MODE=true
        if [[ "$arg" =~ --test[=[:space:]]?([0-9]+) ]]; then
            TEST_DELAY="${BASH_REMATCH[1]}"
        fi
    fi
done

# =============================================================================
# Environment Resolution (per-node CUDA setup from config.env)
# =============================================================================

if [[ "${CUDA_SETUP:-false}" == "true" ]]; then
    export LD_LIBRARY_PATH="${CUDA12_LIB}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export CUDA_HOME="${CUDA_HOME_OVERRIDE}"
fi

export HF_HOME="${HF_HOME}"
source "${LLM_VENV}/bin/activate"

for var in NTFY_TOPIC LLM_VENV LLM_BIN MODEL_NAME SERVER_PORT CLOUDFLARED_BIN TUNNEL_ID NUM_GPUS; do
    if [[ -z "${!var:-}" ]]; then
        echo "ERROR: $var not set in config"
        exit 1
    fi
done

HOSTNAME_SHORT=$(hostname -s)

# Detection config (with safe defaults; override in config.env)
DETECTION_MODE="${DETECTION_MODE:-hybrid}"                # nvml | hybrid
DETECT_POLL="${DETECT_POLL:-${POLL_INTERVAL:-2}}"        # seconds between polls
YIELD_GRACE="${YIELD_GRACE:-15}"                          # seconds before SIGKILL
NVSMI_TIMEOUT="${NVSMI_TIMEOUT:-5}"                       # seconds for nvidia-smi calls
SLURM_CGROUP_PATTERN="${SLURM_CGROUP_PATTERN:-slurmstepd.scope/job_}"

# =============================================================================
# State
# =============================================================================

SERVER_PID=""
TUNNEL_PID=""
ACTIVE_GPUS=""
TOTAL_GPUS=0
DOWNTIME_START=0
declare -A BUS_TO_INDEX

# =============================================================================
# Logging
# =============================================================================

LOG_FILE="$SCRIPT_DIR/runlogs.txt"

log() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $1" | tee -a "$LOG_FILE"
}

# =============================================================================
# NVML helpers (Option A: primary detection, no cgroupfs, no slurmctld)
# =============================================================================

# All nvidia-smi calls go through this — a stuck driver won't hang the watchdog.
nvsmi() {
    timeout "$NVSMI_TIMEOUT" nvidia-smi "$@"
}

get_total_gpus() {
    nvsmi --query-gpu=index --format=csv,noheader 2>/dev/null | wc -l
}

# Cache bus_id -> index once. GPU topology doesn't change at runtime.
build_gpu_map() {
    local line idx bus
    while IFS=, read -r idx bus; do
        idx="${idx// /}"; bus="${bus// /}"
        [[ -z "$idx" || -z "$bus" ]] && continue
        BUS_TO_INDEX["$bus"]="$idx"
    done < <(nvsmi --query-gpu=index,gpu_bus_id --format=csv,noheader 2>/dev/null)
}

# Recursive descendants of SERVER_PID. Used to classify "our" PIDs in nvidia-smi
# compute-apps output so we don't treat a newly-spawned vLLM worker as foreign.
my_pids() {
    [[ -z "$SERVER_PID" ]] && return
    local -a queue=("$SERVER_PID")
    local -a out=()
    while ((${#queue[@]} > 0)); do
        local pid="${queue[0]}"
        queue=("${queue[@]:1}")
        out+=("$pid")
        local kids
        kids=$(pgrep -P "$pid" 2>/dev/null || true)
        [[ -n "$kids" ]] && queue+=($kids)
    done
    ((${#out[@]} > 0)) && printf '%s\n' "${out[@]}"
}

# GPU indices (as known to nvidia-smi) holding ANY CUDA context right now.
# Used at startup to determine which GPUs are free. Nothing is serving yet at
# that call site, so "any context" = "not ours".
get_busy_gpus() {
    local raw
    raw=$(nvsmi --query-compute-apps=gpu_bus_id --format=csv,noheader 2>/dev/null || true)
    [[ -z "$raw" ]] && return
    echo "$raw" | awk '{$1=$1}1' | sort -u | while read -r bus; do
        [[ -z "$bus" ]] && continue
        local idx="${BUS_TO_INDEX[$bus]:-}"
        [[ -n "$idx" ]] && echo "$idx"
    done | sort -un
}

# GPU indices with a foreign (non-vLLM-descendant) CUDA context. Double-reads
# my_pids to handle the race where vLLM forks a worker mid-query.
foreign_gpus_in_use() {
    local before after raw
    before=$(my_pids | paste -sd'|' -)
    [[ -z "$before" ]] && before="__none__"

    raw=$(nvsmi --query-compute-apps=pid,gpu_bus_id --format=csv,noheader 2>/dev/null || true)

    after=$(my_pids | paste -sd'|' -)
    [[ -z "$after" ]] && after="__none__"

    [[ -z "$raw" ]] && return

    echo "$raw" \
        | awk -F, -v m1="^(${before})$" -v m2="^(${after})$" '
            { gsub(/ /,"") }
            $1 !~ m1 && $1 !~ m2 { print $2 }
          ' \
        | sort -u \
        | while read -r bus; do
            [[ -z "$bus" ]] && continue
            local idx="${BUS_TO_INDEX[$bus]:-}"
            [[ -n "$idx" ]] && echo "$idx"
          done | sort -un
}

# =============================================================================
# Procfs helpers (Option B: optional early detection)
# =============================================================================
#
# Reads /proc/<pid>/cgroup — procfs, NOT cgroupfs. The kernel synthesizes the
# output from each task's in-memory css_set under RCU. This does not take any
# kernfs locks, so it cannot contend with cgroup_destroy the way find/cat/
# inotifywait on /sys/fs/cgroup can. Safe w.r.t. the cgroup_kn_lock_live wedge.

# True if we can observe processes owned by other users (hidepid not blocking).
procfs_sees_other_users() {
    # pid 1 is root-owned; if we can read its cgroup, hidepid isn't hiding us.
    [[ -r /proc/1/cgroup ]]
}

# Snapshot of Slurm job IDs with at least one running process on this node,
# sourced from /proc/*/cgroup. Comma-joined, deduped, sorted. Empty if none.
procfs_job_snapshot() {
    local pat="${SLURM_CGROUP_PATTERN}"
    awk -v pat="$pat" '
        {
            i = index($0, pat)
            if (i > 0) {
                rest = substr($0, i + length(pat))
                n = 0
                for (k = 1; k <= length(rest); k++) {
                    c = substr(rest, k, 1)
                    if (c ~ /[0-9]/) n = n * 10 + (c + 0)
                    else break
                }
                if (n > 0) print n
            }
        }
    ' /proc/[0-9]*/cgroup 2>/dev/null | sort -un | tr '\n' ',' | sed 's/,$//'
}

# =============================================================================
# Shared helpers
# =============================================================================

expand_gpu_range() {
    local input=$1
    echo "$input" | tr ',' '\n' | while read -r part; do
        [[ -z "$part" ]] && continue
        if [[ "$part" == *-* ]]; then
            seq "${part%-*}" "${part#*-}"
        else
            echo "$part"
        fi
    done
}

# Query Slurm for a specific job's GPU indices. Called at most once per newly-
# observed job ID (hybrid mode), so slurmctld load is bounded by job arrival
# rate on this node — not by our poll rate.
get_job_gpus() {
    local jobid=$1
    scontrol show job "$jobid" -d 2>/dev/null | \
        grep -oP 'GRES=gpu[^(]*\(IDX:\K[-0-9,.]+' | head -1
}

get_free_gpus() {
    local all busy
    all=$(seq 0 $((TOTAL_GPUS - 1)))
    busy=$(get_busy_gpus)
    if [[ -z "$busy" ]]; then
        echo "$all"
    else
        comm -23 <(echo "$all") <(echo "$busy")
    fi
}

check_overlap() {
    local gpu_range=$1
    local expanded
    expanded=$(expand_gpu_range "$gpu_range")
    while read -r gpu; do
        [[ -z "$gpu" ]] && continue
        if [[ ",$ACTIVE_GPUS," == *",$gpu,"* ]]; then
            return 0
        fi
    done <<< "$expanded"
    return 1
}

# =============================================================================
# Node GPU Status (sinfo) — only used on migration, not on hot path
# =============================================================================

get_node_gpu_status() {
    local nodes="$1"
    local required_gpus=$2

    for node in $nodes; do
        local sinfo_line
        sinfo_line=$(sinfo -NO "Gres:GresUsed,NodeList" -n "$node" 2>/dev/null | tail -1)
        [[ -z "$sinfo_line" ]] && continue

        local gres_used
        gres_used=$(echo "$sinfo_line" | grep -oP 'GRES_USED=\Kgpu:[^ ]+' || true)

        local total_gpus=0
        local used_gpus=0

        if [[ "$sinfo_line" =~ gpu:h200:([0-9]+) ]]; then
            total_gpus="${BASH_REMATCH[1]}"
        elif [[ "$sinfo_line" =~ gpu:([0-9]+) ]]; then
            total_gpus="${BASH_REMATCH[1]}"
        fi

        if [[ -n "$gres_used" ]]; then
            if [[ "$gres_used" =~ IDX:([0-9,\-]+) ]]; then
                local idx="${BASH_REMATCH[1]}"
                used_gpus=$(expand_gpu_range "$idx" | wc -l)
            else
                used_gpus=$total_gpus
            fi
        fi

        local free_gpus=$((total_gpus - used_gpus))
        if [[ $free_gpus -ge $required_gpus ]]; then
            echo "$node:$free_gpus"
        fi
    done | head -1
}

# =============================================================================
# Notifications
# =============================================================================

notify() {
    local title="$1"
    local message="$2"
    local priority="${3:-3}"

    curl -sf -X POST "${NTFY_SERVER}/${NTFY_TOPIC}" \
        -H "Title: $title" \
        -H "Priority: $priority" \
        -d "$message" >/dev/null 2>&1 || log "Warning: ntfy failed"
}

# =============================================================================
# Cloudflare Tunnel
# =============================================================================

start_tunnel() {
    log "Starting Cloudflare tunnel..."

    cat > /tmp/cloudflared_config.yml <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: ${CLOUDFLARED_CREDS}

ingress:
  - hostname: ${TUNNEL_HOSTNAME}
    service: http://localhost:${SERVER_PORT}
  - service: http_status:404
EOF

    "$CLOUDFLARED_BIN" tunnel --config /tmp/cloudflared_config.yml run &
    TUNNEL_PID=$!
    sleep 3

    if kill -0 "$TUNNEL_PID" 2>/dev/null; then
        log "Tunnel started (PID: $TUNNEL_PID) -> $TUNNEL_HOSTNAME"
        return 0
    else
        log "ERROR: Tunnel failed to start"
        TUNNEL_PID=""
        return 1
    fi
}

stop_tunnel() {
    if [[ -n "$TUNNEL_PID" ]] && kill -0 "$TUNNEL_PID" 2>/dev/null; then
        log "Stopping tunnel (PID: $TUNNEL_PID)..."
        kill -TERM "$TUNNEL_PID" 2>/dev/null
        sleep 2
        kill -KILL "$TUNNEL_PID" 2>/dev/null
        wait "$TUNNEL_PID" 2>/dev/null
    fi
    TUNNEL_PID=""
}

# =============================================================================
# LLM Server (GPU-aware)
# =============================================================================

start_server() {
    local free_gpus
    free_gpus=$(get_free_gpus)
    local free_count
    free_count=$(echo "$free_gpus" | grep -c . || true)

    if (( free_count < NUM_GPUS )); then
        log "Only $free_count free GPUs, need $NUM_GPUS"
        return 1
    fi

    # Pick the last NUM_GPUS free indices (Slurm tends to allocate low first)
    ACTIVE_GPUS=$(echo "$free_gpus" | tail -n "$NUM_GPUS" | tr '\n' ',' | sed 's/,$//')
    log "Starting vLLM on GPUs: $ACTIVE_GPUS ($NUM_GPUS of $TOTAL_GPUS)"

    local args="${VLLM_ARGS:-}"
    args=$(echo "$args" | sed "s/--tensor-parallel-size [0-9]*/--tensor-parallel-size $NUM_GPUS/")

    CUDA_VISIBLE_DEVICES="$ACTIVE_GPUS" "$LLM_BIN" serve "$MODEL_NAME" \
        $args &
    SERVER_PID=$!

    log "Waiting for server to initialize..."
    local retries=0
    while [[ $retries -lt 120 ]]; do
        if curl -sf "http://localhost:${SERVER_PORT}/health" >/dev/null 2>&1; then
            log "Server is healthy"
            break
        fi
        if ! kill -0 "$SERVER_PID" 2>/dev/null; then
            log "ERROR: Server died during startup"
            SERVER_PID=""
            ACTIVE_GPUS=""
            return 1
        fi
        sleep 5
        ((retries++))
    done

    if kill -0 "$SERVER_PID" 2>/dev/null; then
        log "Server started (PID: $SERVER_PID) on GPUs $ACTIVE_GPUS"
        return 0
    else
        log "ERROR: Server failed"
        SERVER_PID=""
        ACTIVE_GPUS=""
        return 1
    fi
}

# Graceful yield: SIGTERM first, wait up to YIELD_GRACE for CUDA contexts to
# unwind, then SIGKILL. Letting the nvidia driver release state cleanly is
# what prevents a follow-on Slurm prolog from stalling on device setup.
stop_server() {
    if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
        log "Stopping server (PID: $SERVER_PID), grace ${YIELD_GRACE}s..."
        kill -TERM "$SERVER_PID" 2>/dev/null
        local i=0
        while (( i < YIELD_GRACE )); do
            kill -0 "$SERVER_PID" 2>/dev/null || break
            sleep 1
            ((i++))
        done
        if kill -0 "$SERVER_PID" 2>/dev/null; then
            log "Grace expired after ${i}s, SIGKILL"
            kill -KILL "$SERVER_PID" 2>/dev/null
        else
            log "Server exited cleanly after ${i}s"
        fi
        wait "$SERVER_PID" 2>/dev/null

        # Soft sweep for stray workers (same tree; SIGTERM first)
        pkill -TERM -f "vllm serve" 2>/dev/null || true
        sleep 1
        pkill -KILL -f "vllm serve" 2>/dev/null || true
    fi
    SERVER_PID=""
    ACTIVE_GPUS=""
}

# =============================================================================
# Combined Start/Stop
# =============================================================================

start_all() {
    if ! start_server; then
        return 1
    fi

    if ! start_tunnel; then
        stop_server
        return 1
    fi

    notify "vLLM Server Online" \
        "$HOSTNAME_SHORT: GPUs $ACTIVE_GPUS ($NUM_GPUS of $TOTAL_GPUS)
https://${TUNNEL_HOSTNAME}" \
        3
    return 0
}

stop_all() {
    # Close the tunnel first so no new requests route to a server we're tearing down.
    stop_tunnel
    stop_server
}

# =============================================================================
# Migration
# =============================================================================

migrate_to_node() {
    log "Migration triggered: conflict on GPUs $ACTIVE_GPUS, yielding vLLM..."

    stop_all

    if [[ -z "$AVAILABLE_NODES" ]]; then
        log "No available nodes configured"
        notify "No nodes available, permanently stopping" \
            "$HOSTNAME_SHORT: No nodes in AVAILABLE_NODES" 4
        exit 1
    fi

    local reverse_nodes
    reverse_nodes=$(echo "$AVAILABLE_NODES" | tr ' ' '\n' | tac | tr '\n' ' ')

    log "=== Searching for node with $NUM_GPUS free GPUs (reverse priority: $reverse_nodes) ==="

    local found_node=""
    local found_free=""

    for node in $reverse_nodes; do
        log "Checking $node..."
        local sinfo_line
        sinfo_line=$(sinfo -NO "Gres:GresUsed,NodeList" -n "$node" 2>/dev/null | tail -1)

        if [[ -z "$sinfo_line" ]]; then
            log "  $node: sinfo returned empty, skipping"
            continue
        fi

        local gres_used
        gres_used=$(echo "$sinfo_line" | grep -oP 'GRES_USED=\Kgpu:[^ ]+' || true)

        local total_gpus=0
        local used_gpus=0

        if [[ "$sinfo_line" =~ gpu:h200:([0-9]+) ]]; then
            total_gpus="${BASH_REMATCH[1]}"
        elif [[ "$sinfo_line" =~ gpu:([0-9]+) ]]; then
            total_gpus="${BASH_REMATCH[1]}"
        fi

        if [[ -n "$gres_used" ]]; then
            if [[ "$gres_used" =~ IDX:([0-9,\-]+) ]]; then
                local idx="${BASH_REMATCH[1]}"
                used_gpus=$(expand_gpu_range "$idx" | wc -l)
            else
                used_gpus=$total_gpus
            fi
        fi

        local free_gpus=$((total_gpus - used_gpus))
        log "  $node: $total_gpus total, $used_gpus used, $free_gpus free"

        if [[ $free_gpus -ge $NUM_GPUS ]]; then
            log "==> Found $node with $free_gpus free GPUs (need $NUM_GPUS)"
            found_node="$node"
            found_free="$free_gpus"
            break
        else
            log "  $node: only $free_gpus free, need $NUM_GPUS"
        fi
    done

    if [[ -z "$found_node" ]]; then
        log "=== No nodes available with $NUM_GPUS free GPUs ==="
        notify "No nodes available, permanently stopping" \
            "$HOSTNAME_SHORT: No nodes with $NUM_GPUS GPUs" 4
        exit 1
    fi

    log "=== Starting new worker on $found_node ($found_free free GPUs) ==="

    notify "Migrating to $found_node" \
        "$HOSTNAME_SHORT -> $found_node ($found_free free GPUs)" 3

    ssh -o ConnectTimeout=30 "$found_node" "tmux new-session -d -s llm_watchdog '$SCRIPT_DIR/llm_watchdog.sh $SCRIPT_DIR/config.env $MODEL_FILE $AVAILABLE_NODES'" 2>/dev/null
    local ssh_status=$?

    if [[ $ssh_status -ne 0 ]]; then
        log "SSH failed to $found_node, permanently stopping"
        notify "SSH failed to $found_node, permanently stopping" \
            "$HOSTNAME_SHORT: SSH failed" 4
        exit 1
    fi

    log "Migration complete to $found_node, exiting..."
    sleep 1
    exit 0
}

# =============================================================================
# Conflict detection loop (replaces cgroup inotify/polling + handle_new_job)
# =============================================================================
#
# Returns:
#   0 = conflict on our GPUs — caller should migrate
#   1 = server died — caller should restart

wait_for_conflict() {
    local mode="$DETECTION_MODE"
    local last_snapshot=""
    if [[ "$mode" == "hybrid" ]]; then
        if procfs_sees_other_users; then
            last_snapshot=$(procfs_job_snapshot)
        else
            log "WARN: /proc hidepid active — falling back to nvml-only"
            mode="nvml"
        fi
    fi

    log "Watching GPUs $ACTIVE_GPUS (mode=$mode, poll=${DETECT_POLL}s)..."

    while true; do
        sleep "$DETECT_POLL"

        # Server health
        if [[ -n "$SERVER_PID" ]] && ! kill -0 "$SERVER_PID" 2>/dev/null; then
            log "Server died"
            return 1
        fi

        # --- Option B: early detection via procfs (hybrid only) ---
        if [[ "$mode" == "hybrid" ]]; then
            local snap
            snap=$(procfs_job_snapshot)
            if [[ "$snap" != "$last_snapshot" ]]; then
                local new_jobs
                new_jobs=$(comm -23 \
                    <(echo "$snap"          | tr ',' '\n' | sed '/^$/d' | sort -un) \
                    <(echo "$last_snapshot" | tr ',' '\n' | sed '/^$/d' | sort -un) 2>/dev/null || true)
                last_snapshot="$snap"
                if [[ -n "$new_jobs" ]]; then
                    while read -r jobid; do
                        [[ -z "$jobid" ]] && continue
                        local job_gpus
                        job_gpus=$(get_job_gpus "$jobid")
                        if [[ -z "$job_gpus" ]]; then
                            log "  new job $jobid: no GPU allocation"
                            continue
                        fi
                        if check_overlap "$job_gpus"; then
                            log "EARLY DETECT: job $jobid on GPUs $job_gpus (we have $ACTIVE_GPUS)"
                            return 0
                        else
                            log "  new job $jobid: GPUs $job_gpus (no overlap)"
                        fi
                    done <<< "$new_jobs"
                fi
            fi
        fi

        # --- Option A: primary detection via NVML ---
        local foreign
        foreign=$(foreign_gpus_in_use | tr '\n' ',' | sed 's/,$//')
        [[ -z "$foreign" ]] && continue
        if check_overlap "$foreign"; then
            log "CONFLICT (NVML): foreign CUDA contexts on GPUs $foreign (we have $ACTIVE_GPUS)"
            return 0
        fi
    done
}

# =============================================================================
# Cleanup
# =============================================================================

cleanup() {
    log "Shutting down..."
    stop_all
    notify "LLM Watchdog Stopped" "$HOSTNAME_SHORT" 3
    exit 0
}

trap cleanup SIGTERM SIGINT SIGHUP

# =============================================================================
# Main Loop
# =============================================================================

TOTAL_GPUS=$(get_total_gpus)
build_gpu_map

# Resolve effective mode for banner (procfs_sees_other_users may downgrade)
banner_mode="$DETECTION_MODE"
if [[ "$banner_mode" == "hybrid" ]] && ! procfs_sees_other_users; then
    banner_mode="nvml (hybrid requested; procfs hidepid blocks)"
fi

log "=========================================="
log "LLM Watchdog on $HOSTNAME_SHORT"
log "  Model:      ${MODEL_NAME}"
log "  Venv:       ${LLM_VENV}"
if [[ "${CUDA_SETUP:-false}" == "true" ]]; then
    log "  CUDA:       CUDA_HOME=${CUDA_HOME}, LD_LIBRARY_PATH prepended"
fi
log "  GPUs:       ${NUM_GPUS} of ${TOTAL_GPUS} total"
log "  URL:        https://$TUNNEL_HOSTNAME"
log "  Detection:  $banner_mode (poll ${DETECT_POLL}s)"
log "  Yield:      SIGTERM + ${YIELD_GRACE}s grace"
log "  Cgroupfs:   NOT touched (safe w.r.t. cgroup_kn_lock_live)"
log "=========================================="

while true; do
    free_gpus=$(get_free_gpus)
    free_count=$(echo "$free_gpus" | grep -c . || true)

    if (( free_count < NUM_GPUS )); then
        if [[ $DOWNTIME_START -eq 0 ]]; then
            DOWNTIME_START=$(date +%s)
            log "Only $free_count of $NUM_GPUS GPUs free. Waiting..."
            log "  Busy (NVML): $(get_busy_gpus | tr '\n' ',' | sed 's/,$//')"
        fi
        sleep 10
        continue
    fi

    if start_all; then
        if [[ $DOWNTIME_START -gt 0 ]]; then
            log "Was down for $(($(date +%s) - DOWNTIME_START))s"
            DOWNTIME_START=0
        fi

        if [[ "$TEST_MODE" == "true" ]]; then
            log "TEST MODE: Will trigger migration in ${TEST_DELAY}s..."
            sleep "$TEST_DELAY"
            log "TEST MODE: Triggering migration now"
            migrate_to_node
            break
        fi

        if wait_for_conflict; then
            log "GPU conflict -- migrating to another node"
            migrate_to_node
            break
        else
            log "Server died, restarting..."
            stop_all
            sleep 5
        fi
    else
        log "Startup failed, retrying in 30s..."
        sleep 30
    fi
done
