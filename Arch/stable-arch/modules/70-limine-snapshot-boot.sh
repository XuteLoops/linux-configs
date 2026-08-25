#!/bin/bash
#
# 70-limine-snapshot-boot.sh
#
# Standalone module: wires snapper snapshots into the Limine boot menu,
# so a prior snapshot can be selected and booted directly, not just
# restored via pacback's automatic rollback. Also adds the appropriate
# btrfs-overlayfs hook to mkinitcpio so a booted snapshot is actually
# usable (writable via an overlay) rather than a broken read-only boot —
# without this, selecting a snapshot from the menu wouldn't work.
#
# Requires: snapper already configured (see 15-snapper-setup.sh) and
# Limine as the bootloader. GRUB is explicitly NOT supported by this
# module — the equivalent grub-btrfs integration is a different package
# and mechanism that hasn't been built here yet.
#
# Package install strategy: prefers a pre-built binary from any
# configured repo over building from AUR. limine-mkinitcpio-hook and
# limine-snapper-sync have a confirmed, unresolved Gradle/GraalVM build
# issue on vanilla Arch, so this module adds chaotic-aur (a well-known
# prebuilt-binary AUR mirror) to install prebuilt versions of just these
# two packages, then immediately restricts that repo to Sync+Upgrade
# only — no new installs from it beyond these two. See the comment
# above ensure_chaotic_aur() and install_pkg_prefer_binary_repo() calls
# below for the full detail, including why this differs from an earlier
# CachyOS-repo-auto-add attempt that was tried and reverted.
#
# limine.conf marker handling: if the //Snapshots injection marker isn't
# already present, this module inserts one automatically — finds the
# first top-level boot entry block and adds the marker as its last line,
# backing up the file first. This is a heuristic (assumes your first
# entry is the one you want snapshots under); if that's wrong for your
# setup, just move the single inserted line manually afterward.
#
# Safe to re-run.
#
# Usage:
#   sudo ./70-limine-snapshot-boot.sh
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

# yay preferred over paru throughout (paru has caused real problems in
# practice); prebuilt tried before source; "working" verified by
# actually running --version; builds happen under the user's home
# directory, not /tmp.
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

install_pkg_prefer_binary_repo() {
    local pkg="$1"
    if pacman -Qi "$pkg" &>/dev/null; then
        log "Already installed: $pkg"
        return
    fi

    # Prefer a pre-built binary from any currently-configured repo over
    # building from AUR (covers chaotic-aur, if ensure_chaotic_aur has
    # added it below, or any future official repo that picks this
    # package up).
    if pacman -Si "$pkg" &>/dev/null; then
        log "Found $pkg in a configured repo — installing prebuilt binary (skipping AUR build)..."
        pacman -S --needed --noconfirm "$pkg"
        return
    fi

    log "Not found in any configured repo — building from AUR: $pkg"
    local helper
    helper=$(command -v yay || command -v paru)
    sudo -u "$BUILD_USER" "$helper" -S --needed --noconfirm "$pkg"
}

# --- chaotic-aur: precompiled fallback for limine-mkinitcpio-hook /
# limine-snapper-sync, both permanently blocked building from AUR by a
# confirmed Gradle/GraalVM version incompatibility (see the comment
# above the install_pkg_prefer_binary_repo calls below). chaotic-aur
# ships prebuilt binaries for these, sidestepping the Gradle build
# entirely — unlike the earlier CachyOS-repo-auto-add attempt, this is
# a well-known, widely-used binary AUR mirror, not a distro's own
# pacman fork, and its installer is deterministic (key import + two
# package installs), not an interactive third-party script piped
# through non-interactively (which is what caused the earlier CachyOS
# attempt to fail silently). Deliberately scoped to ONLY these two
# packages — see restrict_chaotic_aur_usage below, which locks the repo
# down to Sync+Upgrade (no new installs) once they're in place, so this
# doesn't become a general-purpose AUR-binary shortcut for the rest of
# the system.
CHAOTIC_KEY=3056513887B78AEB

ensure_chaotic_aur() {
    if grep -qE '^\[chaotic-aur\]' /etc/pacman.conf; then
        log "chaotic-aur already configured in /etc/pacman.conf, skipping setup."
        return
    fi

    log "Setting up chaotic-aur (needed for limine-mkinitcpio-hook / limine-snapper-sync prebuilt binaries)..."

    if ! pacman-key --finger "$CHAOTIC_KEY" &>/dev/null; then
        log "Importing chaotic-aur signing key..."
        pacman-key --recv-key "$CHAOTIC_KEY" --keyserver keyserver.ubuntu.com
        pacman-key --lsign-key "$CHAOTIC_KEY"
    else
        log "chaotic-aur signing key already imported."
    fi

    if ! pacman -Qi chaotic-keyring &>/dev/null; then
        log "Installing chaotic-keyring..."
        pacman -U --noconfirm 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst'
    fi
    if ! pacman -Qi chaotic-mirrorlist &>/dev/null; then
        log "Installing chaotic-mirrorlist..."
        pacman -U --noconfirm 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst'
    fi

    log "Adding [chaotic-aur] to /etc/pacman.conf (full usage, temporarily — restricted after install)..."
    cp -a /etc/pacman.conf "/etc/pacman.conf.$(date +%Y%m%d-%H%M%S).bak"
    {
        echo ""
        echo "[chaotic-aur]"
        echo "Include = /etc/pacman.d/chaotic-mirrorlist"
    } >> /etc/pacman.conf

    log "Syncing package databases..."
    pacman -Syy
}

# Locks [chaotic-aur] down to Sync+Upgrade only (no Install/Search),
# once both limine packages are confirmed actually installed. This
# means the repo's db still refreshes and the two packages installed
# from it still get upgrades via normal -Syu, but nothing new can be
# pulled from chaotic-aur afterward. Only narrows once — if the section
# already has a Usage line, leaves it alone rather than overwriting a
# choice made elsewhere. If either package isn't actually installed yet
# (e.g. this run failed partway), leaves the repo at full access so a
# retry can still use it.
restrict_chaotic_aur_usage() {
    if ! grep -qE '^\[chaotic-aur\]' /etc/pacman.conf; then
        return
    fi
    if ! pacman -Qi limine-mkinitcpio-hook &>/dev/null || ! pacman -Qi limine-snapper-sync &>/dev/null; then
        warn "Not restricting [chaotic-aur] usage — one or both limine packages aren't installed yet."
        return
    fi
    if awk '/^\[chaotic-aur\]/{f=1;next} /^\[/{f=0} f && /^Usage[[:space:]]*=/{print; exit}' /etc/pacman.conf | grep -q .; then
        log "[chaotic-aur] already has a Usage restriction set, leaving it as-is."
        return
    fi

    log "Both limine packages confirmed installed — restricting [chaotic-aur] to Sync+Upgrade only..."
    cp -a /etc/pacman.conf "/etc/pacman.conf.$(date +%Y%m%d-%H%M%S).bak"
    sed -i '/^\[chaotic-aur\]/a Usage = Sync Upgrade' /etc/pacman.conf
    log "[chaotic-aur] restricted — its db will still refresh and installed packages will still upgrade, but no new packages can be installed from it."
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

# --- Bootloader detection ---
if pacman -Qi grub &>/dev/null; then
    echo "GRUB detected. This module only supports Limine — the equivalent" >&2
    echo "grub-btrfs integration is a different package/mechanism that hasn't" >&2
    echo "been built yet. Nothing done. See HANDOFF.md 'Open items'." >&2
    exit 0
fi

if ! pacman -Qi limine &>/dev/null; then
    echo "Neither Limine nor GRUB detected as installed. Aborting — this module" >&2
    echo "only knows how to configure Limine." >&2
    exit 1
fi

log "Limine detected."

# --- Prerequisite: snapper must already be configured ---
if [ ! -f /etc/snapper/configs/root ]; then
    echo "snapper 'root' config not found. Run 15-snapper-setup.sh first —" >&2
    echo "this module needs snapshots to already exist to sync into the boot menu." >&2
    exit 1
fi

# --- Install packages ---
log "Ensuring an AUR helper is available..."
ensure_aur_helper

if pacman -Qi limine-entry-tool &>/dev/null && ! pacman -Qi limine-mkinitcpio-hook &>/dev/null; then
    log "Removing limine-entry-tool (superseded by limine-mkinitcpio-hook, which conflicts with it)..."
    pacman -Rdd --noconfirm limine-entry-tool
fi

# NOTE: limine-mkinitcpio-hook and limine-snapper-sync both build a
# native Java component via Gradle + GraalVM when built from AUR
# (confirmed on their AUR comments pages — intentional upstream, not a
# bug). CONFIRMED BLOCKER on vanilla Arch: building from AUR fails with
# "Cannot find module 'gradle-public-api-legacy' in distribution
# directory '/usr/share/java/gradle'" — a genuine version mismatch
# between Arch's currently-packaged gradle and what these PKGBUILDs'
# build scripts expect. Confirmed NOT a local cache/daemon issue.
# Confirmed on both stable and -git variants of both packages.
#
# An earlier automatic CachyOS-repo fallback was tried and reverted —
# their installer silently failed to add a working repo section when
# run non-interactively, while still installing CachyOS's patched
# pacman fork as a side effect. chaotic-aur (below) avoids that failure
# mode: it's a deterministic key-import + package-install sequence, not
# an interactive third-party installer script piped through
# non-interactively, and it doesn't touch pacman itself.
ensure_chaotic_aur
install_pkg_prefer_binary_repo limine-mkinitcpio-hook
install_pkg_prefer_binary_repo limine-snapper-sync
restrict_chaotic_aur_usage

# --- Add the overlay hook to mkinitcpio.conf ---
# limine-mkinitcpio-hook provides two overlay hook variants: btrfs-overlayfs
# (for the older udev-based mkinitcpio hook set) and sd-btrfs-overlayfs (for
# the newer systemd-based hook set) — sd-btrfs-overlayfs will fail outright
# under udev hooks, so which one to use has to be detected, not assumed.
# Without this hook, selecting a snapshot from the boot menu produces a
# broken read-only boot (most services need writable /var), not a working
# rollback — this is what actually makes snapshot-booting useful.
MKINITCPIO_CONF=/etc/mkinitcpio.conf
CURRENT_HOOKS_LINE=$(grep -E '^HOOKS=' "$MKINITCPIO_CONF" || true)

if echo "$CURRENT_HOOKS_LINE" | grep -qw systemd; then
    OVERLAY_HOOK="sd-btrfs-overlayfs"
elif echo "$CURRENT_HOOKS_LINE" | grep -qw udev; then
    OVERLAY_HOOK="btrfs-overlayfs"
else
    OVERLAY_HOOK=""
    warn "Could not determine whether mkinitcpio uses the 'systemd' or 'udev'"
    warn "hook set from HOOKS=(...) in $MKINITCPIO_CONF."
    warn "Skipping automatic overlay hook insertion — add 'btrfs-overlayfs'"
    warn "(udev-based) or 'sd-btrfs-overlayfs' (systemd-based) manually, after"
    warn "the 'filesystems' hook, then re-run 'mkinitcpio -P'."
fi

if [ -n "$OVERLAY_HOOK" ]; then
    if echo "$CURRENT_HOOKS_LINE" | grep -qw "$OVERLAY_HOOK"; then
        log "$OVERLAY_HOOK already present in HOOKS, skipping"
    else
        log "Adding $OVERLAY_HOOK to HOOKS (after 'filesystems')..."
        cp -a "$MKINITCPIO_CONF" "${MKINITCPIO_CONF}.$(date +%Y%m%d-%H%M%S).bak"
        sed -i -E "/^HOOKS=/ s/(\bfilesystems\b)/\1 ${OVERLAY_HOOK}/" "$MKINITCPIO_CONF"
        if ! grep -E '^HOOKS=' "$MKINITCPIO_CONF" | grep -qw "$OVERLAY_HOOK"; then
            warn "Automatic insertion did not appear to work (no 'filesystems'"
            warn "hook found, or HOOKS=(...) spans multiple lines). Add"
            warn "'$OVERLAY_HOOK' manually after 'filesystems' in $MKINITCPIO_CONF,"
            warn "then re-run 'mkinitcpio -P'."
        fi
    fi

    if [ "$OVERLAY_HOOK" = "sd-btrfs-overlayfs" ]; then
        # Known gotcha (confirmed via limine-snapper-sync's own issue tracker):
        # sd-btrfs-overlayfs's overlayfs-setup.service fails with
        # "No such file or directory" unless these binaries are explicitly
        # listed, since the systemd-based initramfs doesn't include them by
        # default the way the udev-based one implicitly does.
        for bin in env mktemp mkdir rmdir; do
            if grep -E '^BINARIES=' "$MKINITCPIO_CONF" | grep -qw "$bin"; then
                continue
            fi
            log "Adding required binary '$bin' to BINARIES (needed by sd-btrfs-overlayfs)..."
            if grep -q '^BINARIES=' "$MKINITCPIO_CONF"; then
                sed -i -E "/^BINARIES=/ s/\)/ ${bin})/" "$MKINITCPIO_CONF"
            else
                echo "BINARIES=(${bin})" >> "$MKINITCPIO_CONF"
            fi
        done
    fi
fi

# --- /etc/default/limine ---
ESP_PATH=$(findmnt -no TARGET /boot/efi 2>/dev/null || true)
if [ -z "$ESP_PATH" ]; then
    ESP_PATH=/boot
fi
log "Detected ESP path: $ESP_PATH"

deploy_file /etc/default/limine "ESP_PATH=$ESP_PATH"

# --- Regenerate initramfs so limine-mkinitcpio-hook takes effect ---
log "Regenerating initramfs..."
mkinitcpio -P

# --- Locate limine.conf, then check for (or insert) the snapshot marker ---
# limine-snapper-sync injects generated snapshot entries at a marker line
# (//Snapshots or /Snapshots) placed inside the boot entry block you want
# them to appear under. If one's already there (e.g. included by whatever
# generated your limine.conf), we leave it alone. If not, we insert one
# using a conservative heuristic: find the FIRST top-level boot entry
# block (a line starting at column 0 with "/", Limine's entry-name syntax)
# and add the marker as the last indented line of that block, before the
# next top-level entry or end of file. This assumes your first entry is
# the one you want snapshots under (typically the default/primary kernel
# entry) — if that's wrong for your setup, edit limine.conf manually
# afterward; the marker line can simply be moved.
LIMINE_CONF=""
for candidate in /boot/limine.conf /boot/EFI/limine/limine.conf /boot/efi/limine.conf; do
    if [ -f "$candidate" ]; then
        LIMINE_CONF="$candidate"
        break
    fi
done

if [ -z "$LIMINE_CONF" ]; then
    warn "Could not locate limine.conf in any of the common paths."
    warn "You'll need to locate it manually and add a //Snapshots marker line"
    warn "(indented, inside the boot entry block you want snapshots to appear"
    warn "under) for limine-snapper-sync to inject entries into."
elif grep -qE '^[[:space:]]*//?[Ss]napshots[[:space:]]*$' "$LIMINE_CONF"; then
    log "Snapshot marker already present in $LIMINE_CONF."
else
    log "No snapshot marker found in $LIMINE_CONF — inserting one automatically."
    backup="${LIMINE_CONF}.$(date +%Y%m%d-%H%M%S).bak"
    cp -a "$LIMINE_CONF" "$backup"
    log "Backed up $LIMINE_CONF to $backup first."

    awk '
        /^\/[^\/]/ {
            if (in_entry && !inserted) {
                print "    //Snapshots"
                inserted = 1
            }
            in_entry = 1
            print
            next
        }
        { print }
        END {
            if (in_entry && !inserted) {
                print "    //Snapshots"
            }
        }
    ' "$LIMINE_CONF" > "${LIMINE_CONF}.tmp"

    if grep -qE '^[[:space:]]*//?[Ss]napshots[[:space:]]*$' "${LIMINE_CONF}.tmp"; then
        mv "${LIMINE_CONF}.tmp" "$LIMINE_CONF"
        log "Inserted //Snapshots marker into $LIMINE_CONF (under the first boot entry found)."
        log "If that's the wrong entry for your setup, just move the line manually."
    else
        rm -f "${LIMINE_CONF}.tmp"
        warn "Could not confidently locate a boot entry block to insert a marker into."
        warn "$LIMINE_CONF was left unmodified (backup at $backup is identical, safe to remove)."
        warn "Add a line reading exactly '//Snapshots', indented inside the boot entry"
        warn "block you want snapshots to appear under, then re-run 'limine-snapper-sync'."
    fi
fi

# --- Run limine-snapper-sync once, then enable the service ---
log "Running limine-snapper-sync..."
limine-snapper-sync

log "Enabling limine-snapper-sync.service..."
systemctl enable --now limine-snapper-sync.service

echo
log "Done."