#!/usr/bin/env bash
# 03-aur-helper.sh — ensures a WORKING AUR helper is available (needed
# for: preload, arch-manwarn, arch-update, and the ALHP-related AUR
# tooling). Sets global AUR_HELPER to the binary name to use.
#
# Strategy: try paru-bin (prebuilt binary, installs in seconds) first,
# and verify it actually works immediately after install. paru-bin is
# compiled upstream against whatever libalpm version existed at build
# time — if that's drifted from the local system's current libalpm (e.g.
# after a pacman upgrade), it fails at runtime with a "cannot open shared
# object file" error. This happened for real during this project. Rather
# than always paying a multi-minute compile to avoid that risk
# unconditionally, only fall back to building plain `paru` from source
# (compiles against whatever libalpm is actually on the machine right
# now, so it can't go stale) when paru-bin turns out broken.
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
        log_warn "paru binary exists but is broken (failed --version check) — reinstalling."
    fi

    log_info "Trying paru-bin (prebuilt binary, fast) first..."
    if _install_paru_pkg "paru-bin" && _working_aur_helper paru; then
        AUR_HELPER="paru"
        log_success "Installed AUR helper: paru (prebuilt binary)"
        return 0
    fi

    log_warn "paru-bin unavailable or broken (e.g. libalpm ABI mismatch against this system) — building paru from source instead. This compiles locally and will take longer, but can't go stale the same way."
    _install_paru_pkg "paru" \
        || die "Failed to build/install paru from source"

    _working_aur_helper paru \
        || die "paru was built from source but still fails to run — check the build output above manually."
    AUR_HELPER="paru"
    log_success "Installed AUR helper: paru (built from source)"
}

_working_aur_helper() {
    local bin="$1"
    command -v "$bin" &>/dev/null && "$bin" --version &>/dev/null
}

# Clones and installs the given AUR package name (paru-bin or paru).
# Returns non-zero on failure rather than dying, so the caller can decide
# whether to fall back rather than aborting the whole script.
_install_paru_pkg() {
    local pkgname="$1"
    pkg_install base-devel git

    local build_dir
    build_dir=$(mktemp -d)
    local user
    user=$(target_user)

    # Build must happen as a non-root user; makepkg refuses to run as root.
    chown -R "$user:$user" "$build_dir"
    if ! sudo -u "$user" git clone --depth=1 "https://aur.archlinux.org/${pkgname}.git" "$build_dir/${pkgname}"; then
        log_warn "Failed to clone ${pkgname} from AUR"
        rm -rf "$build_dir"
        return 1
    fi

    if ! (cd "$build_dir/${pkgname}" && sudo -u "$user" makepkg -si --noconfirm); then
        log_warn "Failed to build/install ${pkgname}"
        rm -rf "$build_dir"
        return 1
    fi

    rm -rf "$build_dir"
}