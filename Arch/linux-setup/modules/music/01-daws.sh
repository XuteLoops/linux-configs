#!/usr/bin/env bash
#
# 01-daws.sh — install native Linux DAWs, and set up Bottles as the
# foundation for the Windows-only DAWs (Ableton, FL Studio).
#
# Deliberately does NOT install Ableton/FL Studio themselves — both
# require a licensed installer .exe you already own, which isn't
# something this script can fetch for you. It gets Bottles + the
# recommended runner/settings ready so installing them by hand is a
# short remaining step instead of a research project.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/config/versions.conf"

install_native_daws() {
    log_info "Installing native Linux DAWs..."

    if aur_install bitwig-studio; then
        log_ok "Bitwig Studio installed."
        log_info "If your license covers an older major version, grab the"
        log_info "matching installer from https://www.bitwig.com/previous_releases/"
        log_info "and install that instead — Bitwig's license is version-locked"
        log_info "to whatever your upgrade plan last covered."
    else
        log_warn "Bitwig Studio AUR install failed — check AUR page for updates."
    fi

    if pkg_install reaper; then
        log_ok "REAPER installed."
    else
        log_warn "REAPER install failed — check if 'reaper' is still in the"
        log_warn "official extra repo (it was promoted there from AUR)."
    fi
}

setup_bottles_foundation() {
    log_info "Setting up Bottles for Ableton / FL Studio..."

    if ! command -v flatpak >/dev/null 2>&1; then
        pkg_install flatpak
    fi

    # Flatpak Bottles specifically — not a distro package — since the
    # flatpak build ships extra pieces needed for windows to render
    # correctly on minimal Wayland compositors (confirmed issue with
    # Ableton's main window not mapping without it).
    run_as_user flatpak install -y --noninteractive flathub com.usebottles.bottles

    run_as_user flatpak override --user com.usebottles.bottles --filesystem=home
    run_as_user flatpak override --user com.usebottles.bottles \
        --filesystem=xdg-data/applications
    run_as_user flatpak override --user com.usebottles.bottles \
        --filesystem=/home/"$(target_user)"/.local/share/applications

    log_ok "Bottles installed via flatpak with home/desktop-entry access."
    log_info "Remaining manual steps (not automatable — need your licensed installers):"
    log_info "  Ableton: create a bottle, install runner '$ABLETON_RUNNER',"
    log_info "           run the Ableton installer, then register WineASIO"
    log_info "           against that bottle's WINEPREFIX (see notes)."
    log_info "  FL Studio: create a bottle, install runner '$FL_STUDIO_RUNNER',"
    log_info "             enable the 'allfonts' dependency, enable DXVK + VKD3D,"
    log_info "             then run the FL Studio installer."
}

install_wineasio() {
    log_info "Building WineASIO (needed for Ableton/FL Studio audio via Bottles)..."

    pkg_install --needed base-devel git

    # jack2 and pipewire-jack conflict (both provide 'jack') — installing
    # both in one transaction fails. Modern Arch systems run PipeWire by
    # default, so only add pipewire-jack, and only if neither is already
    # present.
    if ! pkg_installed jack2 && ! pkg_installed pipewire-jack; then
        pkg_install pipewire-jack
    else
        log_ok "JACK support already present ($(pkg_installed jack2 && echo jack2 || echo pipewire-jack)) — skipping."
    fi

    local build_dir
    build_dir="$(run_as_user mktemp -d)"
    run_as_user git clone --recurse-submodules \
        https://github.com/wineasio/wineasio "$build_dir/wineasio"

    (
        cd "$build_dir/wineasio" || exit 1
        run_as_user make 64
    )

    log_ok "WineASIO built at $build_dir/wineasio/build64/wineasio.dll.so"
    log_info "This still needs registering against each bottle's WINEPREFIX:"
    log_info "  export WINEPREFIX=<bottle path from 'bottles-cli info bottles-path'>"
    log_info "  $build_dir/wineasio/wineasio-register"
    log_info "  cp $build_dir/wineasio/build64/wineasio.dll.so \\"
    log_info "     \$WINEPREFIX/drive_c/windows/system32/wineasio.dll"
    log_info "Left as a manual step since WINEPREFIX differs per bottle/per DAW,"
    log_info "and doing this automatically before a bottle exists isn't possible."
}

install_native_daws
setup_bottles_foundation
install_wineasio