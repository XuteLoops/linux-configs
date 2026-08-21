#!/usr/bin/env bash
#
# install.sh — entry point for the Arch (and Arch-based, e.g. CachyOS)
# version of linux-setup.
#
# This script only runs the SHARED bundles under modules/. Anything
# under personal/ is intentionally never touched by this script — those
# are run directly and separately, by hand.
#
# Usage:
#   ./install.sh --core --music --gaming --social   # pick what you want
#   ./install.sh --all                                # everything shared
#
# Bundles:
#   --core     PIN login, drive automount
#   --music    DAWs (Bitwig/Reaper native, Bottles foundation for
#              Ableton/FL Studio), yabridge + Bottles wineloader
#   --gaming   Steam, Proton/ProtonUp-QT, RuneLite, Minecraft launcher
#   --social   Vesktop (Discord)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

RUN_CORE=0
RUN_MUSIC=0
RUN_GAMING=0
RUN_SOCIAL=0

if [[ $# -eq 0 ]]; then
    log_error "No bundles specified."
    echo "Usage: $0 [--core] [--music] [--gaming] [--social] [--all]"
    exit 1
fi

for arg in "$@"; do
    case "$arg" in
        --core)    RUN_CORE=1 ;;
        --music)   RUN_MUSIC=1 ;;
        --gaming)  RUN_GAMING=1 ;;
        --social)  RUN_SOCIAL=1 ;;
        --all)     RUN_CORE=1; RUN_MUSIC=1; RUN_GAMING=1; RUN_SOCIAL=1 ;;
        *)
            log_error "Unknown option: $arg"
            echo "Usage: $0 [--core] [--music] [--gaming] [--social] [--all]"
            exit 1
            ;;
    esac
done

require_root

log_info "Syncing package databases and upgrading system (this may take a while"
log_info "on a system that hasn't been updated recently)..."
pacman -Syu --noconfirm
log_ok "System synced and up to date."

run_module() {
    local path="$1"
    log_info "── Running $(basename "$path") ──"
    bash "$path"
}

if [[ $RUN_CORE -eq 1 ]]; then
    for m in "$SCRIPT_DIR"/modules/core/*.sh; do run_module "$m"; done
fi

if [[ $RUN_MUSIC -eq 1 ]]; then
    for m in "$SCRIPT_DIR"/modules/music/*.sh; do run_module "$m"; done
fi

if [[ $RUN_GAMING -eq 1 ]]; then
    for m in "$SCRIPT_DIR"/modules/gaming/*.sh; do run_module "$m"; done
fi

if [[ $RUN_SOCIAL -eq 1 ]]; then
    for m in "$SCRIPT_DIR"/modules/social/*.sh; do run_module "$m"; done
fi

log_ok "Done. Check any [WARN] lines above for manual follow-up steps."