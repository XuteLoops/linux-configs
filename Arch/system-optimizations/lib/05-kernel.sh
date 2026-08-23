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
# multimedia/real-time audio workloads. Since only one scx scheduler can
# be active at a time, this sets scx_bpfland as the persistent boot
# default (solid general-purpose middle ground) and installs helper
# scripts for switching into gaming or audio mode on demand.
#
# Mechanism: scx_loader.service (from scx-tools), configured via
# /etc/scx_loader.toml — NOT scx.service + /etc/default/scx, which an
# earlier version of this script incorrectly targeted. Confirmed against
# the actual installed package's file list (`pacman -Ql scx-tools`) that
# scx.service does not exist at all in Arch's real packages; only
# scx_loader.service does. scx_loader is a D-Bus daemon configured via a
# TOML file (search order: /etc/scx_loader/config.toml,
# /etc/scx_loader.toml, then vendor defaults), not environment variables.
# Flag values below (scx_bpfland's "auto" mode, scx_lavd's gaming mode)
# are copied verbatim from scx_loader's own official example config —
# not invented.

install_kernel() {
    pkg_install linux-zen linux-zen-headers
}

setup_scx_scheduler() {
    pkg_install scx-scheds scx-tools

    local conf="/etc/scx_loader.toml"
    backup_file "$conf"

    cat > "$conf" <<'EOF'
default_sched = "scx_bpfland"
default_mode = "Auto"

[scheds.scx_bpfland]
auto_mode = ["-m", "auto"]

[scheds.scx_lavd]
gaming_mode = ["--performance", "--pinned-slice-us", "500"]

[scheds.scx_flash]
EOF
    log_success "Configured $conf (default_sched = scx_bpfland, general-purpose default)"

    enable_service scx_loader.service

    _install_scx_switch_script "scx-gaming" "scx_lavd" "Gaming" \
        "Switches to scx_lavd (Steam Deck's scheduler, most latency-tuned for gaming) for this session."
    _install_scx_switch_script "scx-audio" "scx_flash" "Auto" \
        "Switches to scx_flash (purpose-built for multimedia/real-time audio workloads) for this session."
    _install_scx_switch_script "scx-default" "scx_bpfland" "Auto" \
        "Switches back to the persistent default (scx_bpfland)."

    log_info "Scheduler switching: run 'scx-gaming' before gaming, 'scx-audio' before audio production, 'scx-default' to return to the everyday default. Each restarts scx_loader.service to apply immediately, no reboot."
    log_warn "If you notice audio cracking/static with any scx scheduler active (including the default), that's a known occasional interaction — try 'scx-default', and if it persists, stop scx_loader.service entirely to fall back to the kernel's built-in scheduler."
}

# Updates the two top-level scalar fields (default_sched, default_mode)
# in /etc/scx_loader.toml and restarts the service to apply. Only
# targets these two lines specifically — they're simple `key = "value"`
# assignments at the top of the file, before any [section] headers, so a
# line-anchored sed replace is safe here (unlike the multi-line-value
# risk that applies to shell config files like makepkg.conf).
_install_scx_switch_script() {
    local name="$1" scheduler="$2" mode="$3" description="$4"
    local path="/usr/local/bin/${name}"
    cat > "$path" <<EOF
#!/usr/bin/env bash
# ${description}
set -e
sudo sed -i 's|^default_sched = .*|default_sched = "${scheduler}"|' /etc/scx_loader.toml
sudo sed -i 's|^default_mode = .*|default_mode = "${mode}"|' /etc/scx_loader.toml
sudo systemctl restart scx_loader.service
echo "Switched to ${scheduler} (${mode} mode)."
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