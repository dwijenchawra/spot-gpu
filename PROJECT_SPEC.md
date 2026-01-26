# Gilbreth LLM Server Watchdog

**Purpose**: Run an LLM server (llama.cpp) on idle Gilbreth GPU compute nodes, automatically yielding to Slurm jobs and exposing via Cloudflare tunnel.

## Key Design: Zero RPC Detection

This system detects Slurm jobs by monitoring the **cgroup filesystem** instead of calling `squeue`. This avoids all network traffic to the Slurm controller.

```bash
# Detection in one line:
ls /sys/fs/cgroup/system.slice/slurmstepd.scope/ | grep "^job_"
```

**Why this works:**
- Cgroups are kernel virtual filesystems
- Reading `/sys/fs/cgroup/*` is a local operation
- Zero network traffic to Slurm controller
- No authentication or RPC required

**Cgroup v2 path** (Gilbreth/Rocky Linux 9):
```
/sys/fs/cgroup/system.slice/slurmstepd.scope/
├── job_10012011/     # Job directory (appears when job starts)
├── job_10053935/
├── job_10213014/
└── system/
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                                                             │
│   purduechat.dwijen.dev ◄──── cloudflared tunnel           │
│                                     │                       │
│                                     ▼                       │
│   ┌─────────────────────────────────────────────────────┐  │
│   │            llm_watchdog.sh (in tmux)                │  │
│   │                                                     │  │
│   │   count_jobs() {                                    │  │
│   │     ls /sys/fs/cgroup/.../slurmstepd.scope/ \      │  │
│   │       | grep -c "^job_"                             │  │
│   │   }                                                 │  │
│   │                                                     │  │
│   │   Main loop:                                        │  │
│   │   1. if jobs exist → wait for them to end          │  │
│   │   2. start llama-server + cloudflared              │  │
│   │   3. poll cgroup every 5s                           │  │
│   │   4. if job_* dir appears → stop everything        │  │
│   │   5. goto 1                                         │  │
│   └─────────────────────────────────────────────────────┘  │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

## Files

```
~/llm-watchdog/
├── llm_watchdog.sh     # Main daemon (~200 lines)
├── config.env          # Configuration
├── start.sh            # tmux launcher
└── PROJECT_SPEC.md     # This document
```

## Configuration

**File**: `config.env`

```bash
# Notifications
NTFY_TOPIC="purduechat-watchdog"
NTFY_SERVER="https://ntfy.sh"

# LLM Server
LLAMA_SERVER_BIN="/scratch/gilbreth/dchawra/llama.cpp/build/bin/llama-server"
MODEL_PATH="/scratch/gilbreth/dchawra/models/Qwen3-Next-80B-A3B/Qwen3-Next-80B-A3B-Instruct-Q4_K_M.gguf"
SERVER_PORT="8080"
LLAMA_EXTRA_ARGS=""

# Cloudflare Tunnel
CLOUDFLARED_BIN="/home/dchawra/cloudflared-linux-amd64"
TUNNEL_ID="0051dc2e-f4fb-4a69-8284-6c18d35514fe"
TUNNEL_HOSTNAME="purduechat.dwijen.dev"
CLOUDFLARED_CREDS="/home/dchawra/.cloudflared/${TUNNEL_ID}.json"

# Detection
POLL_INTERVAL="5"
```

## Quick Start

### 1. Start on compute node

```bash
ssh gilbreth-m002
cd ~/llm-watchdog
./start.sh
```

### 2. Monitor

```bash
tmux attach -t llm_watchdog
```

### 3. Stop

```bash
tmux kill-session -t llm_watchdog
```

## Access

| Service | URL |
|---------|-----|
| Web UI | https://purduechat.dwijen.dev |
| Health | https://purduechat.dwijen.dev/health |
| API | https://purduechat.dwijen.dev/v1/chat/completions |

## Notifications

Subscribe: https://ntfy.sh/purduechat-watchdog

| Event | Priority |
|-------|----------|
| Server Online | Normal |
| Server Yielding | High |
| Watchdog Stopped | Normal |

## Detection Latency

From REPORT.md benchmarks (cgroup v1, similar expected for v2):

| Metric | Value |
|--------|-------|
| Average detection | ~776 ms |
| With 5s polling | ~5.8 seconds worst case |
| With 1s polling | ~1.8 seconds worst case |

The detection happens **after** the job cgroup is created, which is ~776ms after `sbatch` is called.

## Available Models

| Model | Size | Path |
|-------|------|------|
| Qwen3-Next-80B-A3B (Q4_K_M) | 48.5 GB | `/scratch/gilbreth/dchawra/models/Qwen3-Next-80B-A3B/...` |
| GLM-4.7 (Q2_K_XL) | 135 GB | `/scratch/gilbreth/dchawra/models/GLM-4.7/...` |

## Comparison: Old vs New Approach

| Aspect | Old (squeue) | New (cgroup) |
|--------|--------------|--------------|
| Network to Slurm | Yes (RPC) | **None** |
| Works offline | No | **Yes** |
| Detection speed | ~same | ~same |
| Job info | Full | Job ID only |
