#!/usr/bin/env bash
#
# 01-discord-vesktop.sh — installs Vesktop instead of stock Discord.
#
# Vesktop is a wrapper around the real Discord client (same account,
# same login) built with better Wayland/PipeWire screen-share and
# audio-share support (via Venmic) than the official client historically
# had. Official client has improved, but Vesktop remains the more
# consistently reliable choice, especially for sharing audio while
# screen sharing — so it's the default here rather than stock Discord.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

install_vesktop() {
    log_info "Installing Vesktop..."

    if aur_install vesktop-bin; then
        log_ok "Vesktop installed."
    else
        log_warn "vesktop-bin AUR install failed — check AUR page for updates."
        log_info "Falling back to stock Discord..."
        aur_install discord || log_warn "discord AUR install also failed."
    fi
}

install_vesktop
