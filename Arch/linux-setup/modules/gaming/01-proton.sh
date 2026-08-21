#!/usr/bin/env bash
#
# 01-proton.sh — Steam + Proton version management.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

install_steam() {
    log_info "Installing Steam..."

    # multilib repo is required for Steam on Arch — check it's enabled
    # rather than silently failing later.
    if ! grep -q "^\[multilib\]" /etc/pacman.conf; then
        log_warn "[multilib] repo not enabled in /etc/pacman.conf."
        log_warn "Steam needs it. Enable it manually, then re-run this module:"
        log_warn "  sudo sed -i \"/\\[multilib\\]/,/Include/\"'s/^#//' /etc/pacman.conf"
        log_warn "  sudo pacman -Syu"
        return 1
    fi

    pkg_install steam
    log_ok "Steam installed."
}

install_protonup_qt() {
    log_info "Installing ProtonUp-QT (confirmed to support GE-Proton and"
    log_info "proton-cachyos as direct sources — no workaround needed)..."

    if aur_install protonup-qt; then
        log_ok "ProtonUp-QT installed."
    else
        log_warn "ProtonUp-QT AUR install failed — check AUR page for updates."
    fi
}

install_cachyos_proton_repo() {
    log_info "proton-cachyos is also available directly via CachyOS's own repo"
    log_info "if you'd rather manage it through pacman than ProtonUp-QT."
    log_info "Not enabled automatically — pick ONE source (ProtonUp-QT or"
    log_info "pacman) and stick with it, since versions between the two can"
    log_info "drift out of sync by a day or so."
    log_info "See: https://wiki.cachyos.org for repo setup if you want this route."
}

install_steam
install_protonup_qt
install_cachyos_proton_repo
