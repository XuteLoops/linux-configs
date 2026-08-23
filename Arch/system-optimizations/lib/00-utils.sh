#!/usr/bin/env bash
# 00-utils.sh — shared helpers sourced by every module.
# Not meant to be run directly.

# ---- logging -----------------------------------------------------------
LOG_FILE="${LOG_FILE:-/var/log/system-optimizations.log}"

_ts() { date '+%Y-%m-%d %H:%M:%S'; }

log_info()    { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*" | tee -a "$LOG_FILE" ; }
log_warn()    { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*" | tee -a "$LOG_FILE" >&2 ; }
log_error()   { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" | tee -a "$LOG_FILE" >&2 ; }
log_success() { printf '\033[1;32m[ OK ]\033[0m  %s\n' "$*" | tee -a "$LOG_FILE" ; }
log_skip()    { printf '\033[1;90m[SKIP]\033[0m  %s\n' "$*" | tee -a "$LOG_FILE" ; }

die() { log_error "$*"; exit 1; }

# ---- environment / preconditions ---------------------------------------
require_root() {
    [[ $EUID -eq 0 ]] || die "This script must be run as root (use sudo)."
}

# The user who invoked sudo, so we're not configuring things for root's
# home directory by mistake. Falls back to $USER if not run via sudo.
target_user() {
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        printf '%s' "$SUDO_USER"
    else
        printf '%s' "${USER:-$(whoami)}"
    fi
}

target_home() {
    getent passwd "$(target_user)" | cut -d: -f6
}

# ---- package management -------------------------------------------------
is_pkg_installed() {
    pacman -Qq "$1" &>/dev/null
}

pkg_install() {
    # Installs any number of official-repo packages, skipping ones already present.
    local pkgs=() p
    for p in "$@"; do
        if is_pkg_installed "$p"; then
            log_skip "$p already installed"
        else
            pkgs+=("$p")
        fi
    done
    if ((${#pkgs[@]})); then
        log_info "Installing: ${pkgs[*]}"
        pacman -S --needed --noconfirm "${pkgs[@]}" \
            || die "Failed to install: ${pkgs[*]}"
        log_success "Installed: ${pkgs[*]}"
    fi
}

# Requires an AUR helper to already be set up (see 01-aur-helper.sh).
aur_install() {
    local pkgs=() p
    for p in "$@"; do
        if is_pkg_installed "$p"; then
            log_skip "$p already installed"
        else
            pkgs+=("$p")
        fi
    done
    if ((${#pkgs[@]})); then
        [[ -n "${AUR_HELPER:-}" ]] || die "No AUR helper configured; run 01-aur-helper.sh first."
        log_info "Installing (AUR): ${pkgs[*]}"
        sudo -u "$(target_user)" "$AUR_HELPER" -S --needed --noconfirm "${pkgs[@]}" \
            || die "Failed to install (AUR): ${pkgs[*]}"
        log_success "Installed (AUR): ${pkgs[*]}"
    fi
}

# Best-effort AUR install for genuinely OPTIONAL packages: logs a warning
# and returns non-zero on failure instead of calling die()/exit like
# aur_install() does. Use this whenever failure should be skipped
# gracefully rather than ending the whole script — e.g. ALHP's keyring
# packages, where the rest of the run should continue fine without them.
# (A plain `|| true` around aur_install()/pkg_install() does NOT achieve
# this: those call die() -> exit on failure, and no enclosing `||` can
# catch a process that has already exited.)
aur_install_optional() {
    local pkgs=() p
    for p in "$@"; do
        if is_pkg_installed "$p"; then
            log_skip "$p already installed"
        else
            pkgs+=("$p")
        fi
    done
    if ((${#pkgs[@]})); then
        if [[ -z "${AUR_HELPER:-}" ]]; then
            log_warn "No AUR helper configured — skipping optional install: ${pkgs[*]}"
            return 1
        fi
        log_info "Installing (AUR, optional): ${pkgs[*]}"
        if sudo -u "$(target_user)" "$AUR_HELPER" -S --needed --noconfirm "${pkgs[@]}"; then
            log_success "Installed (AUR): ${pkgs[*]}"
        else
            log_warn "Failed to install (optional): ${pkgs[*]} — continuing without it."
            return 1
        fi
    fi
}

enable_service() {
    local svc="$1"
    systemctl enable --now "$svc" \
        && log_success "Enabled + started $svc" \
        || log_warn "Could not enable/start $svc — check manually"
}

# ---- idempotent file editing --------------------------------------------
backup_file() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    local bak="${f}.system-optimizations.bak"
    [[ -f "$bak" ]] || cp -a "$f" "$bak"
}

# Appends a line to a file only if an identical line isn't already present.
append_once() {
    local line="$1" file="$2"
    grep -qxF "$line" "$file" 2>/dev/null && return 0
    backup_file "$file"
    printf '%s\n' "$line" >> "$file"
}

# Replaces a `key=value` style line in a config file, or appends it if the
# key doesn't exist yet. Only matches uncommented keys.
set_kv() {
    local key="$1" value="$2" file="$3" sep="${4:-=}"
    backup_file "$file"
    if grep -qE "^${key}${sep}" "$file" 2>/dev/null; then
        sed -i "s|^${key}${sep}.*|${key}${sep}${value}|" "$file"
    else
        printf '%s%s%s\n' "$key" "$sep" "$value" >> "$file"
    fi
}

# Uncomments a line matching a pattern (e.g. "#ParallelDownloads" -> "ParallelDownloads")
uncomment_line() {
    local pattern="$1" file="$2"
    backup_file "$file"
    sed -i "s|^#\(${pattern}.*\)|\1|" "$file"
}