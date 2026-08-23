#!/usr/bin/env bash
# 03-aur-helper.sh — ensures a WORKING AUR helper is available (needed
# for: preload, arch-manwarn, arch-update, and the ALHP-related AUR
# tooling). Sets global AUR_HELPER to the binary name to use.
#
# Builds plain `paru` from source rather than `paru-bin` (the prebuilt
# binary version). paru-bin is compiled upstream against whatever
# libalpm version existed at build time — if that drifts out of sync
# with the local system's pacman/libalpm (e.g. after any pacman
# upgrade), it breaks with a "cannot open shared object file" error at
# runtime. This happened for real during this project's own development.
# Building from source instead compiles against whatever libalpm is
# actually on the machine right now, so it can't go stale this way.
#
# Also verifies an existing AUR helper actually RUNS (not just that the
# binary exists) before trusting it — a present-but-broken binary (same
# ABI-mismatch failure mode) would otherwise go undetected until the
# first aur_install() call fails deep into a later task.

setup_aur_helper() {
    if _working_aur_helper yay; then
        AUR_HELPER="yay"
        log_skip "AUR helper already present and working: yay"
        return 0
    fi
    if _working_aur_helper paru; then
        AUR_HELPER="paru"
        log_skip "AUR helper already present and working: paru"
        return 0
    fi

    if command -v paru &>/dev/null; then
        log_warn "paru binary exists but is broken (failed --version check) — rebuilding from source."
    else
        log_info "No AUR helper found — building paru from source."
    fi
    _build_paru_from_source
}

_working_aur_helper() {
    local bin="$1"
    command -v "$bin" &>/dev/null && "$bin" --version &>/dev/null
}

_build_paru_from_source() {
    pkg_install base-devel git

    local build_dir
    build_dir=$(mktemp -d)
    local user
    user=$(target_user)

    # Build must happen as a non-root user; makepkg refuses to run as root.
    chown -R "$user:$user" "$build_dir"
    sudo -u "$user" git clone --depth=1 https://aur.archlinux.org/paru.git "$build_dir/paru" \
        || die "Failed to clone paru from AUR"
    (
        cd "$build_dir/paru" \
            && sudo -u "$user" makepkg -si --noconfirm
    ) || die "Failed to build/install paru"

    rm -rf "$build_dir"

    _working_aur_helper paru || die "paru was built but still fails to run — check the build output above manually."
    AUR_HELPER="paru"
    log_success "Installed AUR helper: paru (built from source)"
}