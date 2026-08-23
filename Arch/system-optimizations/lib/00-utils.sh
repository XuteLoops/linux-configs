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

# NOTE: a generic set_kv() (single-line key=value replace-or-append) used
# to live here and has been deliberately removed. Its append-on-missing
# fallback appended to the literal end of the file, which is unsafe for
# any config with sections (pacman.conf, makepkg.conf) — a value could
# land under the wrong section header, or after a multi-line value's
# continuation lines, corrupting the file. This caused two real bugs in
# this project. Use set_shell_assignment() for flat shell-style files
# (makepkg.conf) or set_pacman_option() for pacman.conf's [options]
# section. For any NEW config-editing helper: always locate the correct
# structural insertion point (section header, anchor line) rather than
# appending to end-of-file — never assume a flat, unsectioned file.

# Sets a shell-style `KEY="value"` assignment in a config file that is
# itself valid shell (e.g. makepkg.conf), correctly handling an existing
# assignment that spans MULTIPLE lines via trailing backslash
# continuation — which is exactly how stock Arch's /etc/makepkg.conf
# ships CFLAGS by default. Removes the entire old assignment (all its
# continuation lines) before appending the new single-line replacement,
# rather than leaving orphaned fragments behind.
set_shell_assignment() {
    local key="$1" value="$2" file="$3"
    backup_file "$file"

    local tmpfile
    tmpfile=$(mktemp)

    awk -v key="$key" '
        BEGIN { skip = 0 }
        {
            if (skip) {
                if ($0 ~ /\\[[:space:]]*$/) { next }
                skip = 0
                next
            }
            if ($0 ~ "^" key "=") {
                if ($0 ~ /\\[[:space:]]*$/) { skip = 1; next }
                next
            }
            print
        }
    ' "$file" > "$tmpfile"

    printf '%s="%s"\n' "$key" "$value" >> "$tmpfile"
    mv "$tmpfile" "$file"
}

# Sets a `Key = value` directive specifically WITHIN pacman.conf's
# [options] section — never appends to the end of the file. Required for
# any [options]-only directive (ParallelDownloads, CompressXZ,
# CompressZst, DownloadUser, etc.) because pacman.conf directives apply
# to whatever section header they textually fall under. An earlier
# version of this script appended missing directives with plain `>>`,
# which landed them after whatever the LAST section in the file happened
# to be (commonly [multilib]) — pacman then read them as invalid
# directives for that repo instead of global options, producing "not
# recognized" warnings. This bit us for real; see the git history around
# configure_pacman_conf() in 08-pacman-config.sh.
#
# If the key already exists anywhere in the file, updates it in place
# (handles both "already correctly under [options]" and "was previously
# misplaced by the old buggy behavior" — either way the value gets
# fixed, though a misplaced line won't be relocated on its own; run this
# against a clean/restored pacman.conf if one was already corrupted).
set_pacman_option() {
    local key="$1" value="$2" conf="${3:-/etc/pacman.conf}"
    backup_file "$conf"

    if grep -qE "^${key}[[:space:]]*=" "$conf"; then
        sed -i "s|^${key}[[:space:]]*=.*|${key} = ${value}|" "$conf"
    else
        grep -qE '^\[options\]' "$conf" || die "$conf has no [options] section — cannot safely insert ${key}"
        sed -i "/^\[options\]/a ${key} = ${value}" "$conf"
    fi
}

# Uncomments a line matching a pattern (e.g. "#ParallelDownloads" -> "ParallelDownloads")
uncomment_line() {
    local pattern="$1" file="$2"
    backup_file "$file"
    sed -i "s|^#\(${pattern}.*\)|\1|" "$file"
}