#!/usr/bin/env bash
# 10-swap-hibernate.sh
#
# Uses a SWAPFILE (not a partition) — safer for a redistributable script
# since it doesn't touch partition boundaries on someone else's disk.
#
# Sizing: swapfile = RAM size (1:1, standard hibernate rule of thumb).
# Safety check: only proceeds if, after creating the swapfile, at least
#   20% of the remaining free space on that filesystem would still be free.
# Filesystem-aware creation:
#   - Btrfs: `btrfs filesystem mkswapfile` (handles NOCOW + keeps the
#     physical offset stable — a plain fallocate'd file on Btrfs can have
#     its offset silently invalidated by CoW during normal use).
#   - ext4/other: conventional fallocate + chmod + mkswap.
# Initramfs: vanilla Arch mkinitcpio is busybox-based by default, so the
#   `resume` hook is added explicitly (not assumed to be automatic).

SWAPFILE_PATH="/swap/swapfile"

setup_hibernate_swapfile() {
    if swapon --show=NAME --noheadings | grep -qx "$SWAPFILE_PATH"; then
        log_skip "Swapfile already active at $SWAPFILE_PATH"
        return 0
    fi

    local ram_gb
    ram_gb=$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024 + 1}' /proc/meminfo)  # round up

    if ! _check_free_space_ok "$ram_gb"; then
        log_warn "Not enough free space to create a ${ram_gb}G swapfile while keeping 20% free — skipping hibernate setup."
        return 1
    fi

    mkdir -p "$(dirname "$SWAPFILE_PATH")"

    case "$ROOT_FS" in
        btrfs)
            _create_btrfs_swapfile "$ram_gb"
            ;;
        *)
            _create_conventional_swapfile "$ram_gb"
            ;;
    esac

    append_once "${SWAPFILE_PATH} none swap defaults 0 0" /etc/fstab
    swapon "$SWAPFILE_PATH" || log_warn "swapon failed — check $SWAPFILE_PATH manually"

    _add_resume_hook
    _configure_resume_kernel_param
    mkinitcpio -P && log_success "initramfs regenerated with resume hook"
}

_check_free_space_ok() {
    # Passes only if, after the swapfile is carved out, at least 20% of the
    # CURRENTLY-FREE space (not total disk size) remains free. i.e. the
    # swapfile may not consume more than 80% of current headroom.
    local needed_gb="$1"
    local mountpoint free_kb free_gb after_gb pct_of_current_free
    mountpoint=$(df --output=target "$(dirname "$SWAPFILE_PATH")" | tail -1)
    free_kb=$(df --output=avail -k "$mountpoint" | tail -1)
    free_gb=$(( free_kb / 1024 / 1024 ))

    after_gb=$(( free_gb - needed_gb ))
    if (( after_gb <= 0 )); then
        log_info "Free space check: only ${free_gb}G free, need ${needed_gb}G — fails outright."
        return 1
    fi
    pct_of_current_free=$(( after_gb * 100 / free_gb ))
    log_info "Free space check: ${free_gb}G free now, ${needed_gb}G swapfile requested, ${after_gb}G (${pct_of_current_free}% of current free space) would remain."
    (( pct_of_current_free >= 20 ))
}

_create_btrfs_swapfile() {
    local size_gb="$1"
    btrfs filesystem mkswapfile --size "${size_gb}G" "$SWAPFILE_PATH" \
        || die "btrfs filesystem mkswapfile failed"
    log_success "Created Btrfs-safe swapfile (${size_gb}G) at $SWAPFILE_PATH"
}

_create_conventional_swapfile() {
    local size_gb="$1"
    fallocate -l "${size_gb}G" "$SWAPFILE_PATH" || dd if=/dev/zero of="$SWAPFILE_PATH" bs=1M count=$((size_gb*1024))
    chmod 600 "$SWAPFILE_PATH"
    mkswap "$SWAPFILE_PATH" || die "mkswap failed"
    log_success "Created swapfile (${size_gb}G) at $SWAPFILE_PATH"
}

_add_resume_hook() {
    if [[ "$INITRAMFS_STYLE" == "systemd" ]]; then
        log_skip "systemd-based initramfs — resume is handled automatically, no hook needed"
        return 0
    fi
    local conf="/etc/mkinitcpio.conf"
    if grep -qE '^HOOKS=.*\bresume\b' "$conf"; then
        log_skip "resume hook already present in $conf"
        return 0
    fi
    backup_file "$conf"
    # Insert 'resume' right after 'udev'/'autodetect', before 'filesystems'/'fsck'.
    sed -i -E 's/(HOOKS=\([^)]*\bfilesystems\b)/\ resume\1/; s/  / /' "$conf"
    sed -i -E 's/(HOOKS=\(.*)(filesystems)/\1resume \2/' "$conf"
    log_success "Added 'resume' hook to $conf HOOKS array"
}

_configure_resume_kernel_param() {
    local uuid offset
    uuid=$(findmnt -no UUID "$(dirname "$SWAPFILE_PATH")")

    if [[ "$ROOT_FS" == "btrfs" ]]; then
        offset=$(btrfs inspect-internal map-swapfile -r "$SWAPFILE_PATH" 2>/dev/null)
    else
        offset=$(filefrag -v "$SWAPFILE_PATH" | awk '$1=="0:" {print substr($4, 1, length($4)-2)}')
    fi

    if [[ -z "$uuid" || -z "$offset" ]]; then
        log_warn "Could not determine resume UUID/offset — hibernate kernel param NOT set. Configure manually."
        return 1
    fi

    add_kernel_param "resume=UUID=${uuid}" "resume_offset=${offset}"
}
