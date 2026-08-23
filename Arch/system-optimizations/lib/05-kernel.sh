#!/usr/bin/env bash
# 05-kernel.sh — installs linux-zen (official repos, prebuilt — no
# CachyOS repo, no AUR, no compiling), scx-scheds + scx-tools for
# sched_ext scheduler switching, sets preempt=full, and conditionally
# sets libahci.ignore_sss=1 if the SSS quirk is detected.
#
# Note on scope: BORE (the scheduler CachyOS's *-bore kernels use) is a
# patch to the CFS scheduling class itself — it is NOT available as a
# runtime-loadable sched_ext program, so it genuinely requires a custom-
# compiled kernel. What IS available on stock linux-zen via official
# packages is sched_ext (SCX): a kernel framework (mainlined in 6.12)
# that lets you swap in alternative CPU schedulers at runtime with zero
# compiling.
#
# Scheduler choice: no single scx scheduler is simultaneously optimal for
# both gaming and audio production — scx_lavd is the most latency-tuned
# for gaming (Steam Deck's default), while scx_flash is purpose-built for
# multimedia/real-time audio workloads (EDF policy that prioritizes tasks
# that yield the CPU early, matching an audio callback's behavior). Since
# only one scx scheduler can be active at a time, this sets scx_bpfland
# as the persistent boot default (solid general-purpose middle ground)
# and installs two helper scripts for switching into gaming or audio
# mode on demand via SCX_SCHEDULER_OVERRIDE (temporary, doesn't touch the
# persistent default, doesn't survive reboot).

install_kernel() {
    pkg_install linux-zen linux-zen-headers
}

setup_scx_scheduler() {
    pkg_install scx-scheds scx-tools

    local conf="/etc/default/scx"
    backup_file "$conf"

    cat > "$conf" <<'EOF'
SCX_SCHEDULER=scx_bpfland
SCX_FLAGS=
EOF
    log_success "Configured $conf (SCX_SCHEDULER=scx_bpfland as general-purpose default)"

    enable_service scx.service

    _install_scx_switch_script "scx-gaming" "scx_lavd" \
        "Switches to scx_lavd (Steam Deck's scheduler, most latency-tuned for gaming) for this session."
    _install_scx_switch_script "scx-audio" "scx_flash" \
        "Switches to scx_flash (purpose-built for multimedia/real-time audio workloads) for this session."
    _install_scx_switch_script "scx-default" "scx_bpfland" \
        "Switches back to the persistent default (scx_bpfland)."

    log_info "Scheduler switching: run 'scx-gaming' before gaming, 'scx-audio' before audio production, 'scx-default' to return to the everyday default. Each takes effect immediately, no reboot."
    log_warn "If you notice audio cracking/static with any scx scheduler active (including the default), that's a known occasional interaction — try 'scx-default', and if it persists, stop scx.service entirely to fall back to the kernel's built-in scheduler."
}

_install_scx_switch_script() {
    local name="$1" scheduler="$2" description="$3"
    local path="/usr/local/bin/${name}"
    cat > "$path" <<EOF
#!/usr/bin/env bash
# ${description}
# Temporary override — does not change the persistent default in
# /etc/default/scx, and does not survive a reboot.
set -e
sudo systemctl set-environment SCX_SCHEDULER_OVERRIDE=${scheduler}
sudo systemctl restart scx.service
echo "Switched to ${scheduler}."
EOF
    chmod +x "$path"
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
