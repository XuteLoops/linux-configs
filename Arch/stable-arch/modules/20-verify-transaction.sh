#!/bin/bash
#
# 20-verify-transaction.sh
#
# Standalone module: the core safety gate. After every pacman transaction,
# runs paccheck (dependency satisfiability, checked directly against the
# live pacman database) and checkrebuild (broken linkage / stale
# interpreter deps). On failure, automatically rolls back to the most
# recent pacback snapshot via a detached background process.
#
# Dependency check history: this originally used archrepo2solv (libsolv)
# to convert /var/lib/pacman/local into a .solv file, then ran libsolv's
# installcheck against it. That approach was dropped after a confirmed,
# reproducible failure: installcheck does not correctly resolve Arch's
# "any" architecture packages (filesystem, licenses, and others) even
# against a verified byte-correct, complete solv file — every package
# with arch:any was treated as unsatisfiable, which cascaded through
# glibc (which requires filesystem) into nearly the entire system on
# every single transaction. Confirmed directly: dumped and manually
# inspected the exact solv file archrepo2solv produced during a real
# failing transaction (all expected solvables present, correct
# requires/provides throughout), then ran installcheck against that
# exact saved file by hand, outside any hook — it failed identically,
# proving the bug was in installcheck's own dependency resolution, not
# in this script, the hook execution environment, or file generation.
# paccheck (from pacutils, already a pacback dependency) checks
# satisfiability directly against the live libalpm database, so it
# never goes through solv format at all and isn't exposed to this bug.
#
# Installs: pacutils, rebuild-detector (official repos), pacback (AUR).
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

TARGET_HOME=$(getent passwd "$BUILD_USER" | cut -d: -f6)
if [ -z "$TARGET_HOME" ] || [ ! -d "$TARGET_HOME" ]; then
    echo "Could not resolve a home directory for user '$BUILD_USER'." >&2
    exit 1
fi

HOOKS_DIR=/etc/pacman.d/hooks
SCRIPTS_DIR="$HOOKS_DIR/scripts"
mkdir -p "$SCRIPTS_DIR"

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

# Ensure a WORKING AUR helper is available (needed for pacback). Doesn't
# require the 00-aur-helpers.sh module to have run — carries the same
# tiered bootstrap logic inline, so this module works fully standalone.
# yay preferred over paru throughout (paru has caused real problems in
# practice); prebuilt tried before source; "working" verified by
# actually running --version, not just checking install status; builds
# happen under the user's home directory, not /tmp (which is commonly a
# size-capped tmpfs and has been observed causing "Disk quota exceeded"
# failures during large source builds).
_aur_helper_working() {
    local bin="$1"
    command -v "$bin" &>/dev/null && "$bin" --version &>/dev/null
}

_aur_helper_remove_if_installed() {
    local pkgname="$1"
    if pacman -Qi "$pkgname" &>/dev/null; then
        log "Removing non-functional $pkgname..."
        pacman -R --noconfirm "$pkgname" \
            || warn "Failed to remove $pkgname — may cause a conflict on the next install attempt."
    fi
}

_aur_helper_install_pkg() {
    local pkgname="$1"
    ensure_pkg_installed base-devel git

    local build_root="${TARGET_HOME}/.cache/pipeline-aur-build"
    sudo -u "$BUILD_USER" mkdir -p "$build_root"
    local build_dir
    build_dir=$(sudo -u "$BUILD_USER" mktemp -d "${build_root}/build.XXXXXX")

    if ! sudo -u "$BUILD_USER" git clone --quiet --depth=1 "https://aur.archlinux.org/${pkgname}.git" "$build_dir/${pkgname}"; then
        warn "Failed to clone $pkgname from AUR"
        rm -rf "$build_dir"
        return 1
    fi

    if ! (cd "$build_dir/${pkgname}" && sudo -u "$BUILD_USER" makepkg -si --noconfirm); then
        warn "Failed to build/install $pkgname"
        rm -rf "$build_dir"
        return 1
    fi

    rm -rf "$build_dir"
}

ensure_aur_helper() {
    if _aur_helper_working yay; then
        log "AUR helper already present and working: yay"
        return 0
    fi
    if _aur_helper_working paru; then
        log "AUR helper already present and working: paru"
        return 0
    fi

    log "Trying yay-bin (prebuilt, fast) first..."
    if _aur_helper_install_pkg "yay-bin" && _aur_helper_working yay; then
        log "Installed AUR helper: yay (prebuilt binary)"
        return 0
    fi
    warn "yay-bin unavailable or broken — trying paru-bin instead."
    _aur_helper_remove_if_installed "yay-bin"

    if _aur_helper_install_pkg "paru-bin" && _aur_helper_working paru; then
        log "Installed AUR helper: paru (prebuilt binary)"
        return 0
    fi
    warn "paru-bin also unavailable or broken — building yay from source."
    _aur_helper_remove_if_installed "paru-bin"

    if _aur_helper_install_pkg "yay" && _aur_helper_working yay; then
        log "Installed AUR helper: yay (built from source)"
        return 0
    fi
    warn "Building yay from source also failed — falling back to paru from source."

    if ! _aur_helper_install_pkg "paru"; then
        echo "All AUR helper install options exhausted — cannot proceed." >&2
        exit 1
    fi
    if ! _aur_helper_working paru; then
        echo "paru was built from source but still fails to run — check the build output above." >&2
        exit 1
    fi
    log "Installed AUR helper: paru (built from source, last resort)"
}

aur_install() {
    local pkg="$1"
    if pacman -Qi "$pkg" &>/dev/null; then
        log "Already installed (AUR): $pkg"
        return
    fi
    log "Installing (AUR): $pkg"
    local helper
    helper=$(command -v yay || command -v paru)
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
ensure_pkg_installed pacutils rebuild-detector

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

# --- Check 1: dependency satisfiability, via paccheck (pacutils) ---
# Checks directly against the live pacman/libalpm database — no solv
# conversion step. See the comment block at the top of the module
# script (20-verify-transaction.sh) for why this replaced
# archrepo2solv + libsolv's installcheck: that combination was
# confirmed, directly and reproducibly, to fail on Arch's "any"
# architecture packages (filesystem, licenses, etc.) even when fed a
# verified byte-correct, complete solv file, cascading through nearly
# every installed package on every transaction. paccheck avoids the
# issue entirely by never converting to solv format.
PACCHECK_OUTPUT="$(paccheck --dependencies --quiet 2>&1)"
echo "$PACCHECK_OUTPUT" | tee "$LOGDIR/paccheck-$TIMESTAMP.log"
if [ -n "$PACCHECK_OUTPUT" ]; then
        logger -t verify-transaction "FAILED: paccheck found unsatisfied dependencies"
        FAILED=1
fi

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
Description = Verifying Transaction (paccheck + checkrebuild)...
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