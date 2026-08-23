#!/usr/bin/env bash
# 07-audio.sh — rtkit for PipeWire realtime scheduling rights, audio
# group membership, and PipeWire latency global defaults.

setup_rtkit() {
    pkg_install rtkit
    # Correct unit name is rtkit-daemon.service — confirmed against the
    # actual rtkit package file list (usr/lib/systemd/system/rtkit-daemon.service).
    # An earlier version of this script had this wrong as "rtkitd.service",
    # which doesn't exist under that name and silently failed to enable.
    enable_service rtkit-daemon.service
}

add_user_to_audio_group() {
    local user
    user=$(target_user)
    if id -nG "$user" | grep -qw audio; then
        log_skip "$user already in audio group"
    else
        usermod -aG audio "$user" \
            && log_success "Added $user to audio group (re-login required to take effect)"
    fi
}

configure_pipewire_latency() {
    local dropin_dir="/etc/pipewire/pipewire.conf.d"
    mkdir -p "$dropin_dir"

    # Lower default quantum for reduced latency. Adjust quantum values to
    # taste — 32/32768 gives a good low-latency default for most desktop
    # audio interfaces without being so aggressive it causes xruns on
    # generic onboard hardware.
    cat > "$dropin_dir/99-low-latency.conf" <<'EOF'
context.properties = {
    default.clock.rate = 48000
    default.clock.quantum = 1024
    default.clock.min-quantum = 32
    default.clock.max-quantum = 32768
}
EOF
    log_success "Wrote PipeWire low-latency defaults to $dropin_dir/99-low-latency.conf"
    log_info "Restart pipewire (systemctl --user restart pipewire wireplumber) or re-login to apply."
}