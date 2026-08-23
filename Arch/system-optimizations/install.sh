#!/usr/bin/env bash
# install.sh — modular fresh-Arch-install customization script.
#
# Usage:
#   sudo ./install.sh                 # run everything
#   sudo ./install.sh --list          # list available module tasks
#   sudo ./install.sh --only kernel,gpu,swap   # run specific tasks only
#   sudo ./install.sh --skip security,swap     # run everything except these
#
# Each module file in lib/ is sourced; task names below map to the
# functions they call. Add/remove entries in TASKS to customize what a
# full run does.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/var/log/system-optimizations.log"

# ---- source all modules (order matters: utils/detect/bootloader/aur first) ----
for f in "$SCRIPT_DIR"/lib/*.sh; do
    # shellcheck source=/dev/null
    source "$f"
done

# ---- task registry: name -> function(s) --------------------------------
declare -A TASKS=(
    [aur-helper]="setup_aur_helper"
    [reflector]="setup_reflector"
    [compiler-flags]="configure_makepkg_flags install_linux_headers set_pacman_architecture setup_alhp_repo"
    [kernel]="setup_limine_autoupdate install_kernel ensure_limine_kernel_entries set_preempt_full setup_scx_scheduler check_libahci_sss_quirk"
    [security]="install_apparmor configure_login_delay"
    [audio]="setup_rtkit add_user_to_audio_group configure_pipewire_latency"
    [pacman-config]="configure_pacman_conf install_pacman_contrib setup_paccache_hook install_arch_manwarn_and_update setup_pacman_db_backup setup_installed_pkg_list_snapshot"
    [gpu]="setup_gpu_drivers"
    [swap]="setup_hibernate_swapfile"
    [utilities]="setup_preload install_linux_firmware setup_cronie install_fwupd install_fonts"
    [misc]="replace_vim_with_neovim"
)

# Order to run tasks in a full run (aur-helper must precede anything using
# aur_install; reflector runs early so subsequent installs benefit from
# faster mirrors)
TASK_ORDER=(aur-helper reflector compiler-flags kernel security audio pacman-config gpu swap utilities misc)

# ---- arg parsing (handled BEFORE root check / hardware detection, so
# --list and --help work without sudo and without touching the system) ----
ONLY=()
SKIP=()

usage() {
    cat <<EOF
Usage: sudo $0 [--list] [--only task1,task2] [--skip task1,task2]

Available tasks: ${TASK_ORDER[*]}
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --list)
            printf 'Available tasks:\n'
            printf '  %s\n' "${TASK_ORDER[@]}"
            exit 0
            ;;
        --only)
            IFS=',' read -ra ONLY <<< "$2"
            shift 2
            ;;
        --skip)
            IFS=',' read -ra SKIP <<< "$2"
            shift 2
            ;;
        -h|--help)
            usage; exit 0
            ;;
        *)
            log_error "Unknown argument: $1"
            usage; exit 1
            ;;
    esac
done

require_root
run_detection   # populates CPU_VENDOR, MARCH_LEVEL, GPU_VENDORS, BOOTLOADER, ROOT_FS, INITRAMFS_STYLE

_in_array() {
    local needle="$1"; shift
    local x
    for x in "$@"; do [[ "$x" == "$needle" ]] && return 0; done
    return 1
}

# ---- run ------------------------------------------------------------------
log_info "=== system-optimizations starting ==="

for task in "${TASK_ORDER[@]}"; do
    if ((${#ONLY[@]})) && ! _in_array "$task" "${ONLY[@]}"; then
        continue
    fi
    if ((${#SKIP[@]})) && _in_array "$task" "${SKIP[@]}"; then
        log_skip "Skipping task: $task"
        continue
    fi

    log_info "--- Task: $task ---"
    for fn in ${TASKS[$task]}; do
        if declare -F "$fn" &>/dev/null; then
            "$fn" || log_error "Task '$task' step '$fn' failed — continuing with remaining tasks."
        else
            log_error "Function $fn not found for task $task"
        fi
    done
done

log_info "=== system-optimizations complete. Log: $LOG_FILE ==="
log_info "Reboot recommended to fully apply kernel/bootloader/group-membership changes."