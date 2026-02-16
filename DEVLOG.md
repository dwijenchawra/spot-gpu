# LLM Watchdog Devlog

## 2026-02-16: Consolidate cu13/ into unified daemon

### Problem
cu13/ was a near-complete copy of the watchdog scripts (llm_watchdog.sh, start.sh, switch-model.sh, test script, config.env) that differed only in a ~10-line CUDA 13 env setup block and a different venv path. Every bug fix had to be applied twice.

### Solution
Model profiles now declare their environment. Two new optional fields:
- `VENV_PROFILE="cu13/.venv"` -- override the default venv
- `REQUIRES_CUDA13="true"` -- trigger CUDA 13 LD_LIBRARY_PATH/CUDA_HOME setup

The daemon has an "Environment Resolution" block after sourcing config.env + model profile that conditionally applies the CUDA setup and resolves the correct venv. One script handles all models.

### What changed
- `llm_watchdog.sh` -- sources active-model.env, env resolution block, removed hardcoded HF_HOME, removed deactivate from stop_server()
- `config.env` -- infra-only + CUDA paths + HF_HOME (model-specific vars moved to profiles)
- `models/` -- all profiles in one place: glm-4.7-flash, minimax-m2.5, qwen3-coder-fp8
- `switch-model.sh` -- shows [cuda13] tag for CUDA 13 models
- `llm_watchdog_test.sh` -- updated from llama.cpp to vLLM, same env resolution
- `bench.sh` -- moved from cu13/ to top level, uses conditional env resolution
- Deleted: llama-swap-config.yaml, PROJECT_SPEC.md (stale)
- cu13/ now contains only .venv/ (the CUDA 13 virtual environment)

### Rollback
If the unified daemon breaks, the cu13/.venv is untouched -- worst case, recreate cu13/ scripts from git history.

---

## 2026-02-16: Model profiles + MiniMax-M2.5 + perf tuning

### Model profile system
Replaced monolithic config.env with a split setup so swapping models is one command:
- `config.env` -- infra only (ntfy, tunnel, polling, venv path)
- `models/*.env` -- per-model settings (MODEL_NAME, VLLM_ARGS, env vars)
- `active-model.env` -- symlink to current model
- `switch-model.sh` -- list/switch helper

    ./switch-model.sh              # list models
    ./switch-model.sh minimax-m2.5 # switch

### MiniMax-M2.5 added
- Requires CUDA 13 env
- Model downloaded to /scratch/gilbreth/dchawra/models/MiniMax-M2.5 via hf download --local-dir
- Important: MODEL_NAME must point to the local path, not the HF repo ID, otherwise vLLM re-downloads
- --trust-remote-code required (custom model code)
- Max context: 127728 tokens (set to 125000 for headroom)
- DeepGEMM installed for FP8 MoE acceleration

### Performance tuning (gilbreth topology)
Gilbreth GPU topology: no NVLink, pure PCIe + QPI/UPI across 2 NUMA nodes.

    GPU0-GPU1: NODE (NUMA 0)
    GPU2-GPU3: NODE (NUMA 1)
    cross-pair: SYS

Optimizations applied (informed by https://dnhkng.github.io/posts/vllm-optimization-gh200/):

| Setting | Value | Why |
|---------|-------|-----|
| VLLM_ALLREDUCE_USE_SYMM_MEM | 0 | No NVLink -- symmetric memory allreduce hurts |
| VLLM_SLEEP_WHEN_IDLE | 0 | Prevents latency spikes after idle |
| PYTORCH_ALLOC_CONF | expandable_segments:True,max_split_size_mb:512 | Reduces CUDA memory fragmentation for MoE |
| VLLM_FP8_MOE_BACKEND | DEEPGEMM | Force DeepGEMM over default FLASHINFER_CUTLASS |
| SAFETENSORS_FAST_GPU | 1 | Faster model loading |
| --max-num-seqs | 16 | Prevents TTFT spikes (default 256 too aggressive for PCIe) |
| --gpu-memory-utilization | 0.95 | Maximize KV cache |
| --load-format | fastsafetensors | Fast weight loading |
| --compilation-config | cudagraph_mode: PIECEWISE | CUDA graph optimization |
