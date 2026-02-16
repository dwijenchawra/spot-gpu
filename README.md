# llm-watchdog

A daemon for running vLLM servers on idle GPUs at Purdue University's Gilbreth cluster, with automatic Slurm job yielding and public access via Cloudflare tunnel.

## Features

- **Idle GPU utilization** -- starts vLLM when GPUs are idle, yields instantly when Slurm jobs appear
- **Zero RPC detection** -- monitors cgroup filesystem directly, no Slurm controller calls
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
├── llm_watchdog.sh          # unified daemon (handles all models)
├── start.sh                 # tmux launcher
├── switch-model.sh          # list/switch model profiles
├── llm_watchdog_test.sh     # test version (fake job file instead of cgroups)
├── bench.sh                 # benchmark the running server
├── config.env               # infrastructure config (shared across models)
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

Model profiles are node-agnostic. CUDA environment overrides are configured per-node in `config.env`. FP8 models will fail on nodes without sufficient CUDA.

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

Infrastructure settings shared across all models:

```bash
# Notifications
NTFY_TOPIC="purduechat-watchdog"

# CUDA overrides (uncomment on nodes needing CUDA 13 for FP8)
#CUDA_SETUP="true"
#CUDA12_LIB="/apps/spack/gilbreth-r9/apps/cuda/12.6.0-gcc-11.5.0-a7cv7sp/lib64"
#CUDA_HOME_OVERRIDE="/apps/external/cuda-toolkit/13.1.0"

# vLLM defaults
LLM_VENV="/home/dchawra/llm-watchdog/.venv"
SERVER_PORT="8000"
HF_HOME="/scratch/gilbreth/dchawra/cache/huggingface"

# Cloudflare tunnel
TUNNEL_HOSTNAME="purduechat.dwijen.dev"

# Detection
POLL_INTERVAL="0.25"  # ~1s worst case
```

## Endpoints

| Endpoint | URL |
|----------|-----|
| Health check | `https://purduechat.dwijen.dev/health` |
| Chat API | `https://purduechat.dwijen.dev/v1/chat/completions` |

## Detection

- **Method**: cgroup v2 filesystem monitoring
- **Path**: `/sys/fs/cgroup/system.slice/slurmstepd.scope/job_*`
- **Latency**: ~1s with 0.25s polling (instant with inotify if available)
- **Zero RPC**: No Slurm controller communication

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

- **Cluster**: Purdue Gilbreth
- **GPUs**: NVIDIA A30 (4x per node)
- **OS**: Rocky Linux 9

## License

MIT
