#!/bin/bash
#
# 00-aur-helpers.sh
#
# Standalone module: ensures an AUR helper is available. If yay or paru
# is already installed, does nothing — doesn't install a second helper
# just for the sake of it. If neither is present, installs paru (chosen
# over yay for being Rust-based/generally faster), which is then used
# by every other module in this pipeline that needs one.
#
# Not a hard prerequisite for the other modules — they each carry this
# same check-then-bootstrap logic inline — but running this first means
# later modules will find paru already there instead of bootstrapping
# it themselves.
#
# Safe to re-run.
#
# Usage:
#   sudo ./00-aur-helpers.sh
#
set -euo pipefail

log() { echo "==> $*"; }
warn() { echo "WARNING: $*" >&2; }

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root (e.g. sudo $0)" >&2
    exit 1
fi

BUILD_USER="${SUDO_USER:-}"
if [ -z "$BUILD_USER" ] || [ "$BUILD_USER" = "root" ]; then
    echo "Could not determine a non-root build user (run this via 'sudo', not as root directly)." >&2
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

if command -v yay &>/dev/null; then
    log "yay already installed — using it, not installing paru alongside it."
    exit 0
fi

if command -v paru &>/dev/null; then
    log "paru already installed — nothing to do."
    exit 0
fi

log "No AUR helper found — installing paru..."
ensure_pkg_installed base-devel
ensure_pkg_installed git

tmpdir=$(sudo -u "$BUILD_USER" mktemp -d)
sudo -u "$BUILD_USER" git clone --quiet "https://aur.archlinux.org/paru.git" "$tmpdir"
(cd "$tmpdir" && sudo -u "$BUILD_USER" makepkg -si --noconfirm)
rm -rf "$tmpdir"

echo
log "Done. AUR helper: $(command -v paru)"
