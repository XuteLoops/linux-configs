#!/usr/bin/env bash
#
# 02-launchers.sh — non-Steam game launchers.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

install_runelite() {
    log_info "Installing RuneLite (Old School RuneScape client)..."

    if aur_install runelite; then
        log_ok "RuneLite installed."
    else
        log_warn "runelite AUR install failed — check AUR page for updates."
    fi
}

install_minecraft_launcher() {
    log_info "Installing Minecraft launcher..."

    if aur_install minecraft-launcher; then
        log_ok "Minecraft launcher installed."
    else
        log_warn "minecraft-launcher AUR install failed — check AUR page for updates."
    fi
}

install_runelite
install_minecraft_launcher

log_info "Fortnite has no Linux path (kernel-level anti-cheat) — dual boot"
log_info "remains the only option for that one specifically."