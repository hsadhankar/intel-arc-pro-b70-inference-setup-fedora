#!/usr/bin/env bash
# Start llama.cpp Vulkan backend on Intel Arc Pro B70
# Usage: ./start_llamacpp_vulkan.sh <model.gguf> [port] [device]
set -euo pipefail

MODEL="${1:-}"
PORT="${2:-8080}"
# Use vulkan device ID; 0 = first GPU
VK_DEVICE="${3:-0}"

if [[ -z "$MODEL" || ! -f "$MODEL" ]]; then
    echo "Usage: $0 <model.gguf> [port] [vulkan_device_id]"
    echo "Example: $0 ~/models/qwen3-14b-q8_0.gguf 8080 0"
    echo ""
    echo "Available Vulkan devices:"
    vulkaninfo --summary 2>/dev/null | grep -E "deviceName|deviceID" | head -10
    exit 1
fi

echo "Starting llama.cpp Vulkan on device ${VK_DEVICE}, port ${PORT}..."
echo "Model: ${MODEL}"

# Vulkan backend env vars
export GGML_VULKAN_DEVICE="${VK_DEVICE}"

exec ${HOME}/llama.cpp/build_vulkan/bin/llama-server \
    -m "${MODEL}" \
    -ngl 999 \
    --flash-attn \
    -c 8192 \
    --parallel 1 \
    --batch-size 2048 \
    --ubatch-size 512 \
    --defrag-thold 0.1 \
    -t 1 \
    --host 0.0.0.0 \
    --port "${PORT}"
