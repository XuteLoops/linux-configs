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
# Ensures a working AUR helper is available (yay preferred over paru —
# see 00-aur-helpers.sh for the full tiered bootstrap logic, carried
# inline here too so this module works standalone).
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

TARGET_HOME=$(getent passwd "$BUILD_USER" | cut -d: -f6)
if [ -z "$TARGET_HOME" ] || [ ! -d "$TARGET_HOME" ]; then
    echo "Could not resolve a home directory for user '$BUILD_USER'." >&2
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

_aur_helper_working() {
    local bin="$1"
    command -v "$bin" &>/dev/null && "$bin" --version &>/dev/null
}

_aur_helper_remove_if_installed() {
    local pkgname="$1"
    if pacman -Qi "$pkgname" &>/dev/null; then
        log "Removing non-functional $pkgname..."
        pacman -R --noconfirm "$pkgname" \
            || warn "Failed to remove $pkgname — may cause a conflict on the next install attempt."
    fi
}

_aur_helper_install_pkg() {
    local pkgname="$1"
    ensure_pkg_installed base-devel git

    local build_root="${TARGET_HOME}/.cache/pipeline-aur-build"
    sudo -u "$BUILD_USER" mkdir -p "$build_root"
    local build_dir
    build_dir=$(sudo -u "$BUILD_USER" mktemp -d "${build_root}/build.XXXXXX")

    if ! sudo -u "$BUILD_USER" git clone --quiet --depth=1 "https://aur.archlinux.org/${pkgname}.git" "$build_dir/${pkgname}"; then
        warn "Failed to clone $pkgname from AUR"
        rm -rf "$build_dir"
        return 1
    fi

    if ! (cd "$build_dir/${pkgname}" && sudo -u "$BUILD_USER" makepkg -si --noconfirm); then
        warn "Failed to build/install $pkgname"
        rm -rf "$build_dir"
        return 1
    fi

    rm -rf "$build_dir"
}

# yay preferred over paru throughout (paru has caused real problems in
# practice); prebuilt tried before source; "working" verified by
# actually running --version; builds happen under the user's home
# directory, not /tmp.
ensure_aur_helper() {
    if _aur_helper_working yay; then
        log "AUR helper already present and working: yay"
        return 0
    fi
    if _aur_helper_working paru; then
        log "AUR helper already present and working: paru"
        return 0
    fi

    log "Trying yay-bin (prebuilt, fast) first..."
    if _aur_helper_install_pkg "yay-bin" && _aur_helper_working yay; then
        log "Installed AUR helper: yay (prebuilt binary)"
        return 0
    fi
    warn "yay-bin unavailable or broken — trying paru-bin instead."
    _aur_helper_remove_if_installed "yay-bin"

    if _aur_helper_install_pkg "paru-bin" && _aur_helper_working paru; then
        log "Installed AUR helper: paru (prebuilt binary)"
        return 0
    fi
    warn "paru-bin also unavailable or broken — building yay from source."
    _aur_helper_remove_if_installed "paru-bin"

    if _aur_helper_install_pkg "yay" && _aur_helper_working yay; then
        log "Installed AUR helper: yay (built from source)"
        return 0
    fi
    warn "Building yay from source also failed — falling back to paru from source."

    if ! _aur_helper_install_pkg "paru"; then
        echo "All AUR helper install options exhausted — cannot proceed." >&2
        exit 1
    fi
    if ! _aur_helper_working paru; then
        echo "paru was built from source but still fails to run — check the build output above." >&2
        exit 1
    fi
    log "Installed AUR helper: paru (built from source, last resort)"
}

# Installs all given AUR packages in a single transaction (rather than one
# pacman/paru invocation per package) — this matters: each separate
# transaction runs the full pacman hook chain (snapper snapshots,
# verify-transaction.sh's full local-db scan, etc.), and firing many of
# these back-to-back in rapid succession was found to cause real problems
# (pacback's own <300s-since-last-snapshot safety abort firing, and
# plausibly transient bad reads of /var/lib/pacman/local by
# verify-transaction.sh's installcheck racing an adjacent transaction's
# writes — producing spurious "nothing provides" errors on rock-solid
# packages like glibc, without any real corruption existing at rest).
# One batched transaction avoids this entirely.
aur_install() {
    local to_install=()
    local pkg
    for pkg in "$@"; do
        if pacman -Qi "$pkg" &>/dev/null; then
            log "Already installed (AUR): $pkg"
        else
            to_install+=("$pkg")
        fi
    done
    if [ "${#to_install[@]}" -gt 0 ]; then
        log "Installing (AUR): ${to_install[*]}"
        local helper
        helper=$(command -v yay || command -v paru)
        sudo -u "$BUILD_USER" "$helper" -S --needed --noconfirm "${to_install[@]}"
    fi
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
aur_install "${AUR_PKGS[@]}"

echo
log "Done."