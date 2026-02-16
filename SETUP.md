# Setting Up llm-watchdog on a New Node

This covers setting up both venvs and the watchdog from scratch on a Gilbreth compute node.

## Prerequisites

- SSH access to a Gilbreth compute node (need GPUs for vLLM/DeepGEMM compilation)
- Python 3 available (`python3 --version`)

## 1. Clone the repo

```bash
ssh gilbreth-m00X
cd ~
git clone git@github.com:dwijenchawra/spot-gpu.git llm-watchdog
cd ~/llm-watchdog
```

## 2. Create the standard venv

This venv is for models that don't need CUDA 13 (e.g. GLM-4.7-Flash).

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install vllm
deactivate
```

## 3. Create the CUDA 13 venv

This venv is for FP8 models (MiniMax-M2.5, Qwen3-Coder-FP8) that need CUDA >= 12.8 for flashinfer block scaling.

```bash
mkdir -p cu13
python3 -m venv cu13/.venv
source cu13/.venv/bin/activate

# Set CUDA environment before installing
export CUDA_HOME=/apps/external/cuda-toolkit/13.1.0
export LD_LIBRARY_PATH=/apps/spack/gilbreth-r9/apps/cuda/12.6.0-gcc-11.5.0-a7cv7sp/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}

pip install --upgrade pip
pip install vllm
```

### 3a. Install DeepGEMM (optional, for FP8 MoE models)

Still inside the cu13 venv with CUDA env set:

```bash
# Must be on a compute node (compiles CUDA kernels)
curl -sL https://raw.githubusercontent.com/vllm-project/vllm/refs/heads/main/tools/install_deepgemm.sh | bash
```

Verify:

```bash
python -c "import deep_gemm; print('ok')"
```

```bash
deactivate
```

## 4. Set up cloudflared

Download the cloudflared binary (one-time, shared across nodes):

```bash
# If not already at ~/cloudflared-linux-amd64
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o ~/cloudflared-linux-amd64
chmod +x ~/cloudflared-linux-amd64
```

The tunnel credentials (`~/.cloudflared/`) must also exist -- copy from an existing node if needed.

## 5. Set up HF cache

The HuggingFace cache is on shared scratch and should already be available:

```
/scratch/gilbreth/dchawra/cache/huggingface
```

If models haven't been downloaded yet:

```bash
source .venv/bin/activate
export HF_HOME=/scratch/gilbreth/dchawra/cache/huggingface
huggingface-cli download zai-org/GLM-4.7-Flash
deactivate
```

## 6. Activate a model and start

```bash
cd ~/llm-watchdog

# Set the default model
./switch-model.sh glm-4.7-flash

# Verify
./switch-model.sh
#   * glm-4.7-flash  (active)
#     minimax-m2.5 [cuda13]
#     qwen3-coder-fp8 [cuda13]

# Launch in tmux
./start.sh
```

## 7. Verify

```bash
# Check the tmux session
tmux attach -t llm_watchdog

# Or check health directly
curl http://localhost:8000/health
```

## Paths to update if your username differs

All in `config.env`:

| Variable | Current value |
|----------|---------------|
| `LLM_VENV` | `/home/dchawra/llm-watchdog/.venv` |
| `HF_HOME` | `/scratch/gilbreth/dchawra/cache/huggingface` |
| `CLOUDFLARED_BIN` | `/home/dchawra/cloudflared-linux-amd64` |
| `CLOUDFLARED_CREDS` | `/home/dchawra/.cloudflared/<tunnel-id>.json` |
