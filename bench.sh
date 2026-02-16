#!/bin/bash
#
# bench.sh - Benchmark the running vLLM server
#
# Uses the same config.env + active-model.env as the watchdog,
# then runs `vllm bench serve` against the live server.
#
# Usage:
#   ./bench.sh                  # default: 20 prompts, random 128in/256out
#   ./bench.sh quick            # quick smoke test (5 prompts)
#   ./bench.sh full             # thorough benchmark (100 prompts)
#   ./bench.sh stress           # sustained load (200 prompts, high concurrency)
#   ./bench.sh sweep            # sweep across concurrency levels
#   ./bench.sh -- <extra args>  # pass extra args directly to vllm bench serve
#
# Results are saved to bench-results/
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.env"
MODEL_FILE="$SCRIPT_DIR/active-model.env"
RESULTS_DIR="$SCRIPT_DIR/bench-results"

# -----------------------------------------------------------------------------
# Load config
# -----------------------------------------------------------------------------

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Config not found: $CONFIG_FILE"
    exit 1
fi
source "$CONFIG_FILE"

if [[ ! -f "$MODEL_FILE" ]]; then
    echo "ERROR: No active model. Run: ./switch-model.sh <model-name>"
    exit 1
fi
source "$MODEL_FILE"

# Environment resolution (same logic as watchdog)
if [[ -n "${VENV_PROFILE:-}" ]]; then
    LLM_VENV="${SCRIPT_DIR}/${VENV_PROFILE}"
fi
if [[ "${REQUIRES_CUDA13:-false}" == "true" ]]; then
    export LD_LIBRARY_PATH="${CUDA12_LIB}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export CUDA_HOME="${CUDA_HOME_OVERRIDE}"
fi
export HF_HOME="${HF_HOME}"
source "${LLM_VENV}/bin/activate"

# Extract the served model name from VLLM_ARGS (--served-model-name <name>)
SERVED_MODEL=$(echo "$VLLM_ARGS" | grep -oP '(?<=--served-model-name\s)\S+' || true)
if [[ -z "$SERVED_MODEL" ]]; then
    SERVED_MODEL="$MODEL_NAME"
fi

BASE_URL="http://localhost:${SERVER_PORT}"
TIMESTAMP=$(date '+%Y%m%d-%H%M%S')
HOSTNAME_SHORT=$(hostname -s)

# -----------------------------------------------------------------------------
# Profiles
# -----------------------------------------------------------------------------

PROFILE="${1:-default}"
shift 2>/dev/null || true  # consume the profile arg

# Defaults
NUM_PROMPTS=20
REQUEST_RATE="inf"
MAX_CONCURRENCY=4
INPUT_LEN=128
OUTPUT_LEN=256
DATASET="random"
EXTRA_ARGS=()

case "$PROFILE" in
    quick)
        NUM_PROMPTS=5
        MAX_CONCURRENCY=1
        INPUT_LEN=64
        OUTPUT_LEN=128
        ;;
    default)
        # defaults above
        ;;
    full)
        NUM_PROMPTS=100
        MAX_CONCURRENCY=8
        INPUT_LEN=512
        OUTPUT_LEN=512
        ;;
    stress)
        NUM_PROMPTS=200
        MAX_CONCURRENCY=16
        INPUT_LEN=1024
        OUTPUT_LEN=512
        ;;
    sweep)
        # handled separately below
        ;;
    --)
        # everything after -- goes to vllm bench serve
        EXTRA_ARGS=("$@")
        ;;
    *)
        echo "Unknown profile: $PROFILE"
        echo "Usage: $0 [quick|default|full|stress|sweep|-- <args>]"
        exit 1
        ;;
esac

# -----------------------------------------------------------------------------
# Pre-flight checks
# -----------------------------------------------------------------------------

echo "============================================"
echo "  vLLM Benchmark -- $HOSTNAME_SHORT"
echo "============================================"
echo "  Model:    $SERVED_MODEL"
echo "  Server:   $BASE_URL"
echo "  Profile:  $PROFILE"
echo "============================================"

if ! curl -sf "${BASE_URL}/health" >/dev/null 2>&1; then
    echo "ERROR: Server not responding at ${BASE_URL}/health"
    echo "Is the watchdog running?"
    exit 1
fi
echo "Server is healthy."

mkdir -p "$RESULTS_DIR"

# -----------------------------------------------------------------------------
# Run benchmark
# -----------------------------------------------------------------------------

run_bench() {
    local tag="$1"
    shift
    local outfile="${RESULTS_DIR}/${TIMESTAMP}-${SERVED_MODEL}-${tag}.txt"

    echo ""
    echo "--- $tag ---"
    echo "  prompts=$NUM_PROMPTS  concurrency=$MAX_CONCURRENCY  input=$INPUT_LEN  output=$OUTPUT_LEN"
    echo "  saving to: $(basename "$outfile")"
    echo ""

    vllm bench serve \
        --model "$SERVED_MODEL" \
        --tokenizer "$MODEL_NAME" \
        --base-url "$BASE_URL" \
        --endpoint /v1/completions \
        --dataset-name "$DATASET" \
        --num-prompts "$NUM_PROMPTS" \
        --request-rate "$REQUEST_RATE" \
        --max-concurrency "$MAX_CONCURRENCY" \
        --random-input-len "$INPUT_LEN" \
        --random-output-len "$OUTPUT_LEN" \
        "$@" \
        2>&1 | tee "$outfile"

    echo ""
    echo "Results saved: $outfile"
}

if [[ "$PROFILE" == "sweep" ]]; then
    # Sweep across concurrency levels to find saturation point
    echo ""
    echo "Sweeping concurrency: 1, 2, 4, 8, 16"
    echo ""
    for conc in 1 2 4 8 16; do
        MAX_CONCURRENCY=$conc
        NUM_PROMPTS=$((conc * 10))
        INPUT_LEN=256
        OUTPUT_LEN=256
        run_bench "sweep-c${conc}" "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"
    done
    echo ""
    echo "Sweep complete. Results in: $RESULTS_DIR"
elif [[ "$PROFILE" == "--" ]]; then
    run_bench "custom" "${EXTRA_ARGS[@]}"
else
    run_bench "$PROFILE" "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"
fi

echo ""
echo "Done."
