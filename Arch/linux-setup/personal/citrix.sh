#!/usr/bin/env bash
#
# citrix.sh — PERSONAL SCRIPT. Installs Citrix Workspace (icaclient) for
# work remote-desktop access. Not part of any shared bundle — run this
# directly and only on your own machine.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/config/versions.conf"

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
    aur_install "$ICACLIENT_AUR_PKG"
    log_ok "icaclient installed."
}

install_citrix
