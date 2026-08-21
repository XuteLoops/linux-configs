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

# sudo resets the environment by default (env_reset in sudoers, the
# default on virtually every distro including Arch) — so
# `VAR=val run_as_user cmd` does NOT reliably pass VAR through to cmd as
# run by the target user. This does, via `env`, regardless of sudoers
# env_reset settings.
#
# Usage: run_as_user_env VAR1=val1 VAR2=val2 -- command args...
run_as_user_env() {
    local envs=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do
        envs+=("$1")
        shift
    done
    shift || true  # drop the --
    sudo -u "$(target_user)" env "${envs[@]}" "$@"
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
# Bottles CLI helpers (flatpak com.usebottles.bottles)
#
# Syntax confirmed against Bottles' own CLI docs (docs.usebottles.com/
# advanced/cli). Runs as the invoking user via run_as_user, same as AUR
# builds — Bottles is a per-user Flatpak install, not root.
# ---------------------------------------------------------------------------

bottles_cli() {
    run_as_user flatpak run --command=bottles-cli com.usebottles.bottles "$@"
}

# Checks the CLI's own JSON listing for an exact-name match, rather than
# guessing at on-disk folder naming.
bottle_exists() {
    local name="$1"
    bottles_cli --json list bottles 2>/dev/null | grep -q "\"$name\""
}

# Root directory holding all bottles (NOT a specific bottle's prefix).
bottles_root_path() {
    bottles_cli info bottles-path 2>/dev/null | tail -n1
}

# Locates a bottle's actual on-disk WINEPREFIX directory by display name.
# Bottles' CLI docs don't document an exact folder-naming/sanitization rule
# for display name -> directory name (e.g. whether spaces become
# underscores), so rather than assuming a transform, this searches the
# reported bottles root for a loosely-matching directory name. Returns
# empty and a non-zero exit if nothing matches.
find_bottle_prefix() {
    local name="$1"
    local root
    root="$(bottles_root_path)"
    [[ -z "$root" ]] && return 1
    find "$root" -maxdepth 1 -type d -iname "*${name// /*}*" 2>/dev/null | head -n1
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