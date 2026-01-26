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

# If node specified, SSH to it
if [[ -n "$NODE" ]]; then
    echo "Starting watchdog on $NODE..."
    ssh "$NODE" "tmux kill-session -t $SESSION_NAME 2>/dev/null || true; \
                 tmux new-session -d -s $SESSION_NAME '$SCRIPT_DIR/llm_watchdog.sh $SCRIPT_DIR/config.env'"
    echo "Done. View with: ssh $NODE \"tmux attach -t $SESSION_NAME\""
else
    # Running locally
    echo "Starting watchdog locally..."
    tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true
    tmux new-session -d -s "$SESSION_NAME" "$SCRIPT_DIR/llm_watchdog.sh $SCRIPT_DIR/config.env"
    echo "Done. View with: tmux attach -t $SESSION_NAME"
fi
