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

    # NOTE: the wineloader needs to be told WHICH bottle to target.
    # wineloader.conf is the file that holds this, but the repo's own
    # docs/comments are the authority on the exact variable name/format —
    # that's not something to guess at and hardcode here, since getting it
    # wrong would silently point yabridge at the wrong (or no) bottle. Open
    # $env_dir/wineloader.conf and set it to '$MUSIC_BOTTLE_NAME'.
    log_warn "IMPORTANT — not yet done automatically: open"
    log_warn "  $env_dir/wineloader.conf"
    log_warn "and set the bottle-name variable to: $MUSIC_BOTTLE_NAME"
    log_warn "(check the repo's README/comments for the exact variable —"
    log_warn "getting this wrong silently breaks the bridge, so it's not"
    log_warn "guessed at here.)"
}

register_vst3_path() {
    log_info "Registering '$MUSIC_BOTTLE_NAME' bottle's VST3 folder with yabridgectl..."

    local prefix
    prefix="$(find_bottle_prefix "$MUSIC_BOTTLE_NAME")"

    if [[ -z "$prefix" ]]; then
        log_warn "Could not locate '$MUSIC_BOTTLE_NAME' bottle's prefix — add"
        log_warn "the VST3 path manually once plugins are installed:"
        log_warn "  yabridgectl add <path-to-bottle>/drive_c/Program\\ Files/Common\\ Files/VST3"
        log_warn "  yabridgectl sync"
        return 1
    fi

    local vst3_dir="$prefix/drive_c/Program Files/Common Files/VST3"

    # This is the standard Windows VST3 location; it may not exist yet if
    # no plugins are installed in the bottle. yabridgectl add itself will
    # create/track it either way, and re-running sync later (after
    # installing plugins) is safe and expected.
    run_as_user mkdir -p "$vst3_dir"
    run_as_user yabridgectl add "$vst3_dir" \
        && log_ok "Registered $vst3_dir with yabridgectl." \
        || log_warn "yabridgectl add failed — check the path above manually."

    run_as_user yabridgectl sync \
        && log_ok "yabridgectl sync completed." \
        || log_warn "yabridgectl sync failed — re-run after installing plugins."

    log_info "Re-run 'yabridgectl sync' any time after installing new plugins"
    log_info "into the '$MUSIC_BOTTLE_NAME' bottle."
}

install_yabridge
install_bottles_wineloader
register_vst3_path