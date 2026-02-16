# llm-watchdog

A daemon for running vLLM servers on idle GPUs at Purdue University's compute clusters, with automatic Slurm job yielding and public access via Cloudflare tunnel.

## Features

- **Partial GPU utilization** -- claims N GPUs (configurable), coexists with Slurm jobs on remaining GPUs
- **GPU-aware yielding** -- only yields when a Slurm job conflicts with our GPUs, not on every job
- **Hybrid detection** -- cgroup filesystem for instant job arrival signal, `scontrol` for authoritative GPU assignment
- **Multi-model profiles** -- swap models with one command (`./switch-model.sh`)
- **Per-node CUDA config** -- nodes needing CUDA overrides set `CUDA_SETUP=true` in config.env
- **Public access** -- Cloudflare tunnel at `https://purduechat.dwijen.dev`
- **Notifications** -- ntfy.sh alerts for state changes

## Quick Start

```bash
ssh gilbreth-m001
cd ~/llm-watchdog

# List available models
./switch-model.sh
#   * glm-4.7-flash  (active)
#     minimax-m2.5
#     qwen3-coder-fp8

# Switch models
./switch-model.sh minimax-m2.5

# Start the watchdog
./start.sh
```

## File Layout

```
llm-watchdog/
├── llm_watchdog.sh          # daemon (GPU-aware, handles all models)
├── start.sh                 # tmux launcher
├── switch-model.sh          # list/switch model profiles
├── llm_watchdog_test.sh     # test version (fake job file instead of cgroups)
├── bench.sh                 # benchmark the running server
├── config.env               # infrastructure config (per-node)
├── active-model.env -> models/<current>.env
├── models/
│   ├── glm-4.7-flash.env       # works on any node
│   ├── minimax-m2.5.env         # needs CUDA >= 12.8
│   └── qwen3-coder-fp8.env     # needs CUDA >= 12.8
├── bench-results/           # benchmark output
└── .venv/                   # vLLM virtual environment
```

## Model Profiles

Each model is a file in `models/` with these variables:

| Variable | Required | Description |
|----------|----------|-------------|
| `MODEL_NAME` | yes | HuggingFace model ID or local path |
| `VLLM_ARGS` | yes | Arguments passed to `vllm serve` |
| `export ...` | no | Per-model environment variables |

Model profiles are node-agnostic. The watchdog overrides `--tensor-parallel-size` with `NUM_GPUS` from config.env at runtime. CUDA overrides are per-node in `config.env`. FP8 models will fail on nodes without sufficient CUDA.

### Adding a New Model

```bash
cat > models/my-model.env << 'EOF'
MODEL_NAME="org/MyModel"

VLLM_ARGS="--tensor-parallel-size 4 \
    --served-model-name my-model"
EOF

./switch-model.sh my-model
```

## Configuration

### `config.env`

Infrastructure settings, configured per-node:

```bash
# GPU allocation
NUM_GPUS=4   # How many GPUs to claim for vLLM

# Notifications
NTFY_TOPIC="purduechat-watchdog"

# CUDA overrides (uncomment on nodes needing CUDA 13 for FP8)
#CUDA_SETUP="true"
#CUDA12_LIB="/apps/spack/gilbreth-r9/apps/cuda/12.6.0-gcc-11.5.0-a7cv7sp/lib64"
#CUDA_HOME_OVERRIDE="/apps/external/cuda-toolkit/13.1.0"

# vLLM
LLM_VENV="/home/dchawra/llm-watchdog/.venv"
SERVER_PORT="8000"
HF_HOME="/scratch/gilbreth/dchawra/cache/huggingface"

# Cloudflare tunnel
TUNNEL_HOSTNAME="purduechat.dwijen.dev"

# Detection
POLL_INTERVAL="0.25"
```

## Endpoints

| Endpoint | URL |
|----------|-----|
| Health check | `https://purduechat.dwijen.dev/health` |
| Chat API | `https://purduechat.dwijen.dev/v1/chat/completions` |

## Detection

- **Job arrival**: cgroup v2 filesystem monitoring (`/sys/fs/cgroup/system.slice/slurmstepd.scope/job_*`)
- **GPU assignment**: `scontrol show job JOBID -d` (parses `GRES=gpu:...(IDX:N-M)`)
- **Latency**: Instant with inotify, ~0.25s with polling fallback
- **Behavior**: On nodes with spare GPUs (e.g. 8 total, 4 claimed), only yields when new job's GPUs overlap with ours. On nodes using all GPUs, any GPU job triggers yield (same as before).

## Benchmarking

```bash
./bench.sh              # default profile (20 prompts)
./bench.sh quick        # smoke test (5 prompts)
./bench.sh full         # thorough (100 prompts)
./bench.sh stress       # sustained load (200 prompts)
./bench.sh sweep        # sweep concurrency levels
```

Results saved to `bench-results/`.

## Hardware

- **Gilbreth**: 4x NVIDIA A30 per node
- **Gautschi**: 8x NVIDIA H200 per node

## License

MIT
