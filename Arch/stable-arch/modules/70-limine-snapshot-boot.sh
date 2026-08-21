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
# What this module does NOT do: edit the actual boot entries inside
# limine.conf. limine-snapper-sync injects generated snapshot entries at
# a marker line (//Snapshots or /Snapshots) placed inside the boot entry
# block you want them to appear under — but which entry that should be,
# and the exact indentation/structure around it, depends on your
# specific limine.conf, which this script doesn't blindly rewrite. If no
# marker is found, this module tells you exactly what to add and where,
# rather than guessing at your config's structure.
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

ensure_pkg_installed() {
    local pkg="$1"
    if pacman -Qi "$pkg" &>/dev/null; then
        log "Already installed: $pkg"
    else
        log "Installing: $pkg"
        pacman -S --needed --noconfirm "$pkg"
    fi
}

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

aur_install limine-mkinitcpio-hook
aur_install limine-snapper-sync

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

# --- Run limine-snapper-sync once, then enable the service ---
log "Running limine-snapper-sync..."
limine-snapper-sync

log "Enabling limine-snapper-sync.service..."
systemctl enable --now limine-snapper-sync.service

# --- Check for the snapshot marker in limine.conf, but don't edit boot entries ---
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
    warn "$LIMINE_CONF was found, but no //Snapshots marker was detected in it."
    warn "This module does not auto-edit your boot entries, since the correct"
    warn "location depends on your specific config. Add a line reading exactly:"
    warn "    //Snapshots"
    warn "indented under the boot entry block you want snapshot entries to"
    warn "appear beneath (e.g. under your main 'Arch Linux' entry), then re-run"
    warn "'limine-snapper-sync' manually to populate it."
fi

echo
log "Done."