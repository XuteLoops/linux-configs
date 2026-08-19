#!/bin/bash
#
# setup-cachy-pacman-pipeline.sh
#
# Idempotent installer/repair script for the hardened Arch/CachyOS
# "safe update pipeline": pacman hooks that automatically verify every
# transaction (installcheck + checkrebuild) and roll back via pacback
# snapshots on failure, plus supporting hooks (shutdown/sleep inhibitor,
# arch-audit CVE scanning, rebuild detection, etc).
#
# Safe to re-run: existing correct state is left alone, drifted files are
# backed up with a timestamp before being overwritten, and packages already
# installed are skipped.
#
# Usage:
#   sudo ./setup-cachy-pacman-pipeline.sh            # install/repair the pipeline
#   sudo ./setup-cachy-pacman-pipeline.sh --verify    # also run an end-to-end
#                                                      # rollback smoke test after
#                                                      # (forces a failure, confirms
#                                                      # pacback rollback fires, then
#                                                      # reverts the override)
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Preamble
# ---------------------------------------------------------------------------

RUN_SMOKE_TEST=0
for arg in "$@"; do
    case "$arg" in
        --verify) RUN_SMOKE_TEST=1 ;;
        -h|--help)
            echo "Usage: $0 [--verify]"
            echo "  --verify   Run an end-to-end rollback smoke test after setup completes."
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg" >&2
            exit 1
            ;;
    esac
done

log() {
    echo "==> $*"
}

warn() {
    echo "WARNING: $*" >&2
}

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root (e.g. sudo $0 $*)" >&2
    exit 1
fi

# The user who invoked sudo — needed because makepkg refuses to run as root.
BUILD_USER="${SUDO_USER:-}"
if [ -z "$BUILD_USER" ] || [ "$BUILD_USER" = "root" ]; then
    echo "Could not determine a non-root build user (run this via 'sudo', not as root directly)." >&2
    exit 1
fi

HOOKS_DIR=/etc/pacman.d/hooks
SCRIPTS_DIR="$HOOKS_DIR/scripts"
mkdir -p "$SCRIPTS_DIR"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Idempotent official-repo package install.
ensure_pkg_installed() {
    local pkg="$1"
    if pacman -Qi "$pkg" &>/dev/null; then
        log "Already installed: $pkg"
    else
        log "Installing: $pkg"
        pacman -S --needed --noconfirm "$pkg"
    fi
}

# Idempotent AUR package install via paru.
ensure_aur_pkg_installed() {
    local pkg="$1"
    if pacman -Qi "$pkg" &>/dev/null; then
        log "Already installed (AUR): $pkg"
    else
        log "Installing (AUR): $pkg"
        sudo -u "$BUILD_USER" paru -S --needed --noconfirm "$pkg"
    fi
}

# Write $content to $target only if it differs from what's already there.
# Backs up the existing file with a timestamp suffix before overwriting.
deploy_file() {
    local target="$1"
    local content="$2"
    local mode="${3:-644}"

    if [ -f "$target" ]; then
        if diff -q <(printf '%s\n' "$content") "$target" >/dev/null 2>&1; then
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

# ---------------------------------------------------------------------------
# 1. AUR helper bootstrap (yay + paru)
# ---------------------------------------------------------------------------

log "Ensuring base-devel and git are present (needed to build AUR helpers)..."
ensure_pkg_installed base-devel
ensure_pkg_installed git

install_aur_helper() {
    local helper="$1"
    if command -v "$helper" &>/dev/null; then
        log "$helper already installed"
        return
    fi
    log "Building and installing $helper from AUR..."
    local tmpdir
    tmpdir=$(sudo -u "$BUILD_USER" mktemp -d)
    sudo -u "$BUILD_USER" git clone --quiet "https://aur.archlinux.org/${helper}.git" "$tmpdir"
    (cd "$tmpdir" && sudo -u "$BUILD_USER" makepkg -si --noconfirm)
    rm -rf "$tmpdir"
}

install_aur_helper yay
install_aur_helper paru

# ---------------------------------------------------------------------------
# 2. Official repo packages
# ---------------------------------------------------------------------------

OFFICIAL_PKGS=(
    pacman-contrib
    libsolv
    rebuild-detector
    arch-audit
    pkgfile
    curl
    openssl
    snapper
    snap-pac
)

log "Installing official-repo packages..."
for pkg in "${OFFICIAL_PKGS[@]}"; do
    ensure_pkg_installed "$pkg"
done

# ---------------------------------------------------------------------------
# 3. AUR packages
# ---------------------------------------------------------------------------

AUR_PKGS=(
    pacback
    linux-preserve-modules
    pacman-hook-reload-modules
    longoverdue
    sync-pacman-hook-git
    reflector-pacman-hook-git
    pacman-hook-systemd-restart-git
    systemd-cleanup-pacman-hook
    systemd-removed-services-hook
)

log "Installing AUR packages..."
for pkg in "${AUR_PKGS[@]}"; do
    ensure_aur_pkg_installed "$pkg"
done

# ---------------------------------------------------------------------------
# 4. Post-install commands
# ---------------------------------------------------------------------------

if [ -f /usr/share/libalpm/hooks/pacback.hook ]; then
    log "pacback hook already installed, skipping --install_hook"
else
    log "Running 'pacback --install_hook' to enable automatic snapshotting..."
    pacback --install_hook
fi

# ---------------------------------------------------------------------------
# 5. Deploy custom scripts
# ---------------------------------------------------------------------------

log "Deploying custom scripts..."

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
if installcheck x86_64 "$SOLVFILE" 2>&1 | tee "$LOGDIR/installcheck-$TIMESTAMP.log" | grep -q .; then
        logger -t verify-transaction "FAILED: installcheck found unsatisfied dependencies"
        FAILED=1
fi
rm -f "$SOLVFILE"

# --- Check 2: checkrebuild (broken linkage / stale interpreter deps) ---
if checkrebuild 2>&1 | tee "$LOGDIR/checkrebuild-$TIMESTAMP.log" | grep -q .; then
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

deploy_file "$SCRIPTS_DIR/inhibit-start.sh" "$INHIBIT_START_CONTENT" 755
deploy_file "$SCRIPTS_DIR/inhibit-stop.sh" "$INHIBIT_STOP_CONTENT" 755
deploy_file "$SCRIPTS_DIR/verify-transaction.sh" "$VERIFY_TRANSACTION_CONTENT" 755

# ---------------------------------------------------------------------------
# 6. Deploy custom hooks
# ---------------------------------------------------------------------------

log "Deploying custom hooks..."

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

# arch-audit.hook is written directly (not fetched from Strykar's repo) since
# it needs the --source/--show-cve flags and, on pacman builds with hook/
# scriptlet network sandboxing, a NetworkAccess = allowed line. That sandbox
# feature isn't confirmed present in all pacman builds, so we probe for it
# rather than assume it based on distro.
if pacman --help | grep -q -- '--disable-sandbox-network'; then
    log "Detected pacman network sandbox support — adding NetworkAccess = allowed to arch-audit.hook"
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

deploy_file "$HOOKS_DIR/00-systemd-inhibit-pre.hook" "$INHIBIT_PRE_HOOK_CONTENT"
deploy_file "$HOOKS_DIR/zz-systemd-inhibit-post.hook" "$INHIBIT_POST_HOOK_CONTENT"
deploy_file "$HOOKS_DIR/zy-verifytransaction-post.hook" "$VERIFY_HOOK_CONTENT"
deploy_file "$HOOKS_DIR/arch-audit.hook" "$ARCH_AUDIT_HOOK_CONTENT"

# ---------------------------------------------------------------------------
# 7. Enable services/timers
# ---------------------------------------------------------------------------

log "Enabling paccache.timer..."
systemctl enable --now paccache.timer

# ---------------------------------------------------------------------------
# 8. Optional smoke test
# ---------------------------------------------------------------------------

run_smoke_test() {
    local script_path="$SCRIPTS_DIR/verify-transaction.sh"
    local pre_test_backup="${script_path}.pre-smoketest.bak"

    log "Starting rollback smoke test: forcing a failure to confirm pacback rollback fires..."
    cp -a "$script_path" "$pre_test_backup"
    sed -i '0,/^FAILED=0$/{s/^FAILED=0$/FAILED=0\nFAILED=1  # --verify smoke test override/}' "$script_path"

    log "Triggering a harmless transaction (reinstalling 'licenses')..."
    pacman -S --noconfirm licenses || true

    log "Waiting a few seconds for the detached rollback process to log completion..."
    sleep 5

    local smoke_test_result=1
    if journalctl -t verify-transaction --since "2 minutes ago" | grep -q "Rollback to snapshot"; then
        log "Smoke test PASSED: rollback triggered and completed successfully."
        smoke_test_result=0
    else
        warn "Smoke test FAILED: expected rollback log entry not found."
        warn "Check 'journalctl -t verify-transaction' manually before trusting the pipeline."
    fi

    log "Reverting smoke test override..."
    cp -a "$pre_test_backup" "$script_path"
    chmod 755 "$script_path"
    rm -f "$pre_test_backup"

    return "$smoke_test_result"
}

if [ "$RUN_SMOKE_TEST" -eq 1 ]; then
    if ! run_smoke_test; then
        echo
        warn "Pipeline installed, but the smoke test did not confirm rollback works. Investigate before relying on it."
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# 9. Summary
# ---------------------------------------------------------------------------

echo
log "Pipeline setup complete."
log "Custom hooks in: $HOOKS_DIR"
log "Custom scripts in: $SCRIPTS_DIR"
log "Verification logs in: /var/log/pacman-verify"
if [ "$RUN_SMOKE_TEST" -eq 0 ]; then
    log "Tip: re-run with --verify to run an end-to-end rollback smoke test."
fi