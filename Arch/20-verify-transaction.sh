#!/bin/bash
#
# 20-verify-transaction.sh
#
# Standalone module: the core safety gate. After every pacman transaction,
# runs installcheck (dependency satisfiability) and checkrebuild (broken
# linkage / stale interpreter deps). On failure, automatically rolls back
# to the most recent pacback snapshot via a detached background process.
#
# Installs: libsolv, rebuild-detector (official repos), pacback (AUR).
# If neither yay nor paru is already installed, bootstraps paru
# automatically so this module works standalone.
#
# Safe to re-run.
#
# Usage:
#   sudo ./20-verify-transaction.sh
#
set -euo pipefail

log() { echo "==> $*"; }
warn() { echo "WARNING: $*" >&2; }

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root (e.g. sudo $0)" >&2
    exit 1
fi

BUILD_USER="${SUDO_USER:-}"
if [ -z "$BUILD_USER" ] || [ "$BUILD_USER" = "root" ]; then
    echo "Could not determine a non-root build user (run this via 'sudo', not as root directly)." >&2
    exit 1
fi

HOOKS_DIR=/etc/pacman.d/hooks
SCRIPTS_DIR="$HOOKS_DIR/scripts"
mkdir -p "$SCRIPTS_DIR"

ensure_pkg_installed() {
    local pkg="$1"
    if pacman -Qi "$pkg" &>/dev/null; then
        log "Already installed: $pkg"
    else
        log "Installing: $pkg"
        pacman -S --needed --noconfirm "$pkg"
    fi
}

# Ensure at least one AUR helper is available (needed for pacback).
# Doesn't require the 00-aur-helpers.sh module to have run — bootstraps
# paru automatically if neither yay nor paru is already present, so this
# module works fully standalone.
ensure_aur_helper() {
    if command -v paru &>/dev/null || command -v yay &>/dev/null; then
        return
    fi
    log "No AUR helper found — bootstrapping paru..."
    ensure_pkg_installed base-devel
    ensure_pkg_installed git
    local tmpdir
    tmpdir=$(sudo -u "$BUILD_USER" mktemp -d)
    sudo -u "$BUILD_USER" git clone --quiet "https://aur.archlinux.org/paru.git" "$tmpdir"
    (cd "$tmpdir" && sudo -u "$BUILD_USER" makepkg -si --noconfirm)
    rm -rf "$tmpdir"
}

aur_install() {
    local pkg="$1"
    if pacman -Qi "$pkg" &>/dev/null; then
        log "Already installed (AUR): $pkg"
        return
    fi
    log "Installing (AUR): $pkg"
    local helper
    helper=$(command -v paru || command -v yay)
    sudo -u "$BUILD_USER" "$helper" -S --needed --noconfirm "$pkg"
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

log "Installing official-repo dependencies..."
ensure_pkg_installed libsolv
ensure_pkg_installed rebuild-detector

log "Ensuring an AUR helper is available..."
ensure_aur_helper

log "Installing pacback..."
aur_install pacback

if [ -f /usr/share/libalpm/hooks/pacback.hook ]; then
    log "pacback hook already installed, skipping --install_hook"
else
    log "Running 'pacback --install_hook' to enable automatic snapshotting..."
    pacback --install_hook
fi

VERIFY_TRANSACTION_CONTENT=$(cat <<'EOF'
#!/bin/bash
set -o pipefail

FAILED=0
LOGDIR=/var/log/pacman-verify
mkdir -p "$LOGDIR"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# --- Check 1: installcheck (dependency graph satisfiability) ---
SOLVFILE=$(mktemp /tmp/local-XXXXXX.solv)
archrepo2solv -l /var/lib/pacman/local > "$SOLVFILE"
INSTALLCHECK_OUTPUT="$(installcheck x86_64 "$SOLVFILE" 2>&1)"
echo "$INSTALLCHECK_OUTPUT" | tee "$LOGDIR/installcheck-$TIMESTAMP.log"
if [ -n "$INSTALLCHECK_OUTPUT" ]; then
        logger -t verify-transaction "FAILED: installcheck found unsatisfied dependencies"
        FAILED=1
fi
rm -f "$SOLVFILE"

# --- Check 2: checkrebuild (broken linkage / stale interpreter deps) ---
CHECKREBUILD_OUTPUT="$(checkrebuild 2>&1)"
echo "$CHECKREBUILD_OUTPUT" | tee "$LOGDIR/checkrebuild-$TIMESTAMP.log"
if [ -n "$CHECKREBUILD_OUTPUT" ]; then
        logger -t verify-transaction "FAILED: checkrebuild found packages needing rebuild"
        FAILED=1
fi

# --- Verdict ---
if [ "$FAILED" -eq 1 ]; then
        LATEST_SNAPSHOT=$(pacback -ls | grep -oP '(?<=│ )[0-9]+(?= - Pkgs)' | tail -1)
        if [ -n "$LATEST_SNAPSHOT" ]; then
                logger -t verify-transaction "TRANSACTION VERIFICATION FAILED - rolling back to snapshot ss${LATEST_SNAPSHOT}"
                setsid bash -c '
                        while [ -f /var/lib/pacman/db.lck ]; do sleep 1; done
                        yes | pacback -ss "'"$LATEST_SNAPSHOT"'" -nc
                        logger -t verify-transaction "Rollback to snapshot '"$LATEST_SNAPSHOT"' completed"
                ' </dev/null >/dev/null 2>&1 &
                disown
        else
                logger -t verify-transaction "TRANSACTION VERIFICATION FAILED - no snapshot found to roll back to!"
        fi
        exit 1
else
        logger -t verify-transaction "OK: all checks passed"
        exit 0
fi
EOF
)

VERIFY_HOOK_CONTENT=$(cat <<'EOF'
[Trigger]
Operation = Install
Operation = Upgrade
Operation = Remove
Type = Package
Target = *

[Action]
Description = Verifying Transaction (installcheck + checkrebuild)...
When = PostTransaction
Exec = /etc/pacman.d/hooks/scripts/verify-transaction.sh
EOF
)

log "Deploying verify-transaction.sh and its hook..."
deploy_file "$SCRIPTS_DIR/verify-transaction.sh" "$VERIFY_TRANSACTION_CONTENT" 755
deploy_file "$HOOKS_DIR/zy-verifytransaction-post.hook" "$VERIFY_HOOK_CONTENT"

echo
log "Done."
log "Verification logs in: /var/log/pacman-verify"
