#!/bin/bash
#
# llm_watchdog_test.sh - TEST VERSION: watches temp file instead of cgroups
#
# To simulate a job: touch ~/fake_job
# To clear the job:  rm ~/fake_job
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${1:-$SCRIPT_DIR/config.env}"

if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    echo "ERROR: Config file not found: $CONFIG_FILE"
    exit 1
fi

HOSTNAME_SHORT=$(hostname -s)

# TEST MODE: Watch for this file instead of cgroups
FAKE_JOB_FILE="$HOME/fake_job"
WATCH_DIR="$HOME"

# inotifywait path
INOTIFYWAIT="${INOTIFYWAIT:-$HOME/local/bin/inotifywait}"
USE_INOTIFY=false
[[ -x "$INOTIFYWAIT" ]] && USE_INOTIFY=true

# State
SERVER_PID=""
TUNNEL_PID=""
DOWNTIME_START=0

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# TEST: Check if fake job file exists
count_jobs() {
    if [[ -f "$FAKE_JOB_FILE" ]]; then
        echo 1
    else
        echo 0
    fi
}

list_jobs() {
    if [[ -f "$FAKE_JOB_FILE" ]]; then
        echo "fake_job"
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

start_server() {
    log "Starting LLM server..."
    "$LLAMA_SERVER_BIN" \
        -m "$MODEL_PATH" \
        --host 0.0.0.0 \
        --port "$SERVER_PORT" \
        -ngl 99 \
        ${LLAMA_EXTRA_ARGS:-} &
    SERVER_PID=$!

    log "Waiting for server to initialize (this may take a few minutes)..."
    local retries=0
    while [[ $retries -lt 120 ]]; do
        if curl -sf "http://localhost:${SERVER_PORT}/health" >/dev/null 2>&1; then
            log "Server is healthy!"
            break
        fi
        if ! kill -0 "$SERVER_PID" 2>/dev/null; then
            log "ERROR: Server died"
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
        SERVER_PID=""
        return 1
    fi
}

stop_server() {
    if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
        log "Stopping server..."
        kill -TERM "$SERVER_PID" 2>/dev/null
        sleep 3
        kill -KILL "$SERVER_PID" 2>/dev/null
        wait "$SERVER_PID" 2>/dev/null
    fi
    SERVER_PID=""
    pkill -f "llama-server.*--port ${SERVER_PORT}" 2>/dev/null || true
}

start_all() {
    if [[ $(count_jobs) -gt 0 ]]; then
        log "Fake job exists, aborting startup"
        return 1
    fi
    start_server || return 1
    start_tunnel || { stop_server; return 1; }

    local gpu_count=$(nvidia-smi -L 2>/dev/null | wc -l || echo "?")
    notify "LLM Server Online (TEST)" "$HOSTNAME_SHORT: ${gpu_count} GPUs - https://${TUNNEL_HOSTNAME}" 3
    return 0
}

stop_all() {
    stop_tunnel
    stop_server
    sleep 2
}

# TEST: Watch for fake_job file creation using inotify
wait_for_job() {
    log "============================================"
    log "TEST MODE: Watching for file: $FAKE_JOB_FILE"
    log "To trigger shutdown, run:  touch ~/fake_job"
    log "============================================"

    if [[ "$USE_INOTIFY" == "true" ]]; then
        log "Using inotify (instant detection)..."
        while [[ ! -f "$FAKE_JOB_FILE" ]]; do
            "$INOTIFYWAIT" -t 10 -q -e create -e moved_to "$WATCH_DIR" 2>/dev/null || true
            # Check server health
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

# TEST: Watch for fake_job file deletion
wait_for_no_jobs() {
    log "Waiting for fake job to clear (rm ~/fake_job)..."
    if [[ "$USE_INOTIFY" == "true" ]]; then
        while [[ -f "$FAKE_JOB_FILE" ]]; do
            "$INOTIFYWAIT" -t 10 -q -e delete "$WATCH_DIR" 2>/dev/null || true
        done
    else
        while [[ -f "$FAKE_JOB_FILE" ]]; do
            sleep 1
        done
    fi
    log "Fake job cleared"
}

cleanup() {
    log "Shutting down..."
    stop_all
    notify "LLM Watchdog Stopped (TEST)" "$HOSTNAME_SHORT" 3
    exit 0
}

trap cleanup SIGTERM SIGINT SIGHUP

# Remove any existing fake job file
rm -f "$FAKE_JOB_FILE"

log "=========================================="
log "LLM Watchdog TEST MODE on $HOSTNAME_SHORT"
log "=========================================="
log "  Model:  $(basename "$MODEL_PATH")"
log "  URL:    https://$TUNNEL_HOSTNAME"
log "  Detection: ${USE_INOTIFY:+inotify}${USE_INOTIFY:-polling}"
log ""
log "  TRIGGER FILE: $FAKE_JOB_FILE"
log "  To simulate job:  touch ~/fake_job"
log "  To clear job:     rm ~/fake_job"
log "=========================================="

while true; do
    if [[ -f "$FAKE_JOB_FILE" ]]; then
        log "Fake job file exists, waiting for removal..."
        DOWNTIME_START=$(date +%s)
        wait_for_no_jobs
    fi

    if start_all; then
        if [[ $DOWNTIME_START -gt 0 ]]; then
            log "Was down for $(($(date +%s) - DOWNTIME_START))s"
            DOWNTIME_START=0
        fi

        if wait_for_job; then
            log "!!! FAKE JOB DETECTED - SHUTTING DOWN !!!"
            stop_all
            DOWNTIME_START=$(date +%s)
            notify "LLM Server Yielding (TEST)" "$HOSTNAME_SHORT: Fake job detected" 4
        else
            stop_all
            sleep 5
        fi
    else
        log "Startup failed, retrying in 30s..."
        sleep 30
    fi
done
