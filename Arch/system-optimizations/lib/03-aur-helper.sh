#!/usr/bin/env bash
# 03-aur-helper.sh — ensures an AUR helper is available (needed for:
# preload, arch-manwarn, arch-update, and the ALHP-related AUR tooling).
# Sets global AUR_HELPER to the binary name to use.

setup_aur_helper() {
    if command -v yay &>/dev/null; then
        AUR_HELPER="yay"
        log_skip "AUR helper already present: yay"
        return 0
    fi
    if command -v paru &>/dev/null; then
        AUR_HELPER="paru"
        log_skip "AUR helper already present: paru"
        return 0
    fi

    log_info "No AUR helper found — building paru from source."
    pkg_install base-devel git

    local build_dir
    build_dir=$(mktemp -d)
    local user
    user=$(target_user)

    # Build must happen as a non-root user; makepkg refuses to run as root.
    chown -R "$user:$user" "$build_dir"
    sudo -u "$user" git clone --depth=1 https://aur.archlinux.org/paru-bin.git "$build_dir/paru-bin" \
        || die "Failed to clone paru-bin from AUR"
    (
        cd "$build_dir/paru-bin" \
            && sudo -u "$user" makepkg -si --noconfirm
    ) || die "Failed to build/install paru"

    rm -rf "$build_dir"
    AUR_HELPER="paru"
    log_success "Installed AUR helper: paru"
}
