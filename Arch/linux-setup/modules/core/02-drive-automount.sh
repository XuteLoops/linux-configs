#!/usr/bin/env bash
#
# 02-drive-automount.sh — auto-mount non-system drives at login/plug-in.
#
# Uses udisks2, which is what KDE/GNOME's own automount uses under the
# hood, so this works even outside a full desktop session (e.g. if
# you're on a minimal window manager) and doesn't fight with the DE's
# own automount if one is already running.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

install_automount() {
    require_root
    log_info "Setting up drive automount..."

    pkg_install udisks2 udiskie

    local target
    target="$(target_user)"
    local autostart_dir="/home/$target/.config/autostart"
    local desktop_file="$autostart_dir/udiskie.desktop"

    run_as_user mkdir -p "$autostart_dir"

    deploy_file "$desktop_file" <<'EOF'
[Desktop Entry]
Type=Application
Name=udiskie
Comment=Automount removable media
Exec=udiskie --tray
Icon=drive-removable-media
X-GNOME-Autostart-enabled=true
EOF

    chown "$target:$target" "$desktop_file"

    log_ok "udiskie will auto-mount removable/external drives on next login."
    log_info "For fixed internal drives you want mounted every boot"
    log_info "regardless of login (not just removable media), add entries"
    log_info "to /etc/fstab manually — that's deliberately not automated"
    log_info "here since wrong UUIDs/mount options in fstab can prevent"
    log_info "boot."
}

install_automount
