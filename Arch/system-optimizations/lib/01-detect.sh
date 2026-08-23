#!/usr/bin/env bash
# 01-detect.sh — detects hardware/environment and exports globals:
#   CPU_VENDOR         amd | intel
#   MARCH_LEVEL         x86-64-v2 | x86-64-v3 | x86-64-v4 | x86-64 (baseline)
#   GPU_VENDORS         space-separated subset of: amd nvidia intel
#   HAS_DISCRETE_GPU    1 | 0
#   BOOTLOADER          grub | systemd-boot | limine | unknown
#   ROOT_FS             btrfs | ext4 | <whatever findmnt reports> | unknown
#   INITRAMFS_STYLE     systemd | busybox
#
# Must be sourced after 00-utils.sh.
#
# IMPORTANT — bare `VAR=$(command)` assignments are dangerous under
# `set -e`: if `command` (or, with pipefail, ANY stage of a pipeline
# feeding it) returns non-zero, the assignment itself fails and the
# ENTIRE SCRIPT exits immediately and silently — no error message, no
# indication of what failed or why. This bit us for real: detect_root_fs()
# used to be exactly `ROOT_FS=$(findmnt -no FSTYPE / )` with no guard,
# and if findmnt returned non-zero for any reason, the whole install.sh
# run would die right there with zero output. Every detection below is
# now wrapped in `if VAR=$(command); then ... else ...; fi` — that form
# IS safe under set -e (failures inside an if-condition don't trigger it)
# — with an explicit log_warn and a safe fallback value on failure, so a
# single detection glitch degrades gracefully instead of killing the
# entire run silently.

detect_cpu_vendor() {
    local vendor
    if vendor=$(grep -m1 'vendor_id' /proc/cpuinfo | awk '{print $3}'); then
        case "$vendor" in
            AuthenticAMD) CPU_VENDOR="amd" ;;
            GenuineIntel) CPU_VENDOR="intel" ;;
            *) CPU_VENDOR="unknown" ;;
        esac
    else
        log_warn "Could not read CPU vendor from /proc/cpuinfo — defaulting to 'unknown'."
        CPU_VENDOR="unknown"
    fi
    log_info "CPU vendor: $CPU_VENDOR"
}

detect_march_level() {
    # ld.so --help reports which x86-64 levels the CPU supports (glibc 2.33+ / systemd 249+).
    local help_out=""
    if ! help_out=$(/lib/ld-linux-x86-64.so.2 --help 2>/dev/null); then
        if ! help_out=$(/usr/lib/ld-linux-x86-64.so.2 --help 2>/dev/null); then
            log_warn "Could not query ld.so for microarch level (neither /lib nor /usr/lib ld-linux-x86-64.so.2 responded) — defaulting to baseline x86-64."
            help_out=""
        fi
    fi

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
    local pci_vga=""
    if ! pci_vga=$(lspci -nnk 2>/dev/null | grep -Ei 'VGA|3D controller|Display controller'); then
        # grep returns non-zero if lspci exists but nothing matched (or if
        # lspci itself isn't installed) — either way, treat as "no GPU
        # info available" rather than killing the script.
        log_warn "Could not identify any GPU via lspci — GPU driver setup will be skipped."
        pci_vga=""
    fi

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

    if ! GPU_VENDORS=$(echo "$GPU_VENDORS" | xargs); then
        GPU_VENDORS=""
    fi
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
    if [[ "$BOOTLOADER" == "unknown" ]]; then
        log_warn "Could not detect bootloader — kernel-parameter steps will be skipped."
    fi
}

detect_root_fs() {
    if ROOT_FS=$(findmnt -no FSTYPE / 2>/dev/null); then
        log_info "Root filesystem: $ROOT_FS"
    else
        log_warn "findmnt could not determine the root filesystem type — defaulting ROOT_FS to 'unknown'. The swap module will use the conventional (non-Btrfs) swapfile method."
        ROOT_FS="unknown"
    fi
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
    log_info "Detection complete."
}
