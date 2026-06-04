#!/usr/bin/env bash
# =============================================================================
# Intel Arc Pro B70 Inference Server — Fedora 44 Setup Script
#
# Adapted from: Hal9000AIML/arc-pro-b70-inference-setup-ubuntu-server
# Fedora 44 adaptation by: [Your Name]
#
# Sets up Intel Arc Pro B70 GPU for LLM inference with llama.cpp
# SYCL and Vulkan backends on Fedora 44.
#
# Hardware requirements:
#   - 1x Intel Arc Pro B70 GPU (32GB VRAM)
#   - 32GB+ system RAM (64GB+ recommended for 32K context)
#   - Fedora 44 (kernel 6.19+ includes Battlemage xe driver)
#
# BIOS requirements (set manually before running):
#   - Above 4G Decoding: ENABLED
#   - Resizable BAR: ENABLED
#   - CSM: DISABLED (UEFI boot only)
#   - IOMMU: ENABLED
#
# Usage:
#   chmod +x fedora-b70-setup.sh
#   ./fedora-b70-setup.sh   (script will prompt for sudo when needed)
#
# After running, reboot and then:
#   ~/start_llamacpp_sycl.sh <model.gguf>
#   ~/start_llamacpp_vulkan.sh <model.gguf>
# =============================================================================
set -euo pipefail

SCRIPT_VERSION="1.0.0-fedora"
LOG="/tmp/fedora-b70-setup.log"
touch "$LOG" && chmod 600 "$LOG"
exec > >(tee -a "$LOG") 2>&1

echo "================================================================"
echo "Intel Arc Pro B70 Inference Server Setup v${SCRIPT_VERSION}"
echo "Fedora 44 Adaptation"
echo "Date: $(date)"
echo "================================================================"

# -----------------------------------------------------------
# 0. Sanity checks
# -----------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo "INFO: Re-running with sudo..."
    exec sudo "$0" "$@"
fi

REAL_USER="${SUDO_USER:-}"
if [[ -z "$REAL_USER" || "$REAL_USER" == "root" ]]; then
    echo "ERROR: Run as a normal user with sudo: ./fedora-b70-setup.sh"
    exit 1
fi

REAL_HOME=$(getent passwd "${REAL_USER}" | cut -d: -f6)
echo "User: ${REAL_USER} | Home: ${REAL_HOME}"

# Check for B70 GPUs
echo ""
echo "--- Checking for Intel Arc Pro B70 GPUs ---"
lspci -nn | grep -iE "e223|Battlemage|Graphics.*Intel" || true
B70_COUNT=$(lspci -nn | grep -c "e223" 2>/dev/null || echo 0)
if [[ "$B70_COUNT" -eq 0 ]]; then
    echo "WARNING: No Intel Arc Pro B70 GPU detected (device e223)."
    echo "Check BIOS: Above 4G Decoding + ReBAR must be ENABLED."
    echo ""
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]] || exit 1
else
    echo "Detected ${B70_COUNT}x Intel Arc Pro B70 GPU(s)"
fi

NEED_REBOOT=false

# -----------------------------------------------------------
# 1. System update & essential packages
# -----------------------------------------------------------
echo ""
echo ">>> [1/9] System update & essential packages"
echo ""

dnf upgrade -y --refresh 2>/dev/null || dnf upgrade -y
dnf group install -y development-tools 2>/dev/null || dnf install -y gcc gcc-c++ make cmake
dnf install -y \
    cmake git curl wget \
    htop lm_sensors \
    pkgconfig openssl-devel \
    python3 python3-pip \
    unzip pciutils lshw numactl \
    vulkan-tools vulkan-loader-devel \
    mesa-vulkan-drivers \
    glslang

# Additional build deps for llama.cpp
dnf install -y \
    libstdc++-static \
    libcurl-devel \
    gcc gcc-c++ make

echo "    Done."

# -----------------------------------------------------------
# 2. Kernel check — Fedora 44 ships 6.19+, should be fine
# -----------------------------------------------------------
echo ""
echo ">>> [2/9] Kernel check & GRUB configuration"
echo ""

CURRENT_KERNEL=$(uname -r)
echo "    Current kernel: ${CURRENT_KERNEL}"
CURRENT_MAJOR=$(echo "$CURRENT_KERNEL" | cut -d. -f1)
CURRENT_MINOR=$(echo "$CURRENT_KERNEL" | cut -d. -f2)

if [[ "$CURRENT_MAJOR" -lt 6 ]] || [[ "$CURRENT_MAJOR" -eq 6 && "$CURRENT_MINOR" -lt 17 ]]; then
    echo "    WARNING: Kernel too old for Battlemage xe driver support."
    echo "    Fedora 44 should have 6.19+ — please upgrade."
    exit 1
else
    echo "    Kernel version OK for Battlemage"
fi

# Configure GRUB for GPU
GRUB_CFG="/etc/default/grub"
if grep -q "GRUB_CMDLINE_LINUX=" "$GRUB_CFG"; then
    CURRENT_CMDLINE=$(grep '^GRUB_CMDLINE_LINUX=' "$GRUB_CFG" | sed 's/^GRUB_CMDLINE_LINUX="//;s/"$//')
    if ! echo "$CURRENT_CMDLINE" | grep -q "iommu=pt"; then
        echo "    Adding iommu=pt to GRUB_CMDLINE_LINUX"
        NEW_CMDLINE="${CURRENT_CMDLINE} iommu=pt"
        # Using Python for safe sed replacement
        NEW_CMDLINE="${NEW_CMDLINE}" python3 -c "
import os, re
new_val = os.environ['NEW_CMDLINE']
with open('$GRUB_CFG', 'r') as f:
    content = f.read()
content = re.sub(
    r'^GRUB_CMDLINE_LINUX=.*$',
    f'GRUB_CMDLINE_LINUX=\"{new_val}\"',
    content, flags=re.MULTILINE
)
with open('$GRUB_CFG', 'w') as f:
    f.write(content)
print('GRUB updated')
"
        NEED_REBOOT=true
    fi
fi

# Also add pci=realloc if missing
if grep -q "GRUB_CMDLINE_LINUX=" "$GRUB_CFG"; then
    CURRENT_CMDLINE=$(grep '^GRUB_CMDLINE_LINUX=' "$GRUB_CFG" | sed 's/^GRUB_CMDLINE_LINUX="//;s/"$//')
    if ! echo "$CURRENT_CMDLINE" | grep -q "pci=realloc"; then
        echo "    Adding pci=realloc to GRUB_CMDLINE_LINUX"
        NEW_CMDLINE="${CURRENT_CMDLINE} pci=realloc"
        NEW_CMDLINE="${NEW_CMDLINE}" python3 -c "
import os, re
new_val = os.environ['NEW_CMDLINE']
with open('$GRUB_CFG', 'r') as f:
    content = f.read()
content = re.sub(
    r'^GRUB_CMDLINE_LINUX=.*$',
    f'GRUB_CMDLINE_LINUX=\"{new_val}\"',
    content, flags=re.MULTILINE
)
with open('$GRUB_CFG', 'w') as f:
    f.write(content)
print('GRUB updated with pci=realloc')
"
        NEED_REBOOT=true
    fi
fi

if [[ "$NEED_REBOOT" == "true" ]]; then
    grub2-mkconfig -o /boot/grub2/grub.cfg
    echo "    GRUB configuration updated"
fi

echo "    Done."

# -----------------------------------------------------------
# 3. Install Intel GPU compute stack from Fedora repos
# -----------------------------------------------------------
echo ""
echo ">>> [3/9] Intel GPU compute runtime (from Fedora repos)"
echo ""
echo "    Fedora 44 ships modern compute-runtime v26.18.38308.1 + IGC v2.34.4"
echo "    These support Battlemage (BMG G31 / device e223) out of the box."
echo ""

# Fedora includes everything we need in its repos
dnf install -y \
    intel-compute-runtime \
    intel-level-zero \
    intel-level-zero-devel \
    oneapi-level-zero \
    oneapi-level-zero-devel \
    intel-igc \
    intel-igc-libs \
    intel-gmmlib

# Add user to render and video groups
usermod -aG render "${REAL_USER}"
usermod -aG video "${REAL_USER}"
echo "    Added ${REAL_USER} to render and video groups"

# Verify Level Zero is working
echo ""
echo "    Verifying Level Zero GPU detection..."
if command -v zello_world &>/dev/null; then
    zello_world 2>&1 | head -10 || echo "    (zello_world needs a display)"
elif [[ -f /usr/libexec/oneapi-level-zero/zello_world ]]; then
    /usr/libexec/oneapi-level-zero/zello_world 2>&1 | head -10 || true
fi

echo "    Done."

# -----------------------------------------------------------
# 4. Update GuC + HuC firmware for Battlemage
# -----------------------------------------------------------
echo ""
echo ">>> [4/9] GuC/HuC firmware update"
echo ""
echo "    Current firmware is from linux-firmware-20260309"
echo "    Updating to latest GuC 70.60.0+ from linux-firmware.git..."
echo ""

FW_TMP=$(mktemp -d)
LF_BASE="https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/xe"

if curl -fsSLo "$FW_TMP/bmg_guc_70.bin" "$LF_BASE/bmg_guc_70.bin" && \
   curl -fsSLo "$FW_TMP/bmg_huc.bin" "$LF_BASE/bmg_huc.bin"; then
    echo "    Downloaded latest GuC/HuC firmware"
    
    # Fedora uses .xz compression; check what format the current firmware uses
    if ls /lib/firmware/xe/bmg_guc_70.bin.xz &>/dev/null; then
        echo "    Compressing to .xz format..."
        xz -f -k "$FW_TMP/bmg_guc_70.bin"
        xz -f -k "$FW_TMP/bmg_huc.bin"
        
        cp /lib/firmware/xe/bmg_guc_70.bin.xz /lib/firmware/xe/bmg_guc_70.bin.xz.bak.$(date +%s) 2>/dev/null || true
        cp /lib/firmware/xe/bmg_huc.bin.xz /lib/firmware/xe/bmg_huc.bin.xz.bak.$(date +%s) 2>/dev/null || true
        
        install -m 644 "$FW_TMP/bmg_guc_70.bin.xz" /lib/firmware/xe/bmg_guc_70.bin.xz
        install -m 644 "$FW_TMP/bmg_huc.bin.xz" /lib/firmware/xe/bmg_huc.bin.xz
    else
        # Also check for .zst format
        install -m 644 "$FW_TMP/bmg_guc_70.bin" /lib/firmware/xe/bmg_guc_70.bin
        install -m 644 "$FW_TMP/bmg_huc.bin" /lib/firmware/xe/bmg_huc.bin
    fi
    
    # Remove uncompressed .bin if it exists (can shadow compressed)
    rm -f /lib/firmware/xe/bmg_guc_70.bin /lib/firmware/xe/bmg_huc.bin 2>/dev/null || true
    
    dracut --force --regenerate-all
    echo "    GuC/HuC firmware updated. Will load on next boot."
else
    echo "    NOTE: Could not fetch firmware from linux-firmware.git"
    echo "    Current distro firmware should work for basic operation."
fi
rm -rf "$FW_TMP"
echo "    Done."

# -----------------------------------------------------------
# 5. Install Intel oneAPI Base Toolkit (for SYCL compilation)
# -----------------------------------------------------------
echo ""
echo ">>> [5/9] Intel oneAPI Base Toolkit"
echo ""
echo "    Setting up Intel oneAPI RPM repository..."
echo ""

# Set up Intel oneAPI repo
cat > /etc/yum.repos.d/oneAPI.repo << 'REPOEOF'
[oneAPI]
name=Intel® oneAPI repository
baseurl=https://yum.repos.intel.com/oneapi
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://yum.repos.intel.com/intel-gpg-keys/GPG-PUB-KEY-INTEL-SW-PRODUCTS.PUB
REPOEOF

rpm --import https://yum.repos.intel.com/intel-gpg-keys/GPG-PUB-KEY-INTEL-SW-PRODUCTS.PUB 2>/dev/null || true
dnf makecache -y

# Install oneAPI DPC++ compiler (MKL is installed separately below)
echo "    Installing oneAPI DPC++ compiler..."
echo "    (This may take 5-10 minutes depending on network speed)"
echo ""

dnf install -y \
    intel-oneapi-compiler-dpcpp-cpp \
    intel-oneapi-compiler-fortran 2>/dev/null || true

# Check if compiler installed
if [[ ! -f /opt/intel/oneapi/compiler/2026.0/bin/icpx ]]; then
    echo ""
    echo "    WARNING: oneAPI compiler not found via RPM."
    echo "    Downloading full oneAPI toolkit offline installer..."
    echo "    wget https://registrationcenter-download.intel.com/akdlm/IRC_NAS/71180075-e4e3-4c6f-bbbb-19017ed0cf7d/intel-oneapi-toolkit-2026.0.0.198_offline.sh"
    echo "    sudo sh ./intel-oneapi-toolkit-2026.0.0.198_offline.sh -a --silent --eula accept"
    echo ""
    ONEAPI_MISSING=true
else
    ONEAPI_MISSING=false
fi

# Install oneMKL (not available in RPM repo, download standalone)
MKL_INSTALLER="/tmp/intel-onemkl-2026.0.0.909_offline.sh"
if [[ "$ONEAPI_MISSING" == "false" && ! -d /opt/intel/oneapi/mkl ]]; then
    echo ""
    echo "    Downloading Intel oneMKL standalone installer..."
    echo "    (Size: ~1.5GB, may take a few minutes)..."
    wget -q --show-progress \
        "https://registrationcenter-download.intel.com/akdlm/IRC_NAS/db60f483-f02e-4f7e-9bcd-5e01dba97444/intel-onemkl-2026.0.0.909_offline.sh" \
        -O "$MKL_INSTALLER" || {
        echo "    Could not download MKL installer."
        echo "    Build Sycl may fail without MKL."
        MKL_MISSING=true
    }
    if [[ -f "$MKL_INSTALLER" ]]; then
        echo "    Installing Intel oneMKL (silent mode)..."
        chmod +x "$MKL_INSTALLER"
        sh "$MKL_INSTALLER" -a --silent --eula accept 2>&1 | tail -5 || {
            echo "    MKL installation had issues, continuing..."
            MKL_MISSING=true
        }
        rm -f "$MKL_INSTALLER"
    fi
fi

# Check if oneAPI is installed
ONEAPI_DIR="/opt/intel/oneapi"
if [[ -d "$ONEAPI_DIR" ]]; then
    echo "    oneAPI found at ${ONEAPI_DIR}"
    ONEAPI_MISSING=false
else
    echo "    oneAPI not found at ${ONEAPI_DIR}"
    ONEAPI_MISSING=true
fi

# Set up oneAPI environment for the user
if [[ "$ONEAPI_MISSING" == "false" ]]; then
    cat > /etc/profile.d/oneapi.sh << 'EOF'
#!/bin/bash
source /opt/intel/oneapi/setvars.sh 2>/dev/null
EOF
    chmod +x /etc/profile.d/oneapi.sh
    
    # Also add to user's bashrc
    grep -q "oneapi/setvars.sh" "${REAL_HOME}/.bashrc" 2>/dev/null || \
    echo 'source /opt/intel/oneapi/setvars.sh 2>/dev/null || true' >> "${REAL_HOME}/.bashrc"
    
    echo "    oneAPI environment configured in /etc/profile.d/oneapi.sh"
fi

if [[ "$ONEAPI_MISSING" == "true" ]]; then
    echo ""
    echo "    NOTE: oneAPI not installed. llama.cpp SYCL backend build will be skipped."
    echo "    The Vulkan backend will still be built."
fi

echo "    Done."

# -----------------------------------------------------------
# 6. Build llama.cpp (SYCL backend)
# -----------------------------------------------------------
echo ""
echo ">>> [6/9] Building llama.cpp (SYCL backend)"
echo ""

LLAMA_DIR="${REAL_HOME}/llama.cpp"
if [[ -d "${LLAMA_DIR}" ]]; then
    echo "    Updating existing llama.cpp repository..."
    sudo -u "${REAL_USER}" git -C "${LLAMA_DIR}" pull --rebase -q
else
    echo "    Cloning llama.cpp repository..."
    sudo -u "${REAL_USER}" git clone -q --depth 1 https://github.com/ggerganov/llama.cpp.git "${LLAMA_DIR}"
fi

if [[ "$ONEAPI_MISSING" == "false" ]]; then
    echo "    Building with SYCL backend..."
    rm -rf "${LLAMA_DIR}/build_sycl"
    mkdir -p "${LLAMA_DIR}/build_sycl"
    chown "${REAL_USER}:${REAL_USER}" "${LLAMA_DIR}/build_sycl"
    
    # Source oneAPI and run cmake in same shell context
    sudo -u "${REAL_USER}" bash -c 'source /opt/intel/oneapi/setvars.sh 2>/dev/null && cmake -S "'"${LLAMA_DIR}"'" -B "'"${LLAMA_DIR}"'/build_sycl" \
        -DGGML_SYCL=ON \
        -DGGML_SYCL_F16=ON \
        -DGGML_VULKAN=OFF \
        -DGGML_CUDA=OFF \
        -DGGML_NATIVE=ON \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER=icx \
        -DCMAKE_CXX_COMPILER=icpx \
        -DMKL_DIR=/opt/intel/oneapi/mkl/latest' 2>&1 | tail -20 || true
    
    echo "    Compiling (this may take 15-30 minutes)..."
    sudo -u "${REAL_USER}" bash -c 'source /opt/intel/oneapi/setvars.sh 2>/dev/null && cmake --build "'"${LLAMA_DIR}"'/build_sycl" --config Release -j$(nproc)' 2>&1 | tail -5 || true
    
    if [[ -f "${LLAMA_DIR}/build_sycl/bin/llama-server" ]]; then
        echo "    SYCL build SUCCESS: ${LLAMA_DIR}/build_sycl/bin/llama-server"
    else
        echo "    SYCL build FAILED — check output above"
    fi
else
    echo "    Skipping SYCL backend build (oneAPI not installed)"
fi

    echo "    Done."

# -----------------------------------------------------------
# 7. Build llama.cpp (Vulkan backend)
# -----------------------------------------------------------
echo ""
echo ">>> [7/9] Building llama.cpp (Vulkan backend)"
echo ""

echo "    Building with Vulkan backend..."
rm -rf "${LLAMA_DIR}/build_vulkan"
mkdir -p "${LLAMA_DIR}/build_vulkan"
chown "${REAL_USER}:${REAL_USER}" "${LLAMA_DIR}/build_vulkan"

sudo -u "${REAL_USER}" cmake -S "${LLAMA_DIR}" -B "${LLAMA_DIR}/build_vulkan" \
    -DGGML_VULKAN=ON \
    -DGGML_SYCL=OFF \
    -DGGML_CUDA=OFF \
    -DGGML_NATIVE=ON \
    -DCMAKE_BUILD_TYPE=Release 2>&1 | tail -10 || true

echo "    Compiling..."
sudo -u "${REAL_USER}" cmake --build "${LLAMA_DIR}/build_vulkan" --config Release -j$(nproc) 2>&1 | tail -5 || true

if [[ -f "${LLAMA_DIR}/build_vulkan/bin/llama-server" ]]; then
    echo "    Vulkan build SUCCESS: ${LLAMA_DIR}/build_vulkan/bin/llama-server"
else
    echo "    Vulkan build FAILED — check output above"
fi

echo "    Done."

# -----------------------------------------------------------
# 8. Create scripts and configuration
# -----------------------------------------------------------
echo ""
echo ">>> [8/9] Creating scripts and configuration"
echo ""

# --- SYCL start script ---
cat > "${REAL_HOME}/start_llamacpp_sycl.sh" << 'SYCLSCRIPT'
#!/usr/bin/env bash
# Start llama.cpp SYCL backend on Intel Arc Pro B70
# Usage: ./start_llamacpp_sycl.sh <model.gguf> [port]
set -euo pipefail

MODEL="${1:-}"
PORT="${2:-8000}"
DEVICE="${3:-SYCL0}"

if [[ -z "$MODEL" || ! -f "$MODEL" ]]; then
    echo "Usage: $0 <model.gguf> [port] [device]"
    echo "Example: $0 ~/models/gemma-4-26b-q8_0.gguf 8000 SYCL0"
    echo ""
    echo "Available SYCL devices:"
    ${HOME}/llama.cpp/build_sycl/bin/llama-ls-sycl-devices 2>/dev/null || \
        ${HOME}/llama.cpp/build_sycl/bin/llama-cli --list-devices 2>/dev/null || \
        echo "  SYCL0, SYCL1, ... (run 'ls /dev/dri/render*' to count GPUs)"
    exit 1
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

# For dense models (non-MoE), you can remove GGML_SYCL_DISABLE_OPT=1
# for ~5% better performance.

exec ${HOME}/llama.cpp/build_sycl/bin/llama-server \
    -m "${MODEL}" \
    --device "${DEVICE}" \
    -ngl 999 \
    -c 32768 \
    --parallel 2 \
    --batch-size 2048 \
    --ubatch-size 512 \
    --defrag-thold 0.1 \
    -t 1 \
    --host 0.0.0.0 \
    --port "${PORT}" \
    "$@"
SYCLSCRIPT

# --- Vulkan start script ---
cat > "${REAL_HOME}/start_llamacpp_vulkan.sh" << 'VULKANSCRIPT'
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
    -c 32768 \
    --parallel 2 \
    --batch-size 2048 \
    --ubatch-size 512 \
    --defrag-thold 0.1 \
    -t 1 \
    --host 0.0.0.0 \
    --port "${PORT}" \
    "$@"
VULKANSCRIPT

# --- System info script ---
cat > "${REAL_HOME}/sysinfo-b70.sh" << 'SYSSCRIPT'
#!/usr/bin/env bash
echo "=== Intel Arc Pro B70 Inference Server ==="
echo "Host:   $(hostname)"
echo "Date:   $(date)"
echo "Kernel: $(uname -r)"
echo "Uptime: $(uptime -p)"
echo "RAM:    $(free -h | awk '/Mem:/{print $3"/"$2}')"
echo "Swap:   $(free -h | awk '/Swap:/{print $3"/"$2}')"
echo "CPU:    $(lscpu | grep 'Model name' | head -1 | cut -d: -f2 | xargs)"
echo ""
echo "=== GPU ==="
lspci -nn | grep -iE "VGA|3D|Display|Battlemage"
echo ""
echo "=== GPU Memory ==="
cat /sys/class/drm/card*/device/mem_info_vram_total 2>/dev/null | \
    awk '{printf "  VRAM Total: %.2f GiB\n", $1/1024/1024/1024}' || true
cat /sys/class/drm/card*/device/mem_info_vram_free 2>/dev/null | \
    awk '{printf "  VRAM Free:  %.2f GiB\n", $1/1024/1024/1024}' || true
echo ""
echo "=== Vulkan Devices ==="
vulkaninfo --summary 2>/dev/null | grep -E "deviceName|deviceID|deviceType" | head -10 || echo "(not available)"
echo ""
echo "=== Level Zero Devices ==="
ls /dev/dri/render* 2>/dev/null | xargs -I{} sh -c 'echo "  {}: $(cat /sys/class/drm/$(basename {})/device/device 2>/dev/null)"' 2>/dev/null || echo "  (check /dev/dri)"
echo ""
echo "=== GPU Temperature ==="
sensors 2>/dev/null | grep -E "xe|PCH|GPU|edge" | head -10 || echo "(install lm_sensors)"
echo ""
echo "=== llama.cpp ==="
LS_SYCL="${HOME}/llama.cpp/build_sycl/bin/llama-server"
LS_VK="${HOME}/llama.cpp/build_vulkan/bin/llama-server"
[[ -x "$LS_SYCL" ]] && echo "  SYCL:   $($LS_SYCL --version 2>/dev/null | head -1)" || echo "  SYCL:   not built"
[[ -x "$LS_VK" ]] && echo "  Vulkan: $($LS_VK --version 2>/dev/null | head -1)" || echo "  Vulkan: not built"
SYSSCRIPT

# --- xe driver tuning script ---
cat > "${REAL_HOME}/xe_tuning.sh" << 'XESCRIPT'
#!/usr/bin/env bash
# xe_tuning.sh — Intel xe driver tuning for Battlemage inference workloads
#
# Raises job timeouts, disables DVFS, and optimizes PCIe ASPM for
# long-running LLM inference workloads on Intel Arc Pro B70 GPUs.
set -u
LOG_TAG="xe-tuning"

JOB_TIMEOUT_MS=30000

log() { logger -t "$LOG_TAG" -- "$*"; echo "[xe-tuning] $*"; }
log "starting xe driver tuning"

# 1. Per-engine job_timeout_ms
count=0
while IFS= read -r f; do
    [ -z "$f" ] && continue
    case "$f" in *".defaults"*) continue ;; esac
    max_file="$(dirname "$f")/job_timeout_max"
    target=$JOB_TIMEOUT_MS
    if [ -r "$max_file" ]; then
        engine_max=$(cat "$max_file" 2>/dev/null || echo 0)
        if [ "${engine_max:-0}" -gt 0 ] && [ "$target" -gt "$engine_max" ]; then
            target=$engine_max
        fi
    fi
    echo "$target" > "$f" 2>/dev/null && count=$((count + 1)) || log "WARN: failed to write $target to $f"
done < <(find /sys/devices -name job_timeout_ms 2>/dev/null)
log "job_timeout_ms: updated $count engines to ${JOB_TIMEOUT_MS}ms (clamped to engine max where needed)"

# 2. Per-engine preempt_timeout_us (disable preemption timeout)
count=0
while IFS= read -r f; do
    [ -z "$f" ] && continue
    case "$f" in *".defaults"*) continue ;; esac
    max_file="$(dirname "$f")/preempt_timeout_max"
    target=$(cat "$max_file" 2>/dev/null || echo 0)
    [ "${target:-0}" -le 0 ] && continue
    echo "$target" > "$f" 2>/dev/null && count=$((count + 1)) || log "WARN: failed to write $target to $f"
done < <(find /sys/devices -name preempt_timeout_us 2>/dev/null)
log "preempt_timeout_us: raised $count engines to their max"

# 3. Pin GT frequency (DVFS off)
count=0
while IFS= read -r freq_dir; do
    [ -d "$freq_dir" ] || continue
    rp0=$(cat "$freq_dir/rp0_freq" 2>/dev/null || echo "")
    [ -z "$rp0" ] && continue
    echo "$rp0" > "$freq_dir/max_freq" 2>/dev/null || true
    echo "$rp0" > "$freq_dir/min_freq" 2>/dev/null || true
    count=$((count + 1))
done < <(find /sys/devices -type d -path "*tile0/gt*/freq0" 2>/dev/null)
log "gt frequency: pinned min=max=rp0 on $count GTs"

# 4. PCIe ASPM
if [ -w /sys/module/pcie_aspm/parameters/policy ]; then
    echo performance > /sys/module/pcie_aspm/parameters/policy 2>/dev/null || true
    log "pcie_aspm policy: $(cat /sys/module/pcie_aspm/parameters/policy 2>/dev/null)"
fi

log "xe tuning complete"
XESCRIPT

# --- Systemd service for xe tuning ---
cat > /etc/systemd/system/xe-tuning.service << 'XESERVICE'
[Unit]
Description=Intel xe driver tuning for Battlemage inference
After=multi-user.target
Before=vllm-docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/home/harshal/xe_tuning.sh

[Install]
WantedBy=multi-user.target
XESERVICE

chmod +x "${REAL_HOME}/start_llamacpp_sycl.sh"
chmod +x "${REAL_HOME}/start_llamacpp_vulkan.sh"
chmod +x "${REAL_HOME}/sysinfo-b70.sh"
chmod +x "${REAL_HOME}/xe_tuning.sh"
chown "${REAL_USER}:${REAL_USER}" \
    "${REAL_HOME}/start_llamacpp_sycl.sh" \
    "${REAL_HOME}/start_llamacpp_vulkan.sh" \
    "${REAL_HOME}/sysinfo-b70.sh" \
    "${REAL_HOME}/xe_tuning.sh"

systemctl daemon-reload
systemctl enable xe-tuning.service

echo "    Scripts created:"
echo "      ~/start_llamacpp_sycl.sh      — SYCL backend server"
echo "      ~/start_llamacpp_vulkan.sh    — Vulkan backend server"
echo "      ~/sysinfo-b70.sh              — System status"
echo "      ~/xe_tuning.sh                — GPU driver tuning"
echo "      xe-tuning.service             — Auto-tune at boot"
echo "    Done."

# -----------------------------------------------------------
# 9. Summary
# -----------------------------------------------------------
echo ""
echo "================================================================"
echo "Intel Arc Pro B70 Setup Complete!"
echo "Fedora 44 — $(date)"
echo "================================================================"
echo ""
echo "Setup summary:"
echo "  Kernel:           $(uname -r)${NEED_REBOOT:+ (REBOOT REQUIRED)}"
echo "  GPU:              ${B70_COUNT}x Intel Arc Pro B70"
echo "  Compute runtime:  $(dnf list installed intel-compute-runtime 2>/dev/null | grep intel-compute-runtime | awk '{print $2}')"
echo "  IGC:              $(dnf list installed intel-igc 2>/dev/null | grep intel-igc | awk '{print $2}')"
echo "  Mesa:             $(dnf list installed mesa-vulkan-drivers 2>/dev/null | grep mesa-vulkan | awk '{print $2}')"
echo ""
echo "Scripts:"
echo "  ~/start_llamacpp_sycl.sh       — Start llama.cpp SYCL server"
echo "  ~/start_llamacpp_vulkan.sh      — Start llama.cpp Vulkan server"
echo "  ~/sysinfo-b70.sh                — System status"
echo "  ~/xe_tuning.sh                  — GPU driver tuning (auto at boot)"
echo ""
echo "Usage:"
echo "  # Download a model, then:"
echo "  ~/start_llamacpp_sycl.sh ~/models/my-model.gguf 8000 SYCL0"
echo ""
echo "  # Test the API:"
echo "  curl http://localhost:8000/v1/chat/completions \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"model\":\"default\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}],\"max_tokens\":100}'"
echo ""
echo "GPU monitoring:"
echo "  xpu-smi stats     — Power, frequency, VRAM (install separately)"
echo "  sensors           — GPU temperature (if lm_sensors configured)"
echo "  cat /sys/class/drm/card*/device/mem_info_vram_*  — VRAM usage"
echo ""
echo "Troubleshooting:"
echo "  dmesg | grep xe                    — Check xe driver messages"
echo "  ls /dev/dri/render*                — Check GPU device nodes"
echo "  vulkaninfo --summary               — Vulkan device list"
echo "  /usr/libexec/oneapi-level-zero/zello_world  — Level Zero test"
echo ""
if [[ "${NEED_REBOOT}" == "true" ]]; then
    echo "================================================================"
    echo "  REBOOT REQUIRED!"
    echo "  New kernel parameters (iommu=pt, pci=realloc) need a reboot."
    echo "  Run: sudo reboot"
    echo "  After reboot: source /opt/intel/oneapi/setvars.sh"
    echo "================================================================"
fi
echo ""
echo "Log saved to: ${LOG}"
