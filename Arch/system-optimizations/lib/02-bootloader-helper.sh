#!/usr/bin/env bash
# 02-bootloader-helper.sh — add_kernel_param() works across all three
# bootloaders this script supports, using the BOOTLOADER global from
# 01-detect.sh. Must be sourced after 01-detect.sh.

# add_kernel_param "resume=UUID=xxxx" "resume_offset=1234"
add_kernel_param() {
    local params=("$@")
    case "$BOOTLOADER" in
        grub)
            _grub_add_param "${params[@]}"
            ;;
        systemd-boot)
            _sdboot_add_param "${params[@]}"
            ;;
        limine)
            _limine_add_param "${params[@]}"
            ;;
        *)
            log_warn "Unknown bootloader — could not add kernel param(s): ${params[*]}"
            log_warn "Add manually: ${params[*]}"
            return 1
            ;;
    esac
}

_grub_add_param() {
    local p line
    backup_file /etc/default/grub
    line=$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub | sed 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"$/\1/')
    for p in "$@"; do
        local key="${p%%=*}"
        # strip any existing instance of this key first (avoid duplicates)
        line=$(echo "$line" | sed -E "s/(^| )${key}=[^ ]*//g" | xargs)
        line="${line:+$line }${p}"
    done
    sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${line}\"|" /etc/default/grub
    grub-mkconfig -o /boot/grub/grub.cfg \
        && log_success "GRUB: added kernel param(s): $* (grub.cfg regenerated)" \
        || log_error "grub-mkconfig failed"
}

_sdboot_add_param() {
    local entry p
    shopt -s nullglob
    for entry in /boot/loader/entries/*.conf; do
        backup_file "$entry"
        for p in "$@"; do
            local key="${p%%=*}"
            if grep -q "^options .*${key}=" "$entry"; then
                sed -i -E "s/(${key}=)[^ ]*/\1${p#*=}/" "$entry"
            else
                sed -i "s|^\(options .*\)$|\1 ${p}|" "$entry"
            fi
        done
    done
    shopt -u nullglob
    log_success "systemd-boot: added kernel param(s): $* to all boot entries"
}

_limine_add_param() {
    local params=("$@")
    local conf
    conf=$(_find_limine_conf)
    if [[ -z "$conf" ]]; then
        log_warn "Could not locate limine.conf — kernel param(s) not applied: ${params[*]}"
        return 1
    fi

    backup_file "$conf"

    # Directly, structurally edit every kernel entry's cmdline: line in
    # limine.conf itself — rather than only writing /etc/kernel/cmdline
    # and hoping some hook propagates it. Confirmed for real that hoping
    # wasn't good enough: a hook may or may not read that file depending
    # on its own config, so this guarantees the params land correctly
    # regardless. Only the cmdline: line's value is touched — every
    # other line (path, protocol, module_path, blank lines, indentation)
    # is preserved exactly as-is, matching each entry found for EVERY
    # installed kernel, not just one.
    local tmpfile
    tmpfile=$(mktemp)
    local modified=0
    local indent value p key

    while IFS= read -r line; do
        if [[ "$line" =~ ^([[:space:]]*)cmdline:[[:space:]]*(.*)$ ]]; then
            indent="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            for p in "${params[@]}"; do
                key="${p%%=*}"
                value=$(echo "$value" | sed -E "s/(^| )${key}=[^ ]*//g" | xargs)
                value="${value:+$value }${p}"
            done
            printf '%scmdline: %s\n' "$indent" "$value" >> "$tmpfile"
            modified=$((modified + 1))
        else
            printf '%s\n' "$line" >> "$tmpfile"
        fi
    done < "$conf"

    if [[ "$modified" -eq 0 ]]; then
        log_warn "No cmdline: lines found in $conf — kernel param(s) not applied: ${params[*]}"
        rm -f "$tmpfile"
        return 1
    fi

    chmod --reference="$conf" "$tmpfile"
    chown --reference="$conf" "$tmpfile"
    mv "$tmpfile" "$conf"

    local plural="entry"
    [[ "$modified" -gt 1 ]] && plural="entries"
    log_success "Limine: updated cmdline: line in ${modified} boot ${plural} in ${conf} with: ${params[*]}"

    # Also keep /etc/kernel/cmdline in sync as a courtesy — some tools
    # (mkinitcpio, a future hook regeneration) may still read it, and it
    # doesn't hurt to have it match.
    local cmdfile="/etc/kernel/cmdline"
    [[ -f "$cmdfile" ]] || touch "$cmdfile"
    backup_file "$cmdfile"
    local cf_line
    cf_line=$(cat "$cmdfile")
    for p in "${params[@]}"; do
        key="${p%%=*}"
        cf_line=$(echo "$cf_line" | sed -E "s/(^| )${key}=[^ ]*//g" | xargs)
        cf_line="${cf_line:+$cf_line }${p}"
    done
    echo "$cf_line" > "$cmdfile"
}

# Locates the actual limine.conf in use, checking the same paths Limine
# itself checks, in the same priority order.
_find_limine_conf() {
    local candidates=(
        "/boot/limine/limine.conf"
        "/boot/EFI/limine/limine.conf"
        "/boot/EFI/BOOT/limine.conf"
    )
    local c
    for c in "${candidates[@]}"; do
        [[ -f "$c" ]] && { echo "$c"; return 0; }
    done
    # fall back to a glob for less common EFI subdirectory names
    shopt -s nullglob
    local glob_matches=(/boot/EFI/*/limine.conf)
    shopt -u nullglob
    if [[ ${#glob_matches[@]} -gt 0 ]]; then
        echo "${glob_matches[0]}"
        return 0
    fi
    return 1
}

# Ensures new kernels automatically get a limine.conf entry created at
# all (a separate concern from add_kernel_param, which only edits
# entries that already exist). Without this, Arch's Limine setup has NO
# mechanism to pick up new kernel entries — confirmed for real:
# linux-zen installed successfully via pacman but never appeared in the
# boot menu, because no hook package was present to create an entry for
# it in the first place. Only relevant when BOOTLOADER=limine; no-ops
# otherwise. Runs early in the kernel task, before any add_kernel_param
# calls, so those land on top of whatever entries this creates.
setup_limine_autoupdate() {
    [[ "$BOOTLOADER" == "limine" ]] || return 0

    if is_pkg_installed limine-mkinitcpio-hook; then
        log_skip "limine-mkinitcpio-hook already installed"
    else
        aur_install limine-mkinitcpio-hook
    fi

    mkinitcpio -P \
        && log_success "Regenerated initramfs + Limine boot entries — check your boot menu for linux-zen now." \
        || log_warn "mkinitcpio -P failed — check manually."
}