#!/usr/bin/env bash
# 01-detect.sh — detects hardware/environment and exports globals:
#   CPU_VENDOR         amd | intel
#   MARCH_LEVEL         x86-64-v2 | x86-64-v3 | x86-64-v4 | x86-64 (baseline)
#   GPU_VENDORS         space-separated subset of: amd nvidia intel
#   HAS_DISCRETE_GPU    1 | 0
#   BOOTLOADER          grub | systemd-boot | limine | unknown
#   ROOT_FS             btrfs | ext4 | <whatever findmnt reports>
#   INITRAMFS_STYLE     systemd | busybox
#
# Must be sourced after 00-utils.sh.

detect_cpu_vendor() {
    local vendor
    vendor=$(grep -m1 'vendor_id' /proc/cpuinfo | awk '{print $3}')
    case "$vendor" in
        AuthenticAMD) CPU_VENDOR="amd" ;;
        GenuineIntel) CPU_VENDOR="intel" ;;
        *) CPU_VENDOR="unknown" ;;
    esac
    log_info "CPU vendor: $CPU_VENDOR"
}

detect_march_level() {
    # ld.so --help reports which x86-64 levels the CPU supports (glibc 2.33+ / systemd 249+).
    local help_out
    help_out=$(/lib/ld-linux-x86-64.so.2 --help 2>/dev/null || /usr/lib/ld-linux-x86-64.so.2 --help 2>/dev/null)

    if grep -q 'x86-64-v4 (supported' <<<"$help_out"; then
        MARCH_LEVEL="x86-64-v4"
    elif grep -q 'x86-64-v3 (supported' <<<"$help_out"; then
        MARCH_LEVEL="x86-64-v3"
    elif grep -q 'x86-64-v2 (supported' <<<"$help_out"; then
        MARCH_LEVEL="x86-64-v2"
    else
        MARCH_LEVEL="x86-64"
    fi
    log_info "CPU microarch level: $MARCH_LEVEL (used for ALHP repo selection)"
}

detect_gpu() {
    local pci_vga
    pci_vga=$(lspci -nnk 2>/dev/null | grep -Ei 'VGA|3D controller|Display controller')

    GPU_VENDORS=""
    HAS_DISCRETE_GPU=0

    if grep -qi 'nvidia' <<<"$pci_vga"; then
        GPU_VENDORS+="nvidia "
        HAS_DISCRETE_GPU=1
    fi
    if grep -qi 'amd\|advanced micro devices\|ati' <<<"$pci_vga"; then
        # AMD APU (integrated) will also match this — that's fine, the AMD
        # driver stack (mesa/amdgpu) covers both integrated and discrete.
        GPU_VENDORS+="amd "
        # Only count as "discrete" if there's more than one AMD GPU entry style
        # heuristic: presence of a dedicated "3D controller" or non-APU naming.
        if grep -qi '3D controller' <<<"$pci_vga"; then
            HAS_DISCRETE_GPU=1
        fi
    fi
    if grep -qi 'intel' <<<"$pci_vga"; then
        GPU_VENDORS+="intel "
    fi

    GPU_VENDORS=$(echo "$GPU_VENDORS" | xargs)
    log_info "Detected GPU vendor(s): ${GPU_VENDORS:-none}"
    log_info "Discrete GPU present: $([[ $HAS_DISCRETE_GPU -eq 1 ]] && echo yes || echo no)"
}

detect_bootloader() {
    if [[ -f /boot/limine/limine.conf ]] || compgen -G "/boot/EFI/*/limine.conf" >/dev/null 2>&1; then
        BOOTLOADER="limine"
    elif [[ -f /boot/loader/loader.conf ]]; then
        BOOTLOADER="systemd-boot"
    elif [[ -f /etc/default/grub ]] && command -v grub-mkconfig &>/dev/null; then
        BOOTLOADER="grub"
    else
        BOOTLOADER="unknown"
    fi
    log_info "Bootloader detected: $BOOTLOADER"
    [[ "$BOOTLOADER" == "unknown" ]] && log_warn "Could not detect bootloader — kernel-parameter steps will be skipped."
}

detect_root_fs() {
    ROOT_FS=$(findmnt -no FSTYPE / )
    log_info "Root filesystem: $ROOT_FS"
}

detect_initramfs_style() {
    if grep -qE '^HOOKS=.*\bsystemd\b' /etc/mkinitcpio.conf 2>/dev/null; then
        INITRAMFS_STYLE="systemd"
    else
        INITRAMFS_STYLE="busybox"
    fi
    log_info "Initramfs style: $INITRAMFS_STYLE"
}

run_detection() {
    log_info "Running hardware/environment detection..."
    detect_cpu_vendor
    detect_march_level
    detect_gpu
    detect_bootloader
    detect_root_fs
    detect_initramfs_style
}
