# spot-gpu

A daemon for running vLLM LLM servers on idle GPUs at Purdue University's Gilbreth compute cluster, with automatic job yielding and public access via Cloudflare tunnel.

## Features

- **Idle GPU Utilization**: Automatically starts vLLM servers when GPUs are idle
- **Zero Slack RPC**: Uses cgroup filesystem to detect Slurm jobs instead of API calls
- **Automatic Yield**: Stops services immediately when Slurm jobs appear
- **Public Access**: Exposed via Cloudflare tunnel at `https://purduechat.dwijen.dev`
- **Multi-Model Support**: Configurable models with speculative decoding
- **Notifications**: ntfy.sh alerts for state changes

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Gilbreth Cluster                          │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐          │
│  │   Node 1    │    │   Node 2    │    │   Node 3    │          │
│  │ 4× H100 GPU │    │ 4× H100 GPU │    │ 4× H100 GPU │          │
│  └──────┬──────┘    └──────┬──────┘    └──────┬──────┘          │
│         └────────┬─────────┴─────────┬─────────┘                │
│                  │  cgroup watch     │                         │
│                  ▼                    ▼                         │
│         ┌─────────────────────────────────────┐                │
│         │      llm-watchdog daemon            │                │
│         │  (mounts /sys/fs/cgroup/v2)         │                │
│         └──────┬──────────────┬───────────────┘                │
│                ▼              ▼                                 │
│      ┌──────────────┐  ┌──────────────┐                        │
│      │  vllm serve  │  │  vllm serve  │                        │
│      │  on port 8000│  │  on port 8000│                        │
│      └──────┬───────┘  └──────┬───────┘                        │
│             │                 ▼                                 │
│             └─────────┬───────────────┐                         │
│                       ▼               ▼                         │
│              ┌──────────────────────────┐                       │
│              │   Cloudflare Tunnel      │                       │
│              │  purduechat.dwijen.dev   │                       │
│              └──────────────────────────┘                       │
└─────────────────────────────────────────────────────────────────┘
```

## Quick Start

1. **Edit `config.env`** with your settings:
   ```bash
   # Example: Change tunnel hostname
   TUNNEL_HOSTNAME="your-name.dwijen.dev"
   ```

2. **Deploy the daemon**:
   ```bash
   scp *.sh config.env sbatch -N node1 -c 4 --gpus-per-node=4 llm_watchdog.sh
   ```
   Or use the provided `start.sh` to launch via tmux on remote nodes.

3. **Check status**:
   ```bash
   ssh gilbreth-m001
   tail -f ~/.tmux/logs/llm_watchdog.log
   ```

## Configuration

### `config.env`

```bash
# Notifications
NTFY_TOPIC="purduechat-watchdog"
NTFY_SERVER="https://ntfy.sh"

# vLLM Server
LLM_VENV="/home/dchawra/llm-watchdog/.venv"
LLM_BIN="${LLM_VENV}/bin/vllm"
MODEL_NAME="zai-org/GLM-4.7-Flash"
SERVER_PORT="8000"

# vLLM serve args
VLLM_ARGS="--tensor-parallel-size 4 \
    --speculative-config.method mtp \
    --speculative-config.num_speculative_tokens 1 \
    --tool-call-parser glm47 \
    --reasoning-parser glm45 \
    --enable-auto-tool-choice \
    --served-model-name glm-4.7-flash"

# Cloudflare Tunnel
CLOUDFLARED_BIN="/home/dchawra/cloudflared-linux-amd64"
TUNNEL_ID="0051dc2e-f4fb-4a69-8284-6c18d35514fe"
TUNNEL_HOSTNAME="purduechat.dwijen.dev"

# Detection
POLL_INTERVAL="0.25"  # 0.25s polling, ~1s worst case detection
```

### `llama-swap-config.yaml`

Configure models for swap functionality:

```yaml
models:
  glm-4.7:
    cmd: source /home/dchawra/llm-watchdog/.venv/bin/activate && HF_HOME=/scratch/dchawra/cache/huggingface /home/dchawra/llm-watchdog/.venv/bin/vllm serve zai-org/GLM-4.7-Flash ...
    aliases:
      - glm-4.7
      - glm
      - default
    ttl: 0
```

## Endpoints

| Endpoint | Description |
|----------|-------------|
| `https://purduechat.dwijen.dev` | Web UI |
| `https://purduechat.dwijen.dev/health` | Health check |
| `https://purduechat.dwijen.dev/v1/chat/completions` | Chat completions API |

## Detection

- **Method**: cgroup v2 filesystem monitoring
- **Path**: `/sys/fs/cgroup/system.slice/slurmstepd.scope/job_*`
- **Latency**: ~1s with 0.25s polling (instant with inotify)
- **Zero RPC**: No Slurm controller communication

## Notification Topics

| Topic | Description |
|-------|-------------|
| `purduechat-watchdog` | Daemon status alerts |

## Components

- `llm_watchdog.sh` - Main daemon script
- `llm_watchdog_test.sh` - Test daemon (uses fake job file)
- `config.env` - Configuration file
- `llama-swap-config.yaml` - Model configuration
- `start.sh` - tmux launcher
- `PROJECT_SPEC.md` - Detailed technical documentation

## Hardware

- **Cluster**: Purdue Gilbreth
- **GPUs**: NVIDIA H100 80GB (4x per node)
- **OS**: Rocky Linux 9

## Changelog

### [Unreleased]

#### Migrations
- **llama.cpp → vLLM**: Migrated from llama-server to vLLM as the default LLM server
  - Server now listens on port `8000` (was `8080`)
  - Models loaded from HuggingFace Hub instead of local GGUF files
  - Added speculative decoding (MTP) with `--speculative-config.method mtp`
  - Added tool-call parser `glm47` and reasoning parser `glm45`
  - Added `--enable-auto-tool-choice` flag

#### Configuration Changes
- Renamed `LLAMA_SERVER_BIN` to `LLM_VENV` and `LLM_BIN`
- Renamed `MODEL_PATH` to `MODEL_NAME`
- Removed `LLAMA_EXTRA_ARGS` (moved to `VLLM_ARGS`)
- Added `HF_HOME` environment variable export for HuggingFace cache

#### Daemon Updates
- Added venv activation on startup
- Updated `stop_server()` to use `pkill -f "vllm serve"` and `deactivate`
- Updated notification titles to use "vLLM" prefix
- Health check still uses `/health` endpoint (same as llama.cpp)

### [2.x] - llama.cpp Implementation
- Initial implementation using llama.cpp as LLM server
- cgroup v2 filesystem detection for Slurm jobs
- Cloudflare tunnel integration
- ntfy.sh notifications

## License

MIT