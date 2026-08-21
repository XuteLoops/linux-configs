#!/bin/bash
#
# 50-paccache.sh
#
# Standalone module: installs pacman-contrib and enables paccache.timer
# to periodically prune old cached package versions.
#
# Safe to re-run.
#
# Usage:
#   sudo ./50-paccache.sh
#
set -euo pipefail

log() { echo "==> $*"; }
warn() { echo "WARNING: $*" >&2; }

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root (e.g. sudo $0)" >&2
    exit 1
fi

ensure_pkg_installed() {
    local pkg="$1"
    if pacman -Qi "$pkg" &>/dev/null; then
        log "Already installed: $pkg"
    else
        log "Installing: $pkg"
        pacman -S --needed --noconfirm "$pkg"
    fi
}

log "Installing pacman-contrib..."
ensure_pkg_installed pacman-contrib

log "Enabling paccache.timer..."
systemctl enable --now paccache.timer

echo
log "Done."
