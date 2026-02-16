#!/bin/bash
#
# switch-model.sh - Switch the active model profile
#
# Usage:
#   ./switch-model.sh                  # list available models
#   ./switch-model.sh glm-4.7-flash   # switch to GLM
#   ./switch-model.sh minimax-m2.5    # switch to MiniMax (CUDA 13)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELS_DIR="$SCRIPT_DIR/models"
LINK="$SCRIPT_DIR/active-model.env"

# No args -> list available models
if [[ $# -eq 0 ]]; then
    current=$(readlink "$LINK" 2>/dev/null | sed "s|models/||;s|\.env$||" || echo "none")
    echo "Available models:"
    for f in "$MODELS_DIR"/*.env; do
        name=$(basename "$f" .env)
        # Show environment tag
        env_tag=""
        if grep -q 'REQUIRES_CUDA13="true"' "$f" 2>/dev/null; then
            env_tag=" [cuda13]"
        fi
        if [[ "$name" == "$current" ]]; then
            echo "  * $name${env_tag}  (active)"
        else
            echo "    $name${env_tag}"
        fi
    done
    echo ""
    echo "Usage: $0 <model-name>"
    echo "Restart the watchdog after switching."
    exit 0
fi

MODEL="$1"
PROFILE="$MODELS_DIR/${MODEL}.env"

if [[ ! -f "$PROFILE" ]]; then
    echo "ERROR: No profile found: $PROFILE"
    echo "Available: $(ls "$MODELS_DIR"/*.env 2>/dev/null | xargs -n1 basename | sed 's/.env$//' | tr '\n' ' ')"
    exit 1
fi

ln -sf "models/${MODEL}.env" "$LINK"
echo "Switched to: $MODEL"
echo ""
# Show a preview of the model config
grep -E "^(MODEL_NAME|VLLM_ARGS|VENV_PROFILE|REQUIRES_CUDA13|export )" "$PROFILE" | head -5
echo ""
echo "Restart the watchdog to apply."
