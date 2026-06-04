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
for card in /sys/class/drm/card[0-9]*; do
    total=$(cat "$card/device/mem_info_vram_total" 2>/dev/null) || continue
    vendor=$(cat "$card/device/vendor" 2>/dev/null)
    name="GPU"
    case "$vendor" in
        0x8086) name="Intel" ;;
        0x1002) name="AMD" ;;
        0x10de) name="NVIDIA" ;;
    esac
    echo "  ${name} VRAM Total: $(awk "BEGIN {printf \"%.2f GiB\", $total/1073741824}")"
    free=$(cat "$card/device/mem_info_vram_free" 2>/dev/null)
    [[ -n "$free" ]] && echo "  ${name} VRAM Free:  $(awk "BEGIN {printf \"%.2f GiB\", $free/1073741824}")"
done
# For Intel Arc GPUs without a DRM node (xe driver), read VRAM from PCI BAR
for dev in $(lspci -nn | grep -i "Battlemage" | cut -d' ' -f1); do
    driver=$(lspci -k -s "$dev" 2>/dev/null | awk -F': ' '/Kernel driver in use/{print $2}')
    modules=$(lspci -k -s "$dev" 2>/dev/null | awk -F': ' '/Kernel modules/{print $2}')
    bar=$(lspci -vvv -s "$dev" 2>/dev/null | grep -i "Region 2" | grep -oP 'size=\K[0-9]+[MG]')
    if [[ -n "$bar" ]]; then
        if [[ -n "$driver" ]]; then
            echo "  Intel Arc VRAM (from BAR): $bar (driver: $driver)"
        else
            echo "  Intel Arc VRAM (from BAR): $bar (module: ${modules:-none} — not bound)"
        fi
    fi
done
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
