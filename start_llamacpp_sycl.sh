#!/usr/bin/env bash
# Start llama.cpp SYCL backend on Intel Arc Pro B70
# Usage:
#   ./start_llamacpp_sycl.sh <model.gguf> [port] [device]
#   ./start_llamacpp_sycl.sh --download <repo/model> [quant] [port] [device]
set -euo pipefail

MODELS_DIR="${HOME}/models"
LLAMA_BIN="${HOME}/llama.cpp/build_sycl/bin"

# --- Download mode ---
if [[ "${1:-}" == "--download" ]]; then
    REPO="${2:-}"
    QUANT="${3:-UD-Q4_K_XL}"
    PORT="${4:-8000}"
    DEVICE="${5:-SYCL0}"

    if [[ -z "$REPO" ]]; then
        echo "Usage: $0 --download <repo/model> [quant] [port] [device]"
        echo "Example: $0 --download unsloth/Qwen3.6-27B-GGUF UD-Q4_K_XL 8000 SYCL0"
        echo ""
        echo "This will download the GGUF model and start the server."
        exit 1
    fi

    # Extract model name from repo (e.g., unsloth/Qwen3.6-27B-GGUF -> Qwen3.6-27B)
    MODEL_NAME=$(echo "$REPO" | sed 's/.*\///' | sed 's/-GGUF//')
    # Guess GGUF filename from quant (e.g., UD-Q4_K_XL -> Qwen3.6-27B-UD-Q4_K_XL.gguf)
    GGUF_FILE="${MODEL_NAME}-${QUANT}.gguf"
    MODEL_PATH="${MODELS_DIR}/${GGUF_FILE}"

    if [[ ! -f "$MODEL_PATH" ]]; then
        echo "Downloading ${REPO}:${GGUF_FILE}..."
        mkdir -p "$MODELS_DIR"
        if command -v hf &>/dev/null; then
            hf download "$REPO" "$GGUF_FILE" --local-dir "$MODELS_DIR"
        elif command -v huggingface-cli &>/dev/null; then
            pip install huggingface-hub -q && \
                huggingface-cli download "$REPO" "$GGUF_FILE" \
                --local-dir "$MODELS_DIR" --local-dir-use-symlinks False
        else
            pip install huggingface-hub -q && \
                python3 -c "
import sys
try:
    from huggingface_hub import hf_hub_download
    path = hf_hub_download(repo_id='$REPO', filename='$GGUF_FILE', local_dir='$MODELS_DIR')
    print(f'Downloaded: {path}')
except Exception as e:
    print(f'Error: {e}')
    sys.exit(1)
"
        fi
    else
        echo "Model already exists at ${MODEL_PATH}"
    fi

    # Fall through to start server
    MODEL="$MODEL_PATH"
    PORT="$PORT"
    DEVICE="$DEVICE"
else
    MODEL="${1:-}"
    PORT="${2:-8000}"
    DEVICE="${3:-SYCL0}"

    if [[ -z "$MODEL" || ! -f "$MODEL" ]]; then
        echo "Usage: $0 <model.gguf> [port] [device]"
        echo "       $0 --download <repo/model> [quant] [port] [device]"
        echo ""
        echo "Examples:"
        echo "  $0 ~/models/my-model.gguf 8000 SYCL0"
        echo "  $0 --download unsloth/Qwen3.6-27B-GGUF UD-Q4_K_XL 8000 SYCL0"
        echo ""
        echo "Available SYCL devices:"
        ${LLAMA_BIN}/llama-ls-sycl-devices 2>/dev/null || \
            ${LLAMA_BIN}/llama-cli --list-devices 2>/dev/null || \
            echo "  SYCL0 (run 'ls /dev/dri/render*' to count GPUs)"
        exit 1
    fi
fi

echo "Starting llama.cpp SYCL on device ${DEVICE}, port ${PORT}..."
echo "Model: ${MODEL}"

# Source oneAPI environment
source /opt/intel/oneapi/setvars.sh 2>/dev/null || true

# Critical environment variables for B70:
export GGML_SYCL_DISABLE_OPT=1        # Required for MoE models (avoids SEGV)
export UR_L0_ENABLE_RELAXED_ALLOCATION_LIMITS=1  # Allow >4GB VRAM allocations
export GGML_SYCL_ENABLE_FLASH_ATTN=1  # FlashAttention on XMX engines (~20% gain)
export SYCL_CACHE_PERSISTENT=0        # Disable stale JIT cache

exec ${LLAMA_BIN}/llama-server \
    -m "${MODEL}" \
    --device "${DEVICE}" \
    -ngl 999 \
    -c 8192 \
    --parallel 1 \
    --batch-size 2048 \
    --ubatch-size 512 \
    --defrag-thold 0.1 \
    -t 1 \
    --host 0.0.0.0 \
    --port "${PORT}" \
    "$@"
