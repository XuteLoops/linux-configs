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
    # Limine's own recommended approach: a single shared /etc/kernel/cmdline
    # file that most initramfs tools (and Limine itself) read directly —
    # no per-bootloader config regeneration needed.
    local cmdfile="/etc/kernel/cmdline"
    local p line
    [[ -f "$cmdfile" ]] || { touch "$cmdfile"; }
    backup_file "$cmdfile"
    line=$(cat "$cmdfile")
    for p in "$@"; do
        local key="${p%%=*}"
        line=$(echo "$line" | sed -E "s/(^| )${key}=[^ ]*//g" | xargs)
        line="${line:+$line }${p}"
    done
    echo "$line" > "$cmdfile"
    log_success "Limine: added kernel param(s): $* to $cmdfile"
    log_warn "If your Limine setup doesn't read /etc/kernel/cmdline, add manually to limine.conf's cmdline: line."
}
