#!/usr/bin/env bash
#
# cloud-sync.sh — PERSONAL SCRIPT. Google Drive, MEGA, and Resilio Sync.
# Not part of any shared bundle — run this directly and only on your own
# machine (friends may not use these same services).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

install_google_drive() {
    log_info "Installing Google Drive support..."
    # No official native Linux client. rclone + a mount, or a GUI wrapper
    # like gnome-online-accounts (for Nautilus integration), are the
    # common approaches. Defaulting to rclone since it's the more
    # DE-independent option.
    pkg_install rclone
    log_info "rclone installed. Run 'rclone config' manually to authenticate"
    log_info "(interactive OAuth flow — not scriptable unattended)."
}

install_mega() {
    log_info "Installing MEGAsync..."
    if aur_install megasync-bin; then
        log_ok "MEGAsync installed."
    else
        log_warn "megasync-bin AUR install failed — check AUR page for updates."
    fi
}

install_resilio_sync() {
    log_info "Installing Resilio Sync..."
    if aur_install resilio-sync; then
        log_ok "Resilio Sync installed."
        log_info "Enable and start the service if you want it running as a"
        log_info "daemon rather than the GUI app:"
        log_info "  sudo systemctl enable --now resilio-sync"
    else
        log_warn "resilio-sync AUR install failed — check AUR page for updates."
    fi
}

install_google_drive
install_mega
install_resilio_sync
