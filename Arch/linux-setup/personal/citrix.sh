#!/usr/bin/env bash
#
# citrix.sh — PERSONAL SCRIPT. Installs Citrix Workspace (icaclient) for
# work remote-desktop access. Not part of any shared bundle — run this
# directly and only on your own machine.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/config/versions.conf"

require_root

log_info "Syncing package databases and upgrading system..."
pacman -Syu --noconfirm
log_ok "System synced and up to date."

fix_libidn_if_needed() {
    # icaclient depends on libidn.so.11 (libidn v1), but modern Arch
    # ships a newer, incompatible libidn by default. Only apply the fix
    # if that specific old file is actually missing — don't apply it
    # blindly.
    if [[ -f /usr/lib/libidn.so.11 ]]; then
        log_ok "libidn.so.11 already present — no compatibility fix needed."
        return 0
    fi

    log_info "libidn.so.11 missing — installing libidn11 compatibility package..."
    aur_install libidn11
}

install_citrix() {
    log_info "Installing Citrix Workspace (icaclient)..."
    fix_libidn_if_needed

    if aur_install "$ICACLIENT_AUR_PKG"; then
        log_ok "icaclient installed."
        return 0
    fi

    # This is a well-known, structural limitation of this specific AUR
    # package (confirmed across multiple years of AUR comments) — not a
    # bug in this script. Citrix doesn't allow the PKGBUILD to fetch
    # their installer tarball automatically (no stable hotlink, sits
    # behind Citrix's own download page), so it always needs the
    # tarball placed manually before the build can finish.
    log_warn "icaclient build failed — this is expected on first attempt."
    log_warn "Citrix's tarball can't be auto-downloaded by the AUR package."
    log_warn "To finish this manually:"
    log_warn "  1. Go to https://www.citrix.com/downloads/workspace-app/"
    log_warn "     and download the Linux tarball (the exact filename/version"
    log_warn "     the build wants was shown in the error above, e.g."
    log_warn "     'icaclient-x64-<version>.tar.gz')."
    log_warn "  2. Place that file, WITH THAT EXACT FILENAME, into:"
    log_warn "       ~/.cache/paru/clone/$ICACLIENT_AUR_PKG/   (if using paru)"
    log_warn "       ~/.cache/yay/$ICACLIENT_AUR_PKG/          (if using yay)"
    log_warn "  3. Re-run this script."
    return 1
}

install_citrix