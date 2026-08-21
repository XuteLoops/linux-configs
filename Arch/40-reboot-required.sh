#!/bin/bash
#
# 40-reboot-required.sh
#
# Standalone module: detects two high-confidence signals that a reboot
# (not just a service restart) is needed after a transaction — a kernel
# upgrade not yet booted into, or systemd (PID 1) itself running from a
# deleted binary. Writes /run/reboot-required (tmpfs, clears itself on
# every boot) and prints an immediate banner during the transaction, plus
# wires a persistent reminder into bash and zsh so it's visible on every
# new shell until you actually reboot.
#
# Safe to re-run.
#
# Usage:
#   sudo ./40-reboot-required.sh
#
set -euo pipefail

log() { echo "==> $*"; }
warn() { echo "WARNING: $*" >&2; }

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root (e.g. sudo $0)" >&2
    exit 1
fi

HOOKS_DIR=/etc/pacman.d/hooks
SCRIPTS_DIR="$HOOKS_DIR/scripts"
mkdir -p "$SCRIPTS_DIR"

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

ensure_line_in_file() {
    local file="$1"
    local line="$2"

    mkdir -p "$(dirname "$file")"
    touch "$file"

    if grep -qxF "$line" "$file" 2>/dev/null; then
        log "Already present in $file"
    else
        log "Adding to $file"
        printf '\n%s\n' "$line" >> "$file"
    fi
}

CHECK_REBOOT_REQUIRED_CONTENT=$(cat <<'EOF'
#!/bin/bash
# Detects whether a reboot is needed after a pacman transaction, based on
# two high-confidence signals (not every package upgrade — only ones that
# can't be fixed by restarting an individual service):
#   1. The running kernel's module directory no longer exists, meaning a
#      newer kernel was installed but not yet booted into.
#   2. systemd (PID 1) itself is running from a deleted binary, meaning
#      its own package was upgraded. Nothing short of a reboot cleanly
#      replaces PID 1.
#
# If either is true, writes /run/reboot-required (and .pkgs, listing the
# packages from the triggering transaction via NeedsTargets on stdin).
# /run is tmpfs, so this clears itself automatically on every reboot —
# no cleanup step needed.

REBOOT_FLAG=/run/reboot-required
REBOOT_PKGS=/run/reboot-required.pkgs
NEED_REBOOT=0
REASON=""

RUNNING_KERNEL="$(uname -r)"
if [ ! -d "/usr/lib/modules/$RUNNING_KERNEL" ]; then
        NEED_REBOOT=1
        REASON="kernel upgraded (currently running: $RUNNING_KERNEL)"
fi

if readlink /proc/1/exe 2>/dev/null | grep -q ' (deleted)'; then
        NEED_REBOOT=1
        if [ -n "$REASON" ]; then
                REASON="$REASON; systemd (PID 1) upgraded"
        else
                REASON="systemd (PID 1) upgraded"
        fi
fi

if [ "$NEED_REBOOT" -eq 1 ]; then
        echo "$REASON" > "$REBOOT_FLAG"
        logger -t reboot-required "Reboot required: $REASON"
        cat >> "$REBOOT_PKGS"
        echo ""
        echo "*** System restart required: $REASON ***"
        echo ""
fi
EOF
)

ANNOUNCE_REBOOT_REQUIRED_CONTENT=$(cat <<'EOF'
# Sourced by interactive shell startup files (bash and zsh). Warns if a
# prior pacman transaction flagged that a reboot is needed. POSIX-compatible
# so it works the same under both shells.
if [ -f /run/reboot-required ]; then
        echo ""
        echo "*** System restart required ***"
        cat /run/reboot-required
        if [ -f /run/reboot-required.pkgs ]; then
                echo "Triggered by:"
                sort -u /run/reboot-required.pkgs | sed 's/^/  - /'
        fi
        echo ""
fi
EOF
)

REBOOT_REQUIRED_HOOK_CONTENT=$(cat <<'EOF'
[Trigger]
Operation = Install
Operation = Upgrade
Operation = Remove
Type = Package
Target = *

[Action]
Description = Checking whether a reboot is required...
When = PostTransaction
NeedsTargets
Exec = /etc/pacman.d/hooks/scripts/check-reboot-required.sh
EOF
)

log "Deploying reboot-required scripts and hook..."
deploy_file "$SCRIPTS_DIR/check-reboot-required.sh" "$CHECK_REBOOT_REQUIRED_CONTENT" 755
deploy_file "$SCRIPTS_DIR/announce-reboot-required.sh" "$ANNOUNCE_REBOOT_REQUIRED_CONTENT" 644
deploy_file "$HOOKS_DIR/zx-reboot-required-post.hook" "$REBOOT_REQUIRED_HOOK_CONTENT"

log "Wiring reboot-required announcer into shell startup..."
ensure_line_in_file /etc/bash.bashrc '[ -r /etc/pacman.d/hooks/scripts/announce-reboot-required.sh ] && . /etc/pacman.d/hooks/scripts/announce-reboot-required.sh'
ensure_line_in_file /etc/zsh/zshrc '[ -r /etc/pacman.d/hooks/scripts/announce-reboot-required.sh ] && . /etc/pacman.d/hooks/scripts/announce-reboot-required.sh'

echo
log "Done."
log "Reboot-required signal: /run/reboot-required (checked on new bash/zsh shells)"
