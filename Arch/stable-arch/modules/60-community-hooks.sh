#!/bin/bash
#
# 60-community-hooks.sh
#
# Standalone module: installs a bundle of small, independent AUR hook
# packages that each ship their own pacman hook automatically — no
# custom hook content deployed by this module, just the installs.
#
#   linux-preserve-modules       - preserves out-of-tree kernel modules
#                                   across kernel upgrades
#   pacman-hook-reload-modules   - reloads affected kernel modules after
#                                   relevant package upgrades
#   longoverdue                  - notifies about running daemons still
#                                   referencing deleted shared library
#                                   handles
#   sync-pacman-hook-git         - syncs / and /boot after transactions
#   systemd-cleanup-pacman-hook  - cleans up orphaned systemd units
#   systemd-removed-services-hook - flags services removed by a package
#                                   but still referenced
#
# NOTE: reflector-pacman-hook-git is deliberately NOT included.
# reflector/mirrorlist management is handled by a separate,
# out-of-scope script that installs reflector directly and enables its
# service — removing this AUR package dependency and its own moving
# parts from this pipeline.
#
# NOTE: pacman-hook-systemd-restart-git is deliberately NOT included.
# It restarts every service whose underlying binary/library changed
# after an upgrade — including systemd-logind.service, since its binary
# is part of the systemd package itself. Restarting logind live kills
# every active login session it's tracking, which on a desktop system
# means an unannounced logout mid-transaction. The reboot-required
# module (40-reboot-required.sh) is the safer alternative for exactly
# this class of change.
#
# If neither yay nor paru is already installed, bootstraps paru
# automatically so this module works standalone.
#
# Safe to re-run.
#
# Usage:
#   sudo ./60-community-hooks.sh
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

ensure_aur_helper() {
    if command -v paru &>/dev/null || command -v yay &>/dev/null; then
        return
    fi
    log "No AUR helper found — bootstrapping paru..."
    ensure_pkg_installed base-devel
    ensure_pkg_installed git
    local tmpdir
    tmpdir=$(sudo -u "$BUILD_USER" mktemp -d)
    sudo -u "$BUILD_USER" git clone --quiet "https://aur.archlinux.org/paru.git" "$tmpdir"
    (cd "$tmpdir" && sudo -u "$BUILD_USER" makepkg -si --noconfirm)
    rm -rf "$tmpdir"
}

aur_install() {
    local pkg="$1"
    if pacman -Qi "$pkg" &>/dev/null; then
        log "Already installed (AUR): $pkg"
        return
    fi
    log "Installing (AUR): $pkg"
    local helper
    helper=$(command -v paru || command -v yay)
    sudo -u "$BUILD_USER" "$helper" -S --needed --noconfirm "$pkg"
}

log "Ensuring an AUR helper is available..."
ensure_aur_helper

AUR_PKGS=(
    linux-preserve-modules
    pacman-hook-reload-modules
    longoverdue
    sync-pacman-hook-git
    systemd-cleanup-pacman-hook
    systemd-removed-services-hook
)

log "Installing community AUR hook packages..."
for pkg in "${AUR_PKGS[@]}"; do
    aur_install "$pkg"
done

echo
log "Done."