#!/bin/bash
#
# llm_watchdog_test.sh - TEST VERSION: simulates GPU-aware job detection
#
# Simulates Slurm jobs using a file instead of cgroups + scontrol.
#
# To simulate a job on GPUs 0,1:   echo "0,1" > ~/fake_job
# To simulate a job on GPUs 4-7:   echo "4-7" > ~/fake_job
# To clear the job:                rm ~/fake_job
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${1:-$SCRIPT_DIR/config.env}"
MODEL_FILE="${2:-$SCRIPT_DIR/active-model.env}"

if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    echo "ERROR: Config file not found: $CONFIG_FILE"
    exit 1
fi

# Source active model profile (see models/*.env)
if [[ -f "$MODEL_FILE" ]]; then
    source "$MODEL_FILE"
else
    echo "ERROR: No active model. Run: ./switch-model.sh <model-name>"
    exit 1
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

HOSTNAME_SHORT=$(hostname -s)

# TEST MODE: fake job file replaces cgroup + scontrol
# Write GPU indices to this file to simulate a Slurm job:
#   echo "0,1" > ~/fake_job     (job using GPUs 0,1)
#   echo "4-7" > ~/fake_job     (job using GPUs 4-7)
#   rm ~/fake_job               (job finished)
FAKE_JOB_FILE="$HOME/fake_job"
WATCH_DIR="$HOME"

# inotifywait path
INOTIFYWAIT="${INOTIFYWAIT:-$HOME/local/bin/inotifywait}"
USE_INOTIFY=false
[[ -x "$INOTIFYWAIT" ]] && USE_INOTIFY=true

# State
SERVER_PID=""
TUNNEL_PID=""
ACTIVE_GPUS=""
TOTAL_GPUS=0
DOWNTIME_START=0

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# =============================================================================
# GPU Detection (TEST: fake file-based)
# =============================================================================

get_total_gpus() {
    nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | wc -l
}

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

# TEST: Read fake job GPU indices from file
get_allocated_gpus() {
    if [[ -f "$FAKE_JOB_FILE" ]]; then
        local gpu_range
        gpu_range=$(cat "$FAKE_JOB_FILE" 2>/dev/null | tr -d '[:space:]')
        if [[ -n "$gpu_range" ]]; then
            expand_gpu_range "$gpu_range"
        fi
    fi
}

get_free_gpus() {
    local all_gpus
    all_gpus=$(seq 0 $((TOTAL_GPUS - 1)))
    local allocated
    allocated=$(get_allocated_gpus | sort -un)

    if [[ -z "$allocated" ]]; then
        echo "$all_gpus"
    else
        comm -23 <(echo "$all_gpus") <(echo "$allocated")
    fi
}

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

# TEST: Check if fake job file exists
count_jobs() {
    if [[ -f "$FAKE_JOB_FILE" ]]; then
        echo 1
    else
        echo 0
    fi
}

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
        log "ERROR: Tunnel failed"
        TUNNEL_PID=""
        return 1
    fi
}

stop_tunnel() {
    if [[ -n "$TUNNEL_PID" ]] && kill -0 "$TUNNEL_PID" 2>/dev/null; then
        log "Stopping tunnel..."
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
        SERVER_PID=""
        ACTIVE_GPUS=""
        return 1
    fi
}

stop_server() {
    if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
        log "Stopping server..."
        kill -KILL "$SERVER_PID" 2>/dev/null
        wait "$SERVER_PID" 2>/dev/null
        sleep 1
        if [[ $(count_jobs) -gt 0 ]]; then
            pkill -u "$USER" 2>/dev/null || true
        fi
    fi
    SERVER_PID=""
    ACTIVE_GPUS=""
    pkill -f "vllm serve" 2>/dev/null || true
}

start_all() {
    if ! start_server; then return 1; fi
    start_tunnel || { stop_server; return 1; }
    notify "vLLM Server Online (TEST)" \
        "$HOSTNAME_SHORT: GPUs $ACTIVE_GPUS ($NUM_GPUS of $TOTAL_GPUS)" 3
    return 0
}

stop_all() {
    stop_tunnel
    stop_server
    sleep 2
}

# =============================================================================
# Wait for Fake Job
# =============================================================================

wait_for_job() {
    log "============================================"
    log "TEST MODE: Watching for file: $FAKE_JOB_FILE"
    log "  Our GPUs: $ACTIVE_GPUS"
    log "  To simulate job on GPUs 0,1:   echo '0,1' > ~/fake_job"
    log "  To simulate job on GPUs 4-7:   echo '4-7' > ~/fake_job"
    log "  To clear job:                  rm ~/fake_job"
    log "============================================"

    if [[ "$USE_INOTIFY" == "true" ]]; then
        log "Using inotify (instant detection)..."
        while [[ ! -f "$FAKE_JOB_FILE" ]]; do
            "$INOTIFYWAIT" -t 10 -q -e create -e moved_to "$WATCH_DIR" 2>/dev/null || true
            if [[ -n "$SERVER_PID" ]] && ! kill -0 "$SERVER_PID" 2>/dev/null; then
                log "Server died"
                return 1
            fi
        done
    else
        log "Using polling..."
        while [[ ! -f "$FAKE_JOB_FILE" ]]; do
            sleep 1
            if [[ -n "$SERVER_PID" ]] && ! kill -0 "$SERVER_PID" 2>/dev/null; then
                log "Server died"
                return 1
            fi
        done
    fi
    return 0
}

# TEST: Check GPU overlap with fake job
handle_new_job() {
    if (( NUM_GPUS >= TOTAL_GPUS )); then
        log "Using all $TOTAL_GPUS GPUs -- any job is a conflict"
        return 0
    fi

    local fake_gpus
    fake_gpus=$(cat "$FAKE_JOB_FILE" 2>/dev/null | tr -d '[:space:]')
    if [[ -z "$fake_gpus" ]]; then
        log "Fake job file empty -- treating as non-GPU job"
        return 1
    fi

    log "Fake job using GPUs: $fake_gpus"
    if check_overlap "$fake_gpus"; then
        log "  CONFLICT with our GPUs ($ACTIVE_GPUS)"
        return 0
    else
        log "  No conflict -- our GPUs ($ACTIVE_GPUS) are safe"
        return 1
    fi
}

# =============================================================================
# Cleanup
# =============================================================================

cleanup() {
    log "Shutting down..."
    stop_all
    notify "vLLM Watchdog Stopped (TEST)" "$HOSTNAME_SHORT" 3
    exit 0
}

trap cleanup SIGTERM SIGINT SIGHUP

# Remove any existing fake job file
rm -f "$FAKE_JOB_FILE"

# =============================================================================
# Main Loop
# =============================================================================

TOTAL_GPUS=$(get_total_gpus)

log "=========================================="
log "LLM Watchdog TEST MODE on $HOSTNAME_SHORT"
log "=========================================="
log "  Model:     ${MODEL_NAME}"
log "  Venv:      ${LLM_VENV}"
if [[ "${CUDA_SETUP:-false}" == "true" ]]; then
    log "  CUDA:      CUDA_HOME=${CUDA_HOME}, LD_LIBRARY_PATH prepended"
fi
log "  GPUs:      ${NUM_GPUS} of ${TOTAL_GPUS} total"
log "  URL:       https://$TUNNEL_HOSTNAME"
log ""
log "  TRIGGER FILE: $FAKE_JOB_FILE"
log "  echo '0,1' > ~/fake_job   → simulate job on GPUs 0,1"
log "  echo '4-7' > ~/fake_job   → simulate job on GPUs 4-7"
log "  rm ~/fake_job              → job finished"
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
        # Wait for fake job to be removed
        if [[ "$USE_INOTIFY" == "true" ]]; then
            "$INOTIFYWAIT" -t 10 -q -e delete "$WATCH_DIR" 2>/dev/null || true
        else
            sleep 1
        fi
        continue
    fi

    # STARTING
    if start_all; then
        if [[ $DOWNTIME_START -gt 0 ]]; then
            log "Was down for $(($(date +%s) - DOWNTIME_START))s"
            DOWNTIME_START=0
        fi

        # SERVING: watch for fake jobs
        while true; do
            if wait_for_job; then
                if handle_new_job; then
                    log "GPU conflict -- yielding GPUs $ACTIVE_GPUS"
                    stop_all
                    DOWNTIME_START=$(date +%s)
                    notify "vLLM Server Yielding (TEST)" \
                        "$HOSTNAME_SHORT: Fake job on our GPUs ($ACTIVE_GPUS)" 4
                    break
                fi
                # No conflict -- wait for fake job to clear, then loop back
                log "Waiting for fake job to clear before checking again..."
                if [[ "$USE_INOTIFY" == "true" ]]; then
                    while [[ -f "$FAKE_JOB_FILE" ]]; do
                        "$INOTIFYWAIT" -t 10 -q -e delete "$WATCH_DIR" 2>/dev/null || true
                    done
                else
                    while [[ -f "$FAKE_JOB_FILE" ]]; do sleep 1; done
                fi
            else
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
