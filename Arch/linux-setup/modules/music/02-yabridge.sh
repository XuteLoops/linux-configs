#!/usr/bin/env bash
#
# 02-yabridge.sh — installs yabridge and the Bottles wineloader bridge.
#
# The critical piece here: yabridge by default targets the system Wine
# prefix, completely ignoring whichever Wine runner/prefix Bottles is
# actually using. Without the loader script below, plugins can appear
# "installed" but never actually run through the right Wine — this is
# the most likely explanation for prior failed setup attempts.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/config/versions.conf"

install_yabridge() {
    log_info "Installing yabridge..."

    if aur_install yabridge yabridgectl; then
        log_ok "yabridge + yabridgectl installed."
    else
        log_warn "yabridge AUR install failed — check AUR page for updates."
        return 1
    fi
}

install_bottles_wineloader() {
    log_info "Setting up yabridge-bottles-wineloader..."

    pkg_install --needed yq

    local target
    target="$(target_user)"
    local repo_dir="/home/$target/.local/share/yabridge-bottles-wineloader"

    run_as_user git clone "$YABRIDGE_BOTTLES_LOADER_REPO" "$repo_dir" \
        || log_warn "Repo already cloned or clone failed — check $repo_dir"

    local env_dir="/home/$target/.config/environment.d"
    local bin_dir="/home/$target/.local/bin"

    run_as_user mkdir -p "$env_dir" "$bin_dir"

    if [[ -f "$repo_dir/wineloader.conf" ]]; then
        run_as_user cp "$repo_dir/wineloader.conf" "$env_dir/wineloader.conf"
    fi
    if [[ -f "$repo_dir/wineloader.sh" ]]; then
        run_as_user cp "$repo_dir/wineloader.sh" "$bin_dir/wineloader.sh"
        run_as_user chmod +x "$bin_dir/wineloader.sh"
    fi

    log_ok "wineloader files placed under ~/.config/environment.d and ~/.local/bin."
    log_warn "A REBOOT is required for the environment.d variable to take effect."
    log_info "Remaining manual steps:"
    log_info "  1. In Bottles, install a compatible Wine runner (repo recommends"
    log_info "     a specific kron4ek build — check $YABRIDGE_BOTTLES_LOADER_REPO"
    log_info "     for the currently recommended one, this moves)."
    log_info "  2. Point yabridgectl at the bottle's VST3 folder:"
    log_info "     yabridgectl add <path-to-bottle>/drive_c/.../VST3"
    log_info "  3. yabridgectl sync"
}

install_yabridge
install_bottles_wineloader
