#!/bin/bash
#
# llm_watchdog.sh - Run LLM server on idle GPUs, yield to Slurm jobs
#
# GPU detection: cgroup filesystem (fast job arrival signal)
#              + scontrol (authoritative GPU assignment per job)
# Manages: vLLM + cloudflared tunnel
# Notifies: ntfy.sh
#

set -euxuo pipefail

# =============================================================================
# Configuration
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${1:-$SCRIPT_DIR/config.env}"
MODEL_FILE="${2:-$SCRIPT_DIR/active-model.env}"
AVAILABLE_NODES_ARG="${3:-}"

echo "[$(date)] Starting llm_watchdog.sh with args: $@" >> /tmp/llm_watchdog.log

if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    echo "ERROR: Config file not found: $CONFIG_FILE"
    echo "ERROR: Config file not found: $CONFIG_FILE" >> /tmp/llm_watchdog.log
    exit 1
fi

# Source active model profile (see models/*.env)
if [[ -f "$MODEL_FILE" ]]; then
    source "$MODEL_FILE"
else
    echo "ERROR: No active model. Run: ./switch-model.sh <model-name>"
    echo "ERROR: No active model. Run: ./switch-model.sh <model-name>" >> /tmp/llm_watchdog.log
    exit 1
fi

# Parse available nodes - use arg if provided, otherwise use config
AVAILABLE_NODES=""
if [[ -n "$AVAILABLE_NODES_ARG" ]]; then
    AVAILABLE_NODES="$AVAILABLE_NODES_ARG"
elif [[ -n "${AVAILABLE_NODES[*]:-}" ]]; then
    AVAILABLE_NODES="${AVAILABLE_NODES[*]}"
fi

# =============================================================================
# Environment Resolution (per-node CUDA setup from config.env)
# =============================================================================

if [[ "${CUDA_SETUP:-false}" == "true" ]]; then
    export LD_LIBRARY_PATH="${CUDA12_LIB}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export CUDA_HOME="${CUDA_HOME_OVERRIDE}"
fi

export HF_HOME="${HF_HOME}"
source "${LLM_VENV}/bin/activate"

# Validate required config
for var in NTFY_TOPIC LLM_VENV LLM_BIN MODEL_NAME SERVER_PORT CLOUDFLARED_BIN TUNNEL_ID NUM_GPUS; do
    if [[ -z "${!var:-}" ]]; then
        echo "ERROR: $var not set in config"
        exit 1
    fi
done

HOSTNAME_SHORT=$(hostname -s)

# Cgroup v2 path for Slurm jobs
CGROUP_BASE="/sys/fs/cgroup/system.slice/slurmstepd.scope"

# inotifywait path (compiled locally)
INOTIFYWAIT="${INOTIFYWAIT:-$HOME/local/bin/inotifywait}"

# Check if inotify is available
USE_INOTIFY=false
if [[ -x "$INOTIFYWAIT" ]]; then
    USE_INOTIFY=true
fi

# =============================================================================
# State
# =============================================================================

SERVER_PID=""
TUNNEL_PID=""
ACTIVE_GPUS=""      # comma-separated GPU indices we're running on
TOTAL_GPUS=0        # total GPUs on node (set at startup)
DOWNTIME_START=0

# =============================================================================
# Logging
# =============================================================================

# Log to both stdout and a log file
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg"
    echo "$msg" >> /tmp/llm_watchdog.log
}

# =============================================================================
# GPU Detection (nvidia-smi + scontrol + cgroup)
# =============================================================================

# Get total GPU count on this node (called once at startup)
get_total_gpus() {
    nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | wc -l
}

# Expand Slurm GPU index ranges: "0-3" → "0\n1\n2\n3", "0,2,5" → "0\n2\n5"
expand_gpu_range() {
    local input=$1
    echo "$input" | tr ',' '\n' | while read -r part; do
        if [[ "$part" == *-* ]]; then
            seq "${part%-*}" "${part#*-}"
        else
            echo "$part"
        fi
    done
}

# Query Slurm for a job's GPU indices (returns range string like "0-3" or "4,5")
get_job_gpus() {
    local jobid=$1
    scontrol show job "$jobid" -d 2>/dev/null | \
        grep -oP 'GRES=gpu[^(]*\(IDX:\K[-0-9,.]+' | head -1
}

# Get all GPU indices currently allocated by Slurm jobs on this node
get_allocated_gpus() {
    if [[ ! -d "$CGROUP_BASE" ]]; then return; fi
    for job_dir in "$CGROUP_BASE"/job_*; do
        [[ -d "$job_dir" ]] || continue
        # Only check jobs with active processes (stale cgroups have no PIDs)
        if find "$job_dir" -name cgroup.procs -exec cat {} \; 2>/dev/null | grep -q .; then
            local jobid
            jobid=$(basename "$job_dir" | sed 's/job_//')
            local gpu_range
            gpu_range=$(get_job_gpus "$jobid")
            if [[ -n "$gpu_range" ]]; then
                expand_gpu_range "$gpu_range"
            fi
        fi
    done | sort -un
}

# Compute free GPUs = all GPU indices minus Slurm-allocated
get_free_gpus() {
    local all_gpus
    all_gpus=$(seq 0 $((TOTAL_GPUS - 1)))
    local allocated
    allocated=$(get_allocated_gpus)

    if [[ -z "$allocated" ]]; then
        echo "$all_gpus"
    else
        comm -23 <(echo "$all_gpus") <(echo "$allocated")
    fi
}

# Check if a set of GPU indices overlaps with ACTIVE_GPUS
check_overlap() {
    local gpu_range=$1
    local expanded
    expanded=$(expand_gpu_range "$gpu_range")
    while read -r gpu; do
        [[ -z "$gpu" ]] && continue
        if [[ ",$ACTIVE_GPUS," == *",$gpu,"* ]]; then
            return 0  # overlap found
        fi
    done <<< "$expanded"
    return 1  # no overlap
}

# Count active Slurm jobs (cgroup-based, no RPC)
count_jobs() {
    local active=0
    if [[ -d "$CGROUP_BASE" ]]; then
        for job_dir in "$CGROUP_BASE"/job_*; do
            [[ -d "$job_dir" ]] || continue
            if find "$job_dir" -name cgroup.procs -exec cat {} \; 2>/dev/null | grep -q .; then
                ((active++))
            fi
        done
    fi
    echo "$active"
}

# List active job IDs from cgroups
list_job_ids() {
    if [[ -d "$CGROUP_BASE" ]]; then
        for job_dir in "$CGROUP_BASE"/job_*; do
            [[ -d "$job_dir" ]] || continue
            if find "$job_dir" -name cgroup.procs -exec cat {} \; 2>/dev/null | grep -q .; then
                basename "$job_dir" | sed 's/job_//'
            fi
        done
    fi
}

# Snapshot of active job IDs (cheap, no scontrol -- just cgroup directory names)
get_job_snapshot() {
    list_job_ids | sort -n | tr '\n' ','
}

# =============================================================================
# Node GPU Status (sinfo)
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
    # Find free GPUs via cgroup + scontrol
    local free_gpus
    free_gpus=$(get_free_gpus)
    local free_count
    free_count=$(echo "$free_gpus" | grep -c . || true)

    if (( free_count < NUM_GPUS )); then
        log "Only $free_count free GPUs, need $NUM_GPUS"
        return 1
    fi

    # Pick last NUM_GPUS free GPUs (Slurm allocates low indices first)
    ACTIVE_GPUS=$(echo "$free_gpus" | tail -n "$NUM_GPUS" | tr '\n' ',' | sed 's/,$//')
    log "Starting vLLM on GPUs: $ACTIVE_GPUS ($NUM_GPUS of $TOTAL_GPUS)"

    # Override --tensor-parallel-size in model profile's VLLM_ARGS
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

stop_server() {
    if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
        log "Stopping server (PID: $SERVER_PID)..."

        # Kill immediately -- GPU memory must be freed before Slurm job OOMs
        kill -KILL "$SERVER_PID" 2>/dev/null
        wait "$SERVER_PID" 2>/dev/null
        sleep 1

        # Nuclear option: if Slurm jobs are waiting for our GPUs, kill everything
        if [[ $(count_jobs) -gt 0 ]]; then
            pkill -u "$USER" 2>/dev/null || true
        fi
    fi
    SERVER_PID=""
    ACTIVE_GPUS=""
    # Clean up any orphaned vllm processes
    pkill -f "vllm serve" 2>/dev/null || true
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
    stop_tunnel
    stop_server
    sleep 2
}

# =============================================================================
# Migration
# =============================================================================

migrate_to_node() {
    log "Migration triggered: killing vLLM and preparing to move..."
    
    stop_server
    
    log "Killing all user processes on current node..."
    pkill -u "$USER" 2>/dev/null || true
    sleep 2
    
    if [[ -z "$AVAILABLE_NODES" ]]; then
        log "No available nodes configured"
        notify "No nodes available, permanently stopping" \
            "$HOSTNAME_SHORT: No nodes in AVAILABLE_NODES" 4
        pkill -u "$USER" 2>/dev/null || true
        exit 1
    fi
    
    local reverse_nodes
    reverse_nodes=$(echo "$AVAILABLE_NODES" | tr ' ' '\n' | tac | tr '\n' ' ')
    
    log "Querying sinfo for free GPUs on: $reverse_nodes"
    local target
    target=$(get_node_gpu_status "$reverse_nodes" "$NUM_GPUS")
    
    if [[ -z "$target" ]]; then
        log "No nodes available with $NUM_GPUS free GPUs"
        notify "No nodes available, permanently stopping" \
            "$HOSTNAME_SHORT: No nodes with $NUM_GPUS GPUs" 4
        pkill -u "$USER" 2>/dev/null || true
        exit 1
    fi
    
    local new_node="${target%%:*}"
    log "Starting new worker on $new_node..."
    
    ssh -o ConnectTimeout=30 "$new_node" "tmux new-session -d -s $SESSION_NAME '$SCRIPT_DIR/llm_watchdog.sh $SCRIPT_DIR/config.env $AVAILABLE_NODES'" 2>/dev/null
    local ssh_status=$?
    
    if [[ $ssh_status -ne 0 ]]; then
        log "SSH failed to $new_node"
        notify "SSH failed to $new_node, permanently stopping" \
            "$HOSTNAME_SHORT: SSH failed" 4
        pkill -u "$USER" 2>/dev/null || true
        exit 1
    fi
    
    notify "Migrated to $new_node" \
        "$HOSTNAME_SHORT -> $new_node" 3
    
    log "Migration complete to $new_node, exiting..."
    exit 0
}

# =============================================================================
# Wait for Job Change (inotify with polling fallback)
# =============================================================================
#
# Blocks until the set of active Slurm jobs changes. Returns:
#   0 = job set changed (caller should check GPU conflict)
#   1 = server died (need restart)

wait_for_change_inotify() {
    local last_snapshot="$1"
    log "Watching for job changes (inotify) on GPUs $ACTIVE_GPUS..."

    while true; do
        local event
        event=$("$INOTIFYWAIT" -t 10 -q -e create --format '%f' "$CGROUP_BASE" 2>/dev/null || true)

        # Check server health
        if [[ -n "$SERVER_PID" ]] && ! kill -0 "$SERVER_PID" 2>/dev/null; then
            log "Server died"
            return 1
        fi

        # inotify caught a new job directory
        if [[ "$event" =~ ^job_[0-9]+ ]]; then
            sleep 0.5
            return 0
        fi

        # Defensive: check on timeout in case events were missed
        local current
        current=$(get_job_snapshot)
        if [[ "$current" != "$last_snapshot" ]]; then
            return 0
        fi
    done
}

wait_for_change_polling() {
    local last_snapshot="$1"
    log "Watching for job changes (polling ${POLL_INTERVAL}s) on GPUs $ACTIVE_GPUS..."

    while true; do
        sleep "$POLL_INTERVAL"

        if [[ -n "$SERVER_PID" ]] && ! kill -0 "$SERVER_PID" 2>/dev/null; then
            log "Server died"
            return 1
        fi

        local current
        current=$(get_job_snapshot)
        if [[ "$current" != "$last_snapshot" ]]; then
            return 0
        fi
    done
}

# Wait until the set of active jobs changes. Pass current snapshot as $1.
wait_for_change() {
    local last_snapshot="${1:-}"
    if [[ "$USE_INOTIFY" == "true" ]]; then
        wait_for_change_inotify "$last_snapshot"
    else
        wait_for_change_polling "$last_snapshot"
    fi
}

# =============================================================================
# Check GPU Conflict (scontrol)
# =============================================================================
#
# Called when the set of active jobs changes. Queries scontrol for GPU
# assignments across all active jobs.
# Returns:
#   0 = conflict (a job overlaps our GPUs) -- must yield
#   1 = no conflict (all jobs on other GPUs) -- keep serving

handle_new_job() {
    # On nodes where we use ALL GPUs, any GPU job is a guaranteed conflict
    if (( NUM_GPUS >= TOTAL_GPUS )); then
        log "Using all $TOTAL_GPUS GPUs -- any job is a conflict"
        return 0
    fi

    log "Job change detected. Checking GPU assignments via scontrol..."

    # Find all active jobs and check their GPU assignments
    local conflict=false
    while read -r jobid; do
        [[ -z "$jobid" ]] && continue
        local job_gpus
        job_gpus=$(get_job_gpus "$jobid")

        if [[ -z "$job_gpus" ]]; then
            log "  Job $jobid: no GPU allocation (non-GPU job)"
            continue
        fi

        if check_overlap "$job_gpus"; then
            log "  Job $jobid: GPUs $job_gpus -- CONFLICTS with ours ($ACTIVE_GPUS)"
            conflict=true
            break
        else
            log "  Job $jobid: GPUs $job_gpus -- no conflict"
        fi
    done < <(list_job_ids)

    if $conflict; then
        return 0
    fi

    log "All jobs on other GPUs -- continuing to serve"
    return 1
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

log "=========================================="
log "LLM Watchdog on $HOSTNAME_SHORT"
log "  Model:     ${MODEL_NAME}"
log "  Venv:      ${LLM_VENV}"
if [[ "${CUDA_SETUP:-false}" == "true" ]]; then
    log "  CUDA:      CUDA_HOME=${CUDA_HOME}, LD_LIBRARY_PATH prepended"
fi
log "  GPUs:      ${NUM_GPUS} of ${TOTAL_GPUS} total"
log "  Cgroup:    $CGROUP_BASE"
log "  URL:       https://$TUNNEL_HOSTNAME"
if [[ "$USE_INOTIFY" == "true" ]]; then
    log "  Detection: cgroup (inotify) + scontrol"
else
    log "  Detection: cgroup (polling ${POLL_INTERVAL}s) + scontrol"
fi
log "=========================================="

while true; do
    # SCANNING: wait for enough free GPUs
    free_gpus=$(get_free_gpus)
    free_count=$(echo "$free_gpus" | grep -c . || true)

    if (( free_count < NUM_GPUS )); then
        if [[ $DOWNTIME_START -eq 0 ]]; then
            DOWNTIME_START=$(date +%s)
            log "Only $free_count of $NUM_GPUS GPUs free. Waiting..."
            log "  Allocated: $(get_allocated_gpus | tr '\n' ',' | sed 's/,$//')"
        fi
        sleep 5  # check every 5s while scanning (scontrol calls are infrequent)
        continue
    fi

    # STARTING: launch vLLM + tunnel on free GPUs
    if start_all; then
        if [[ $DOWNTIME_START -gt 0 ]]; then
            log "Was down for $(($(date +%s) - DOWNTIME_START))s"
            DOWNTIME_START=0
        fi

        # SERVING: watch cgroups for job changes
        snapshot=$(get_job_snapshot)
        while true; do
            if wait_for_change "$snapshot"; then
                # Job set changed -- check GPU conflict via scontrol
                if handle_new_job; then
                    # CONFLICT: migrate to another node
                    log "GPU conflict -- migrating to another node"
                    migrate_to_node
                    break
                fi
                # No conflict -- update snapshot, keep serving
                snapshot=$(get_job_snapshot)
            else
                # Server died
                log "Server died, restarting..."
                stop_all
                sleep 5
                break
            fi
        done
    else
        log "Startup failed, retrying in 30s..."
        sleep 30
    fi
done
