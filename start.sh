#!/bin/bash
#
# start.sh - Launch the LLM watchdog in a tmux session
#
# Usage: ./start.sh [node]
#   node: gilbreth-m001, gilbreth-m002, etc. (default: current host if on compute node)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NODE="${1:-}"
SESSION_NAME="llm_watchdog"

# Load available nodes from config if not provided
if [[ -z "${2:-}" ]]; then
    source "$SCRIPT_DIR/config.env" 2>/dev/null || true
    if [[ -n "${AVAILABLE_NODES:-}" ]]; then
        NODE_LIST="${AVAILABLE_NODES[*]}"
        NODE_LIST="${NODE_LIST// /,}"
    else
        NODE_LIST=""
    fi
else
    NODE_LIST="$2"
fi

# If node specified, SSH to it
if [[ -n "$NODE" ]]; then
    echo "Starting watchdog on $NODE..."
    ssh "$NODE" "tmux kill-session -t $SESSION_NAME 2>/dev/null || true; \
                 tmux new-session -d -s $SESSION_NAME '$SCRIPT_DIR/llm_watchdog.sh $SCRIPT_DIR/config.env $SCRIPT_DIR/active-model.env $NODE_LIST' 2>&1; \
                 sleep 2; \
                 tmux capture-pane -t $SESSION_NAME -p | tail -20"
    echo "Done. View with: ssh $NODE \"tmux attach -t $SESSION_NAME\""
else
    # Running locally
    echo "Starting watchdog locally..."
    tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true
    tmux new-session -d -s "$SESSION_NAME" "$SCRIPT_DIR/llm_watchdog.sh $SCRIPT_DIR/config.env $SCRIPT_DIR/active-model.env $NODE_LIST"
    sleep 2
    echo "--- Last 20 lines of session ---"
    tmux capture-pane -t "$SESSION_NAME" -p | tail -20
    echo "--- End ---"
    echo "Done. View with: tmux attach -t $SESSION_NAME"
fi
