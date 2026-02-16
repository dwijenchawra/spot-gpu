#!/bin/bash
#
# llm_watchdog.sh - Run LLM server on idle Gilbreth nodes, yield to Slurm jobs
#
# Detection: cgroup filesystem (zero RPC calls to Slurm controller)
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
# Environment Resolution
# =============================================================================
# Model profiles can override the venv and request CUDA 13 setup.

# Resolve venv: model's VENV_PROFILE overrides config's LLM_VENV
if [[ -n "${VENV_PROFILE:-}" ]]; then
    LLM_VENV="${SCRIPT_DIR}/${VENV_PROFILE}"
    LLM_BIN="${LLM_VENV}/bin/vllm"
fi

# CUDA 13 environment (only when model requires it)
if [[ "${REQUIRES_CUDA13:-false}" == "true" ]]; then
    export LD_LIBRARY_PATH="${CUDA12_LIB}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export CUDA_HOME="${CUDA_HOME_OVERRIDE}"
fi

# HF cache (always set, single location)
export HF_HOME="${HF_HOME}"

# Activate the resolved venv
source "${LLM_VENV}/bin/activate"

# Validate required config
for var in NTFY_TOPIC LLM_VENV LLM_BIN MODEL_NAME SERVER_PORT CLOUDFLARED_BIN TUNNEL_ID; do
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
INOTIFY_PID=""
DOWNTIME_START=0

# =============================================================================
# Logging
# =============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# =============================================================================
# Cgroup-based Job Detection (NO RPC to Slurm controller)
# =============================================================================
#
# NOTE: Job directories can persist after jobs end (stale cgroups).
# We must check for ACTIVE PROCESSES, not just directory existence.
# A job is "active" if any cgroup.procs file under job_* contains PIDs.

count_jobs() {
    local active=0
    if [[ -d "$CGROUP_BASE" ]]; then
        while IFS= read -r job_dir; do
            [[ -d "$job_dir" ]] || continue
            if find "$job_dir" -name cgroup.procs -exec cat {} \; 2>/dev/null | grep -q .; then
                ((active++))
            fi
        done < <(find "$CGROUP_BASE" -maxdepth 1 -type d -name 'job_*' 2>/dev/null)
    fi
    echo "$active"
}

list_jobs() {
    if [[ -d "$CGROUP_BASE" ]]; then
        while IFS= read -r job_dir; do
            [[ -d "$job_dir" ]] || continue
            if find "$job_dir" -name cgroup.procs -exec cat {} \; 2>/dev/null | grep -q .; then
                basename "$job_dir" | sed 's/job_//'
            fi
        done < <(find "$CGROUP_BASE" -maxdepth 1 -type d -name 'job_*' 2>/dev/null)
    fi
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
# LLM Server
# =============================================================================

start_server() {
    log "Starting LLM server..."

    "$LLM_BIN" serve "$MODEL_NAME" \
        ${VLLM_ARGS:-} &
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
            return 1
        fi
        sleep 5
        ((retries++))
    done

    if kill -0 "$SERVER_PID" 2>/dev/null; then
        log "Server started (PID: $SERVER_PID)"
        return 0
    else
        log "ERROR: Server failed"
        SERVER_PID=""
        return 1
    fi
}

stop_server() {
    if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
        log "Stopping server (PID: $SERVER_PID)..."

        # Graceful shutdown
        kill -TERM "$SERVER_PID" 2>/dev/null
        sleep 3

        # Force kill if still running
        if kill -0 "$SERVER_PID" 2>/dev/null; then
            kill -KILL "$SERVER_PID" 2>/dev/null
            wait "$SERVER_PID" 2>/dev/null
        fi
        sleep 3
        if [[ $(list_jobs) -gt 0 ]]; then
            pkill -u "$USER"
        fi
    fi
    SERVER_PID=""
    # Clean up vllm processes
    pkill -f "vllm serve" 2>/dev/null || true
}

# =============================================================================
# Combined Start/Stop
# =============================================================================

start_all() {
    if [[ $(count_jobs) -gt 0 ]]; then
        log "Jobs detected, aborting startup"
        return 1
    fi

    if ! start_server; then
        return 1
    fi

    if ! start_tunnel; then
        stop_server
        return 1
    fi

    local gpu_count=$(nvidia-smi -L 2>/dev/null | wc -l || echo "?")
    notify "vLLM Server Online" \
        "$HOSTNAME_SHORT: ${gpu_count} GPUs
https://${TUNNEL_HOSTNAME}" \
        3
    return 0
}

stop_all() {
    # Kill any inotify watcher
    if [[ -n "$INOTIFY_PID" ]] && kill -0 "$INOTIFY_PID" 2>/dev/null; then
        kill -TERM "$INOTIFY_PID" 2>/dev/null
        wait "$INOTIFY_PID" 2>/dev/null
    fi
    INOTIFY_PID=""

    stop_tunnel
    stop_server
    sleep 2
}

# =============================================================================
# Wait Functions (inotify with polling fallback)
# =============================================================================

wait_for_job_inotify() {
    log "Watching for jobs (inotify)..."

    # inotifywait blocks until a job_* directory is created
    # We watch for CREATE events on directories matching job_*
    while true; do
        # Use timeout to periodically check server health
        local event=$("$INOTIFYWAIT" -t 10 -q -e create --format '%f' "$CGROUP_BASE" 2>/dev/null || true)

        # Check if server is still running
        if [[ -n "$SERVER_PID" ]] && ! kill -0 "$SERVER_PID" 2>/dev/null; then
            log "Server died"
            return 1
        fi

        # If event matches job_*, check if it has active processes
        if [[ "$event" =~ ^job_[0-9]+ ]]; then
            # Brief delay for processes to populate
            sleep 0.5
            if [[ $(count_jobs) -gt 0 ]]; then
                return 0
            fi
        fi
    done
}

wait_for_job_polling() {
    log "Watching for jobs (polling every ${POLL_INTERVAL}s)..."

    while [[ $(count_jobs) -eq 0 ]]; do
        sleep "$POLL_INTERVAL"
        if [[ -n "$SERVER_PID" ]] && ! kill -0 "$SERVER_PID" 2>/dev/null; then
            log "Server died"
            return 1
        fi
    done
    return 0
}

wait_for_job() {
    if [[ "$USE_INOTIFY" == "true" ]]; then
        wait_for_job_inotify
    else
        wait_for_job_polling
    fi
}

wait_for_no_jobs_inotify() {
    log "Waiting for jobs to finish (inotify)..."

    while [[ $(count_jobs) -gt 0 ]]; do
        # Watch for DELETE events (job directory removal)
        # Timeout every 30s to recheck in case we missed an event
        "$INOTIFYWAIT" -t 30 -q -e delete "$CGROUP_BASE" 2>/dev/null || true
    done
    log "All jobs finished"
}

wait_for_no_jobs_polling() {
    log "Waiting for jobs to finish (polling)..."
    while [[ $(count_jobs) -gt 0 ]]; do
        sleep "$POLL_INTERVAL"
    done
    log "All jobs finished"
}

wait_for_no_jobs() {
    if [[ "$USE_INOTIFY" == "true" ]]; then
        wait_for_no_jobs_inotify
    else
        wait_for_no_jobs_polling
    fi
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

log "=========================================="
log "LLM Watchdog on $HOSTNAME_SHORT"
log "  Model:  ${MODEL_NAME}"
log "  Venv:   ${LLM_VENV}"
if [[ "${REQUIRES_CUDA13:-false}" == "true" ]]; then
    log "  CUDA:   CUDA_HOME=${CUDA_HOME}, LD_LIBRARY_PATH prepended"
fi
log "  Cgroup: $CGROUP_BASE"
log "  URL:    https://$TUNNEL_HOSTNAME"
if [[ "$USE_INOTIFY" == "true" ]]; then
    log "  Detection: inotify (instant)"
else
    log "  Detection: polling (${POLL_INTERVAL}s)"
fi
log "=========================================="

while true; do
    job_count=$(count_jobs)

    if [[ $job_count -gt 0 ]]; then
        log "Found $job_count job(s): $(list_jobs | tr '\n' ' ')"
        DOWNTIME_START=$(date +%s)
        wait_for_no_jobs
    fi

    if start_all; then
        if [[ $DOWNTIME_START -gt 0 ]]; then
            log "Was down for $(($(date +%s) - DOWNTIME_START))s"
            DOWNTIME_START=0
        fi

        if wait_for_job; then
            log "Job detected: $(list_jobs | tr '\n' ' ')"
            stop_all
            DOWNTIME_START=$(date +%s)
            notify "vLLM Server Yielding" "$HOSTNAME_SHORT: Slurm job detected" 4
        else
            stop_all
            sleep 5
        fi
    else
        log "Startup failed, retrying in 30s..."
        sleep 30
    fi
done
