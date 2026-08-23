#!/usr/bin/env bash
# 03-aur-helper.sh — ensures a WORKING AUR helper is available (needed
# for: preload, arch-manwarn, arch-update, and the ALHP-related AUR
# tooling). Sets global AUR_HELPER to the binary name to use.
#
# yay is tried before paru at EVERY tier, per explicit preference:
#   1. yay already installed and working -> use it.
#   2. paru already installed and working -> use it.
#   3. yay-bin (prebuilt).
#   4. paru-bin (prebuilt).
#   5. yay from source (Go — much lighter peak memory during linking
#      than paru's large Rust dependency tree; confirmed for real during
#      this project that building paru from source can be OOM-killed
#      mid-link on a memory-constrained machine — signal 9/SIGKILL).
#   6. paru from source (final resort).
#
# "Working" is checked by actually running the binary (--version), not
# just checking the package/file exists — a present-but-broken binary
# (e.g. linked against a libalpm version that's since changed after a
# pacman upgrade) would otherwise go undetected until the first real
# aur_install() call fails deep into a later task.

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

    log_info "Trying yay-bin (prebuilt, fast) first..."
    if _install_aur_helper_pkg "yay-bin" && _working_aur_helper yay; then
        AUR_HELPER="yay"
        log_success "Installed AUR helper: yay (prebuilt binary)"
        return 0
    fi
    log_warn "yay-bin unavailable or broken — trying paru-bin instead."
    _remove_if_installed "yay-bin"

    if _install_aur_helper_pkg "paru-bin" && _working_aur_helper paru; then
        AUR_HELPER="paru"
        log_success "Installed AUR helper: paru (prebuilt binary)"
        return 0
    fi
    log_warn "paru-bin also unavailable or broken — both prebuilt options failed. Building yay from source (Go — much lighter on memory during linking than paru's Rust dependency tree, less likely to hit an OOM kill on constrained systems)."
    _remove_if_installed "paru-bin"

    if _install_aur_helper_pkg "yay" && _working_aur_helper yay; then
        AUR_HELPER="yay"
        log_success "Installed AUR helper: yay (built from source)"
        return 0
    fi
    log_warn "Building yay from source also failed — falling back to building paru from source as a final resort."

    _install_aur_helper_pkg "paru" \
        || die "All AUR helper install options exhausted (yay-bin, paru-bin, yay from source, paru from source) — cannot proceed. Check the build output above."

    _working_aur_helper paru \
        || die "paru was built from source but still fails to run — check the build output above manually."
    AUR_HELPER="paru"
    log_success "Installed AUR helper: paru (built from source, last resort)"
}

_working_aur_helper() {
    local bin="$1"
    command -v "$bin" &>/dev/null && "$bin" --version &>/dev/null
}

# Removes a package if it's installed, warning (not dying) on failure —
# used to clean up a broken prebuilt attempt before trying the next
# candidate. Required when moving between -bin and source variants of
# the SAME tool (they conflict, same provided binary); done as general
# hygiene otherwise even where not strictly required to avoid a conflict.
_remove_if_installed() {
    local pkgname="$1"
    if is_pkg_installed "$pkgname"; then
        log_info "Removing non-functional ${pkgname}..."
        pacman -R --noconfirm "$pkgname" \
            || log_warn "Failed to remove ${pkgname} — may cause a conflict on the next install attempt."
    fi
}

# Clones and installs the given AUR package name (yay-bin, paru-bin,
# yay, or paru). Returns non-zero on failure rather than dying, so the
# caller can decide whether to fall back rather than aborting the whole
# script.
_install_aur_helper_pkg() {
    local pkgname="$1"
    pkg_install base-devel git

    local user
    user=$(target_user)
    local user_home
    user_home=$(target_home)

    # Build under the user's home directory, NOT /tmp via plain mktemp.
    # /tmp is commonly a size-capped tmpfs (often a fraction of RAM) —
    # confirmed for real during this project: a source build of paru
    # failed with "Disk quota exceeded" partway through compiling large
    # dependencies, because /tmp filled up. Building somewhere on the
    # real disk avoids that entirely.
    local build_root="${user_home}/.cache/system-optimizations-aur-build"
    sudo -u "$user" mkdir -p "$build_root"
    local build_dir
    build_dir=$(sudo -u "$user" mktemp -d "${build_root}/build.XXXXXX")

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