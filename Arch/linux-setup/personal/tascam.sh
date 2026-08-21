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

require_root

log_info "Syncing package databases and upgrading system..."
pacman -Syu --noconfirm
log_ok "System synced and up to date."

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
    log_info "Falling back to build from source (onkelDead/tascam-gtk on GitHub)..."

    # Confirmed build deps from the project's own README (autotools-based).
    pkg_install --needed base-devel autoconf automake autopoint git \
        gtkmm3 libxml++5.0

    local build_dir
    build_dir="$(run_as_user mktemp -d)"
    run_as_user git clone https://github.com/onkelDead/tascam-gtk.git "$build_dir/tascam-gtk"

    # Build as the invoking user (standard practice, same reasoning as
    # AUR builds — no need for root until the final install step).
    (
        cd "$build_dir/tascam-gtk" || exit 1
        run_as_user autoreconf -fiv
        run_as_user ./configure
        run_as_user make
    )

    # make install itself needs root (writes to /usr/local by default),
    # per the project's own README.
    (
        cd "$build_dir/tascam-gtk" || exit 1
        make install
    )

    # Refresh desktop/icon caches so the .desktop file this installs
    # (per the project's data/ directory and GSettings schema) actually
    # shows up in the application menu without needing a logout.
    command -v update-desktop-database >/dev/null 2>&1 \
        && update-desktop-database /usr/local/share/applications 2>/dev/null
    command -v gtk-update-icon-cache >/dev/null 2>&1 \
        && gtk-update-icon-cache /usr/local/share/icons/hicolor 2>/dev/null

    if command -v tascamgtk >/dev/null 2>&1; then
        log_ok "tascam-gtk built and installed — found at $(command -v tascamgtk)"
    else
        log_warn "Build completed but the 'tascamgtk' binary wasn't found on PATH."
        log_warn "Check $build_dir/tascam-gtk for build errors, or the actual"
        log_warn "binary name may differ — check the project's Makefile.am."
        return 1
    fi
}

install_tascam_gtk