#!/usr/bin/env bash
# 09-gpu.sh — installs GPU driver packages based on GPU_VENDORS/HAS_DISCRETE_GPU
# from 01-detect.sh. Skips entirely if no discrete GPU was found.
#
# Nvidia: uses the nvidia-open stack (open-source kernel modules, the
#   modern recommended default for Turing/RTX-20xx and newer). Nouveau is
#   noted as a fallback in comments but not installed alongside it.
# AMD: mesa + vulkan-radeon + amdgpu userspace stack.
# Intel: hardware video acceleration stack (relevant whether Intel is the
#   only GPU or paired with a discrete AMD/Nvidia card).

setup_gpu_drivers() {
    if [[ "$HAS_DISCRETE_GPU" -ne 1 ]]; then
        log_skip "No discrete GPU detected — skipping GPU driver module entirely"
        return 0
    fi

    pkg_install mesa vulkan-icd-loader

    [[ "$GPU_VENDORS" == *amd*    ]] && _setup_amd_gpu
    [[ "$GPU_VENDORS" == *nvidia* ]] && _setup_nvidia_gpu
    [[ "$GPU_VENDORS" == *intel*  ]] && _setup_intel_gpu
}

_setup_amd_gpu() {
    log_info "Configuring AMD GPU stack..."
    pkg_install vulkan-radeon rocm-smi-lib
    aur_install lact   # GUI/CLI AMD overclocking+fan-control tool (rovclock equivalent)
    log_success "AMD GPU stack installed (mesa, vulkan-radeon, rocm-smi-lib, lact)"
}

_setup_nvidia_gpu() {
    log_info "Configuring Nvidia GPU stack (nvidia-open)..."
    pkg_install nvidia-open-dkms nvidia-utils linux-headers
    # nvidia_uvm is loaded automatically by the nvidia-utils udev rules /
    # nvidia-persistenced on modern setups; ensure the module loads at boot.
    if ! grep -q '^nvidia_uvm' /etc/modules-load.d/nvidia.conf 2>/dev/null; then
        mkdir -p /etc/modules-load.d
        echo "nvidia_uvm" >> /etc/modules-load.d/nvidia.conf
    fi
    aur_install nvclock 2>/dev/null || log_warn "nvclock unavailable in AUR — consider nvidia-settings/coolbits instead"
    log_success "Nvidia GPU stack installed (nvidia-open-dkms, nvidia-utils, nvidia_uvm)"
    log_info "Note: nouveau is NOT installed alongside the proprietary stack (avoid conflicts)."
}

_setup_intel_gpu() {
    log_info "Configuring Intel GPU hardware video acceleration stack..."
    pkg_install vulkan-intel intel-media-driver libva-intel-driver libvpl vpl-gpu-rt
    aur_install intel-hybrid-codec-driver-git
    log_success "Intel GPU stack installed (vulkan-intel, intel-media-driver, libva-intel-driver, libvpl, vpl-gpu-rt)"
}
