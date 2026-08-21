#!/usr/bin/env bash
#
# tascam.sh — PERSONAL SCRIPT. Tascam US-16x08 mixer control app
# (tascam-gtk), needed to unmute the bus master and actually get audio
# out of the interface. Not part of any shared bundle — friends likely
# have different interfaces, so this stays personal even though it's
# still written to be distro-portable like the rest of lib/common.sh.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/config/versions.conf"

install_tascam_gtk() {
    log_info "Installing tascam-gtk for the US-16x08..."

    # Kernel driver support for the 16x08 is mainline as of recent
    # kernels — no separate driver package should be needed here, just
    # confirm the interface shows up once plugged in and tascam-gtk is
    # running.
    if aur_install "$TASCAM_GTK_AUR_PKG"; then
        log_ok "tascam-gtk installed from AUR."
        return 0
    fi

    log_warn "AUR package '$TASCAM_GTK_AUR_PKG' failed or unavailable."
    log_warn "Falling back to build from source (onkelDead/tascam-gtk on GitHub) —"
    log_warn "you've done this before on Fedora, same general process applies:"

    pkg_install --needed base-devel git gtk3 alsa-lib

    local build_dir
    build_dir="$(run_as_user mktemp -d)"
    run_as_user git clone https://github.com/onkelDead/tascam-gtk.git "$build_dir/tascam-gtk"

    log_info "Cloned to $build_dir/tascam-gtk — follow the project's own"
    log_info "build instructions from here (cmake/make steps have changed"
    log_info "before, so deferring to the repo's current README rather than"
    log_info "hardcoding a build command that might go stale)."
}

install_tascam_gtk
