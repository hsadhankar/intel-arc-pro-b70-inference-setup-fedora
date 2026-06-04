# Intel Arc Pro B70 Inference Setup — Fedora

Set up an Intel Arc Pro B70 GPU (Battlemage e223, 32 GB VRAM) on **Fedora 44** to run local LLM inference with `llama.cpp`.

## Hardware requirements

| Component | Requirement |
|---|---|
| GPU | Intel Arc Pro B70 (device e223, Battlemage) — 32 GB VRAM |
| System RAM | 32 GB minimum, 64 GB+ recommended for 32K context |
| OS | Fedora 44 (kernel 6.19+ includes the Battlemage `xe` driver) |

### BIOS settings

Set these before running the setup script:

| Setting | Value |
|---|---|
| Above 4G Decoding | **ENABLED** |
| Resizable BAR | **ENABLED** |
| CSM | **DISABLED** (UEFI boot only) |
| IOMMU | **ENABLED** |

## Quick start

```bash
# 1. Clone the repo
git clone https://github.com/your-username/intel-arc-pro-b70-inference-setup-fedora.git
cd intel-arc-pro-b70-inference-setup-fedora

# 2. Run the setup (installs everything — kernel params, compute stack,
#    oneAPI, builds llama.cpp with both SYCL and Vulkan backends)
sudo ./fedora-b70-setup.sh

# 3. If the script modified GRUB, reboot now:
sudo reboot

# 4. Download a GGUF model (example with huggingface-cli)
mkdir -p ~/models
huggingface-cli download unsloth/Qwen3.6-27B-GGUF Qwen3.6-27B-UD-Q4_K_XL.gguf \
    --local-dir ~/models --local-dir-use-symlinks False

# 5. Start the server (SYCL backend — best performance)
~/start_llamacpp_sycl.sh ~/models/Qwen3.6-27B-UD-Q4_K_XL.gguf 8000 SYCL0

# 6. Test the API
curl http://localhost:8000/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d '{"model":"default","messages":[{"role":"user","content":"Hello"}],"max_tokens":100}'
```

The `--download` flag can also be used to download and serve in one step:

```bash
~/start_llamacpp_sycl.sh --download unsloth/Qwen3.6-27B-GGUF UD-Q4_K_XL 8000 SYCL0
```

## Scripts

All scripts installed to `~/` by the setup script.

| Script | Purpose |
|---|---|
| `~/start_llamacpp_sycl.sh` | Launch llama-server with the **SYCL** backend. `source`s oneAPI, sets critical env vars. |
| `~/start_llamacpp_vulkan.sh` | Launch llama-server with the **Vulkan** backend. |
| `~/sysinfo-b70.sh` | Print GPU, VRAM, driver, and build info. |
| `~/xe_tuning.sh` | Tune the `xe` kernel driver for inference workloads (safe to re-run anytime). |

### Backend comparison

| Backend | Performance | Requires | Build location |
|---|---|---|---|
| **SYCL** | Best (~20% faster with flash attention on XMX engines) | oneAPI DPC++ compiler + MKL | `~/llama.cpp/build_sycl/bin/llama-server` |
| **Vulkan** | Good, no toolchain dependency | Mesa Vulkan drivers (shipped with Fedora) | `~/llama.cpp/build_vulkan/bin/llama-server` |

## SYCL environment variables

These are set automatically by the start script:

| Variable | Purpose |
|---|---|
| `GGML_SYCL_DISABLE_OPT=1` | Required for MoE models (avoids SEGV). Remove for dense models for ~5% more performance. |
| `UR_L0_ENABLE_RELAXED_ALLOCATION_LIMITS=1` | Allow allocations larger than 4 GB VRAM. |
| `GGML_SYCL_ENABLE_FLASH_ATTN=1` | Flash Attention on XMX matrix engines (~20% throughput gain). |
| `SYCL_CACHE_PERSISTENT=0` | Disable stale JIT cache between runs. |

oneAPI environment is sourced automatically: `source /opt/intel/oneapi/setvars.sh` (also sourced in `/etc/profile.d/oneapi.sh` and `~/.bashrc`).

## Post-setup diagnostics

```bash
# System + GPU summary
~/sysinfo-b70.sh

# VRAM usage
sudo cat /sys/class/drm/card*/device/mem_info_vram_*

# xe driver messages
dmesg | grep xe

# Vulkan device list
vulkaninfo --summary

# Level Zero test
/usr/libexec/oneapi-level-zero/zello_world

# GPU power, frequency, VRAM (install separately)
xpu-smi stats

# GPU temperature (if lm_sensors is configured)
sensors | grep -E "xe|PCH|GPU|edge"
```

## What the setup script does

1. Installs system packages (build tools, Vulkan, Mesa)
2. Configures GRUB kernel parameters (`iommu=pt`, `pci=realloc`)
3. Installs Intel compute runtime, Level Zero, and IGC from Fedora repos
4. Updates GuC/HuC firmware for Battlemage
5. Installs Intel oneAPI Base Toolkit (DPC++ compiler + MKL for SYCL)
6. Builds `llama.cpp` from source with SYCL backend (`~/llama.cpp/build_sycl/`)
7. Builds `llama.cpp` with Vulkan backend (`~/llama.cpp/build_vulkan/`)
8. Installs launcher scripts + `xe-tuning.service` (systemd, runs `~/xe_tuning.sh` at boot)

Check the full log: `/tmp/fedora-b70-setup.log`

## Troubleshooting

| Symptom | Check |
|---|---|
| GPU not detected | `lspci -nn | grep e223` — verify BIOS settings (Above 4G + ReBAR) |
| xe driver issues | `dmesg | grep xe` — check firmware load errors |
| No GPU device nodes | `ls /dev/dri/render*` — verify user is in `video` and `render` groups |
| SYCL build fails | oneAPI not installed correctly — run `source /opt/intel/oneapi/setvars.sh` and check `which icpx` |
| Vulkan not working | `vulkaninfo --summary` — install `mesa-vulkan-drivers` |

## Credits

This repo is a Fedora adaptation of [Hal9000AIML/arc-pro-b70-inference-setup-ubuntu-server](https://github.com/Hal9000AIML/arc-pro-b70-inference-setup-ubuntu-server). Most of the logic is from the original — we ported the package manager commands, kernel config paths, and firmware handling to match Fedora 44.

## License

MIT
