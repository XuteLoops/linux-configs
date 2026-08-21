#!/usr/bin/env bash
#
# common.sh — shared helpers for the Arch version of linux-setup.
# Sourced by install.sh and by every module. Not meant to be run directly.

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

log_info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
log_ok()    { echo -e "\033[1;32m[OK]\033[0m    $*"; }
log_warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
log_error() { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; }

# ---------------------------------------------------------------------------
# Root / user handling
# ---------------------------------------------------------------------------

# Call at the top of any module that needs root for pacman itself.
require_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This step needs root. Re-run with sudo."
        exit 1
    fi
}

# The real (non-root) user, even when this script is run via sudo.
# AUR builds must run as this user — makepkg refuses to run as root.
target_user() {
    if [[ -n "${SUDO_USER:-}" ]]; then
        echo "$SUDO_USER"
    else
        echo "$USER"
    fi
}

run_as_user() {
    sudo -u "$(target_user)" "$@"
}

# ---------------------------------------------------------------------------
# Confirmation prompt
# ---------------------------------------------------------------------------

confirm() {
    local prompt="${1:-Continue?}"
    read -r -p "$prompt [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

# ---------------------------------------------------------------------------
# AUR helper detection / bootstrap
#
# Checks for yay or paru, in that order. Uses whichever is already present.
# If neither is present, installs paru (and only paru — deliberately does
# not install both if the system has neither, to avoid bloating a clean
# system with two competing helpers).
#
# Sets the global AUR_HELPER variable as a side effect, and every other
# function in this file that needs an AUR helper reads that variable rather
# than re-detecting, so detection only happens once per run.
# ---------------------------------------------------------------------------

AUR_HELPER=""

detect_aur_helper() {
    if [[ -n "$AUR_HELPER" ]]; then
        echo "$AUR_HELPER"
        return 0
    fi

    if command -v yay >/dev/null 2>&1; then
        AUR_HELPER="yay"
    elif command -v paru >/dev/null 2>&1; then
        AUR_HELPER="paru"
    fi

    echo "$AUR_HELPER"
}

ensure_aur_helper() {
    # NOTE: intentionally not using `found="$(detect_aur_helper)"` here.
    # Command substitution runs in a subshell, so detect_aur_helper's
    # assignment to the global AUR_HELPER would be lost the moment the
    # subshell exits — call it directly instead so the assignment
    # actually sticks in this shell.
    detect_aur_helper >/dev/null

    if [[ -n "$AUR_HELPER" ]]; then
        log_ok "AUR helper already present: $AUR_HELPER"
        return 0
    fi

    log_info "No AUR helper found. Installing paru..."

    local build_dir
    build_dir="$(run_as_user mktemp -d)"

    pkg_install --needed base-devel git

    run_as_user git clone https://aur.archlinux.org/paru.git "$build_dir/paru"
    (
        cd "$build_dir/paru" || exit 1
        run_as_user makepkg -si --noconfirm
    )

    rm -rf "$build_dir"

    if command -v paru >/dev/null 2>&1; then
        AUR_HELPER="paru"
        log_ok "paru installed successfully."
    else
        log_error "paru installation failed."
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Package install wrappers
#
# Modules should call these instead of pacman/yay/paru directly, so the
# underlying tool only needs to be decided once, here.
# ---------------------------------------------------------------------------

# Official repo packages. Runs as root.
pkg_install() {
    pacman -S --noconfirm --needed "$@"
}

pkg_installed() {
    pacman -Qi "$1" >/dev/null 2>&1
}

# AUR packages. Must run as the invoking user, not root.
aur_install() {
    ensure_aur_helper || return 1
    run_as_user "$AUR_HELPER" -S --noconfirm --needed "$@"
}

# ---------------------------------------------------------------------------
# Idempotent file deploy
#
# Only writes if content actually differs from what's already there, and
# backs up the existing file (timestamped) before overwriting — never a
# silent clobber.
#
# Usage: deploy_file <dest_path> <<'EOF'
# ...content...
# EOF
# ---------------------------------------------------------------------------

deploy_file() {
    local dest="$1"
    local new_content
    new_content="$(cat)"

    if [[ -f "$dest" ]]; then
        local existing
        existing="$(cat "$dest")"
        if [[ "$existing" == "$new_content" ]]; then
            log_ok "$dest already up to date, skipping."
            return 0
        fi
        local backup="${dest}.bak.$(date +%Y%m%d%H%M%S)"
        cp "$dest" "$backup"
        log_warn "Existing $dest differs, backed up to $backup"
    fi

    mkdir -p "$(dirname "$dest")"
    printf '%s\n' "$new_content" > "$dest"
    log_ok "Wrote $dest"
}