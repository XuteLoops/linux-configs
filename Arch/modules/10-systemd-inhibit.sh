#!/bin/bash
#
# 10-systemd-inhibit.sh
#
# Standalone module: deploys pre/post pacman hooks that hold a
# shutdown/sleep inhibitor lock for the duration of every transaction,
# so the system can't sleep or power off mid-update.
#
# Safe to re-run: existing correct files are left alone, drifted files
# are backed up with a timestamp before being overwritten.
#
# Usage:
#   sudo ./10-systemd-inhibit.sh
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

INHIBIT_START_CONTENT=$(cat <<'EOF'
#!/bin/bash
setsid systemd-inhibit --what=shutdown:sleep:idle --who="pacman" --why="Package transaction in progress" --mode=block sleep infinity </dev/null >/dev/null 2>&1 &
echo $! > /run/pacman-inhibit.pid
disown
EOF
)

INHIBIT_STOP_CONTENT=$(cat <<'EOF'
#!/bin/bash
if [ -f /run/pacman-inhibit.pid ]; then
        kill "$(cat /run/pacman-inhibit.pid)" 2>/dev/null
        rm -f /run/pacman-inhibit.pid
fi
EOF
)

INHIBIT_PRE_HOOK_CONTENT=$(cat <<'EOF'
[Trigger]
Operation = Install
Operation = Upgrade
Operation = Remove
Type = Package
Target = *

[Action]
Description = Acquiring shutdown/sleep inhibitor lock...
When = PreTransaction
Exec = /etc/pacman.d/hooks/scripts/inhibit-start.sh
EOF
)

INHIBIT_POST_HOOK_CONTENT=$(cat <<'EOF'
[Trigger]
Operation = Install
Operation = Upgrade
Operation = Remove
Type = Package
Target = *

[Action]
Description = Releasing shutdown/sleep inhibitor lock...
When = PostTransaction
Exec = /etc/pacman.d/hooks/scripts/inhibit-stop.sh
EOF
)

log "Deploying inhibitor scripts and hooks..."
deploy_file "$SCRIPTS_DIR/inhibit-start.sh" "$INHIBIT_START_CONTENT" 755
deploy_file "$SCRIPTS_DIR/inhibit-stop.sh" "$INHIBIT_STOP_CONTENT" 755
deploy_file "$HOOKS_DIR/00-systemd-inhibit-pre.hook" "$INHIBIT_PRE_HOOK_CONTENT"
deploy_file "$HOOKS_DIR/zz-systemd-inhibit-post.hook" "$INHIBIT_POST_HOOK_CONTENT"

echo
log "Done."
