#!/bin/bash
#
# 30-arch-audit.sh
#
# Standalone module: informational-only CVE scan against installed
# packages after every transaction. Not part of any pass/fail gate —
# purely visibility, can't itself cause a rollback.
#
# Detects, at runtime, whether the local pacman/libalpm build supports
# hook/scriptlet network sandboxing (a feature not present in every
# pacman build) and adds NetworkAccess = allowed to the hook only if so —
# never assumed based on distro.
#
# Safe to re-run.
#
# Usage:
#   sudo ./30-arch-audit.sh
#
set -euo pipefail

log() { echo "==> $*"; }
warn() { echo "WARNING: $*" >&2; }

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root (e.g. sudo $0)" >&2
    exit 1
fi

HOOKS_DIR=/etc/pacman.d/hooks

ensure_pkg_installed() {
    local to_install=()
    local pkg
    for pkg in "$@"; do
        if pacman -Qi "$pkg" &>/dev/null; then
            log "Already installed: $pkg"
        else
            to_install+=("$pkg")
        fi
    done
    if [ "${#to_install[@]}" -gt 0 ]; then
        log "Installing: ${to_install[*]}"
        pacman -S --needed --noconfirm "${to_install[@]}"
    fi
}

deploy_file() {
    local target="$1"
    local content="$2"
    local mode="${3:-644}"

    if [ -f "$target" ]; then
        local existing
        existing="$(cat "$target")"
        if [ "$existing" = "$content" ]; then
            log "Unchanged, skipping: $target"
            chmod "$mode" "$target"
            return
        fi
        local backup
        backup="${target}.$(date +%Y%m%d-%H%M%S).bak"
        log "Existing file differs — backing up: $target -> $backup"
        cp -a "$target" "$backup"
    else
        log "Creating: $target"
    fi

    printf '%s\n' "$content" > "$target"
    chmod "$mode" "$target"
}

log "Installing arch-audit and dependencies..."
ensure_pkg_installed arch-audit curl openssl

# Hook parsing (and the NetworkAccess key) lives in libalpm, not the
# pacman frontend binary itself — pacman is just a thin CLI wrapper
# around it — so we need to find and grep the actual libalpm shared
# object, not `pacman`.
ALPM_LIB=$(ldd "$(command -v pacman)" 2>/dev/null | awk '/libalpm\.so/ {print $3; exit}')
# NOTE: capture strings' output into a variable before grepping it,
# rather than piping `strings ... | grep -q ...` directly. `grep -q`
# exits the instant it finds a match, which can close the pipe while
# `strings` is still writing — killing it with SIGPIPE. With
# `set -o pipefail` active, that SIGPIPE-driven exit gets reported as
# the pipeline's overall exit status, masking a true positive from grep.
ALPM_STRINGS=""
if [ -n "$ALPM_LIB" ]; then
    ALPM_STRINGS="$(strings "$ALPM_LIB")"
fi
if [ -n "$ALPM_LIB" ] && grep -qi 'networkaccess' <<< "$ALPM_STRINGS"; then
    log "Detected pacman network sandbox support (via $ALPM_LIB) — adding NetworkAccess = allowed to arch-audit.hook"
    NETWORK_ACCESS_LINE="NetworkAccess = allowed"
else
    log "pacman network sandbox not detected — omitting NetworkAccess key from arch-audit.hook"
    NETWORK_ACCESS_LINE=""
fi

ARCH_AUDIT_HOOK_CONTENT=$(cat <<EOF
[Trigger]
Operation = Install
Operation = Upgrade
Operation = Remove
Type = Package
Target = *

[Action]
Depends = curl
Depends = openssl
Depends = arch-audit
When = PostTransaction
Exec = /bin/bash -c '/usr/bin/arch-audit --source https://security.archlinux.org/issues/all.json --color always --upgradable --quiet --show-cve || true'
${NETWORK_ACCESS_LINE}
EOF
)

deploy_file "$HOOKS_DIR/arch-audit.hook" "$ARCH_AUDIT_HOOK_CONTENT"

echo
log "Done."