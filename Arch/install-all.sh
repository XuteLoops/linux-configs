#!/bin/bash
#
# install-all.sh
#
# Convenience wrapper: fetches and runs every module in order, for
# anyone who wants the whole pipeline rather than picking individual
# modules. Each module is fully standalone and safe to re-run on its
# own — this script doesn't add any logic of its own beyond sequencing.
#
# If you only want specific pieces, skip this and run individual module
# scripts from modules/ instead — see the README for what each does.
#
# Usage:
#   sudo ./install-all.sh              # run all modules, fetching each from GitHub
#   sudo ./install-all.sh --local      # run all modules from ./modules/ instead
#                                       # (use this if you've cloned the repo)
#
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root (e.g. sudo $0)" >&2
    exit 1
fi

BASE_URL="https://raw.githubusercontent.com/XuteLoops/linux-configs/main/Arch/modules"

MODULES=(
    00-aur-helpers.sh
    10-systemd-inhibit.sh
    20-verify-transaction.sh
    30-arch-audit.sh
    40-reboot-required.sh
    50-paccache.sh
    60-community-hooks.sh
)

LOCAL_MODE=0
for arg in "$@"; do
    case "$arg" in
        --local) LOCAL_MODE=1 ;;
        *)
            echo "Unknown argument: $arg" >&2
            exit 1
            ;;
    esac
done

for module in "${MODULES[@]}"; do
    echo
    echo "############################################################"
    echo "# Running $module"
    echo "############################################################"

    if [ "$LOCAL_MODE" -eq 1 ]; then
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        bash "$script_dir/modules/$module"
    else
        tmpfile=$(mktemp)
        curl -fsSL "$BASE_URL/$module" -o "$tmpfile"
        bash "$tmpfile"
        rm -f "$tmpfile"
    fi
done

echo
echo "############################################################"
echo "# All modules complete."
echo "############################################################"
