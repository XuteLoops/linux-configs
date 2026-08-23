#!/usr/bin/env bash
# 05-kernel.sh — installs linux-cachyos, sets preempt=full, and
# conditionally sets libahci.ignore_sss=1 if the SSS quirk is detected.

install_cachyos_kernel() {
    if grep -q '\[cachyos' /etc/pacman.conf 2>/dev/null; then
        log_skip "CachyOS repo already configured"
    else
        log_info "Adding CachyOS repo..."
        curl -fsSL https://mirror.cachyos.org/cachyos-repo.tar.xz -o /tmp/cachyos-repo.tar.xz \
            && tar xf /tmp/cachyos-repo.tar.xz -C /tmp \
            && (cd /tmp/cachyos-repo && ./cachyos-repo.sh) \
            || log_warn "Automated CachyOS repo setup failed — install manually per wiki.cachyos.org"
    fi

    pkg_install linux-cachyos linux-cachyos-headers
}

set_preempt_full() {
    add_kernel_param "preempt=full"
}

check_libahci_sss_quirk() {
    if dmesg | grep -qi 'sss'; then
        log_info "libahci SSS quirk detected in dmesg — adding libahci.ignore_sss=1"
        add_kernel_param "libahci.ignore_sss=1"
    else
        log_skip "No libahci SSS quirk detected — libahci.ignore_sss=1 not needed"
    fi
}
