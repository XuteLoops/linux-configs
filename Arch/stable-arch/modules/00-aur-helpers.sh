#!/bin/bash
#
# 00-aur-helpers.sh
#
# Standalone module: ensures a WORKING AUR helper is available. Tries,
# in order:
#   1. yay already installed and working -> use it.
#   2. paru already installed and working -> use it.
#   3. yay-bin (prebuilt).
#   4. paru-bin (prebuilt).
#   5. yay from source (Go — much lighter peak memory during linking
#      than paru's large Rust dependency tree; a source build of paru
#      has been observed getting OOM-killed mid-link on
#      memory-constrained machines).
#   6. paru from source (final resort).
#
# yay is preferred over paru throughout — paru has caused real problems
# in practice (see above). "Working" is checked by actually running the
# binary (--version), not just checking it's installed — a
# present-but-broken binary (e.g. linked against a libalpm version
# that's since changed after a pacman upgrade) would otherwise go
# undetected until the first real AUR install fails deep into a later
# step.
#
# Builds happen under the invoking user's home directory
# (~/.cache/pipeline-aur-build), not /tmp via plain mktemp — /tmp is
# commonly a size-capped tmpfs, and a source build has been observed
# failing with "Disk quota exceeded" partway through compiling large
# dependencies when /tmp filled up. Building on the real disk avoids
# that.
#
# Not a hard prerequisite for the other modules — they each carry this
# same logic inline — but running this first means later modules will
# find a working helper already there instead of bootstrapping one
# themselves.
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

# Clones and installs the given AUR helper candidate package
# (yay-bin/paru-bin/yay/paru). Returns non-zero on failure so the
# caller can fall back rather than aborting outright.
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

if _aur_helper_working yay; then
    log "AUR helper already present and working: yay"
    exit 0
fi
if _aur_helper_working paru; then
    log "AUR helper already present and working: paru"
    exit 0
fi

log "Trying yay-bin (prebuilt, fast) first..."
if _aur_helper_install_pkg "yay-bin" && _aur_helper_working yay; then
    log "Installed AUR helper: yay (prebuilt binary)"
    exit 0
fi
warn "yay-bin unavailable or broken — trying paru-bin instead."
_aur_helper_remove_if_installed "yay-bin"

if _aur_helper_install_pkg "paru-bin" && _aur_helper_working paru; then
    log "Installed AUR helper: paru (prebuilt binary)"
    exit 0
fi
warn "paru-bin also unavailable or broken — building yay from source (Go, lighter on memory during linking than paru's Rust dependency tree)."
_aur_helper_remove_if_installed "paru-bin"

if _aur_helper_install_pkg "yay" && _aur_helper_working yay; then
    log "Installed AUR helper: yay (built from source)"
    exit 0
fi
warn "Building yay from source also failed — falling back to building paru from source as a final resort."

if ! _aur_helper_install_pkg "paru"; then
    echo "All AUR helper install options exhausted (yay-bin, paru-bin, yay from source, paru from source) — cannot proceed. Check the build output above." >&2
    exit 1
fi

if ! _aur_helper_working paru; then
    echo "paru was built from source but still fails to run — check the build output above manually." >&2
    exit 1
fi
log "Installed AUR helper: paru (built from source, last resort)"