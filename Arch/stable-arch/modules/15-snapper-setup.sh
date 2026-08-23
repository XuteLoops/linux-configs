#!/bin/bash
#
# 15-snapper-setup.sh
#
# Standalone module: installs and configures snapper + snap-pac, the
# BTRFS snapshotting foundation the rest of this pipeline (pacback,
# bootloader snapshot-boot integration) relies on.
#
# Requires: a BTRFS filesystem with root (/) on a subvolume. Does not
# create or modify subvolumes itself — only configures snapper against
# the existing layout.
#
# Safe to re-run.
#
# Usage:
#   sudo ./15-snapper-setup.sh
#
set -euo pipefail

log() { echo "==> $*"; }
warn() { echo "WARNING: $*" >&2; }

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root (e.g. sudo $0)" >&2
    exit 1
fi

ensure_pkg_installed() {
    local to_install=()
    local pkg
    for pkg in "$@"; do
        if pacman -Qi "$pkg" &>/dev/null; then
            log "Already installed: $pkg"
        else
            to_install+=("$pkg")
        fi
    done
    if [ "${#to_install[@]}" -gt 0 ]; then
        log "Installing: ${to_install[*]}"
        pacman -S --needed --noconfirm "${to_install[@]}"
    fi
}

if ! findmnt -no FSTYPE / | grep -qx btrfs; then
    echo "Root filesystem is not BTRFS — snapper needs a BTRFS root to work. Aborting." >&2
    exit 1
fi

log "Installing snapper and snap-pac..."
ensure_pkg_installed snapper snap-pac

if [ -f /etc/snapper/configs/root ]; then
    log "snapper 'root' config already exists, skipping create-config"
else
    log "Creating snapper 'root' config..."
    if ! snapper -c root create-config /; then
        echo "snapper create-config failed. This usually means /.snapshots already" >&2
        echo "exists as a plain directory (not a subvolume) from a prior/manual" >&2
        echo "attempt. Resolve manually (see the ArchWiki Snapper page's" >&2
        echo "'Suggested filesystem layout' section) and re-run this module." >&2
        exit 1
    fi
fi

CONF_FILE=/etc/conf.d/snapper
if [ ! -f "$CONF_FILE" ]; then
    log "Creating $CONF_FILE..."
    echo 'SNAPPER_CONFIGS=""' > "$CONF_FILE"
fi

if grep -q '^SNAPPER_CONFIGS=' "$CONF_FILE"; then
    CURRENT_VAL=$(grep -oP '(?<=^SNAPPER_CONFIGS=")[^"]*' "$CONF_FILE" || echo "")
    if echo " $CURRENT_VAL " | grep -q ' root '; then
        log "'root' already present in SNAPPER_CONFIGS"
    else
        NEW_VAL=$(echo "$CURRENT_VAL root" | xargs)
        log "Adding 'root' to SNAPPER_CONFIGS..."
        sed -i "s|^SNAPPER_CONFIGS=.*|SNAPPER_CONFIGS=\"$NEW_VAL\"|" "$CONF_FILE"
    fi
else
    log "Adding SNAPPER_CONFIGS=\"root\" to $CONF_FILE..."
    echo 'SNAPPER_CONFIGS="root"' >> "$CONF_FILE"
fi

log "Enabling snapper timers..."
systemctl enable --now snapper-timeline.timer
systemctl enable --now snapper-cleanup.timer

echo
log "Done."
log "Snapper config: /etc/snapper/configs/root"
log "Confirm with: snapper -c root list"