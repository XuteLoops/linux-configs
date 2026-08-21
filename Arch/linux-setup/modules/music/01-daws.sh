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

    # One shared bottle for both DAWs (rather than one each) — this is
    # what lets a single yabridge/VST3 config actually work across both,
    # instead of Bottles and yabridge never being pointed at each other.
    if bottle_exists "$MUSIC_BOTTLE_NAME"; then
        log_ok "Bottle '$MUSIC_BOTTLE_NAME' already exists — skipping creation."
    else
        log_info "Creating '$MUSIC_BOTTLE_NAME' bottle (runner: $MUSIC_BOTTLE_RUNNER)..."
        if bottles_cli new \
            --bottle-name "$MUSIC_BOTTLE_NAME" \
            --environment application \
            --arch win64 \
            --runner "$MUSIC_BOTTLE_RUNNER"
        then
            log_ok "Bottle '$MUSIC_BOTTLE_NAME' created."
        else
            log_warn "Bottle creation failed — the runner '$MUSIC_BOTTLE_RUNNER'"
            log_warn "may not be installed in Bottles yet. Open Bottles, let it"
            log_warn "download that runner (or pick another), then re-run this module."
        fi
    fi

    log_info "Remaining manual steps (not automatable — need your licensed installers):"
    log_info "  In Bottles, open '$MUSIC_BOTTLE_NAME' and run the Ableton and"
    log_info "  FL Studio installers into it (same bottle for both)."
    log_info "  For FL Studio specifically: enable the 'allfonts' dependency"
    log_info "  and enable DXVK + VKD3D from the bottle's dependencies list."
}

install_wineasio() {
    log_info "Building WineASIO (needed for Ableton/FL Studio audio via Bottles)..."

    # wineasio's build needs Wine's own dev headers (objbase.h,
    # windef.h, etc under /usr/include/wine) — these ship with the wine
    # package itself, not with base-devel/git. Missing this caused a
    # real build failure (objbase.h: No such file or directory).
    pkg_install --needed base-devel git wine

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

    # Register it against the actual bottle we created above, rather than
    # leaving this as a fully manual step — this is the piece that
    # actually makes Bottles + WineASIO talk to each other.
    local prefix
    prefix="$(find_bottle_prefix "$MUSIC_BOTTLE_NAME")"

    if [[ -z "$prefix" ]]; then
        log_warn "Could not locate '$MUSIC_BOTTLE_NAME' bottle's on-disk prefix —"
        log_warn "register WineASIO manually once you know the path:"
        log_warn "  export WINEPREFIX=<bottle path>"
        log_warn "  $build_dir/wineasio/wineasio-register"
        log_warn "  cp $build_dir/wineasio/build64/wineasio.dll.so \\"
        log_warn "     \$WINEPREFIX/drive_c/windows/system32/wineasio.dll"
        return 1
    fi

    log_info "Found bottle prefix: $prefix"
    # WINEDLLOVERRIDES=mscoree=d disables Wine's .NET (Mono) integration
    # for this call specifically — wineasio-register is a native tool and
    # doesn't need it, and without this Wine pops up a blocking "install
    # Mono?" dialog on first boot of a prefix, which would hang here in
    # an unattended run.
    #
    # Using run_as_user_env rather than `VAR=val run_as_user` because sudo
    # resets the environment by default — WINEPREFIX would silently NOT
    # reach the actual command otherwise, and this would end up
    # registering wineasio against the wrong (default) prefix.
    run_as_user_env WINEPREFIX="$prefix" WINEDLLOVERRIDES="mscoree=d" -- \
        "$build_dir/wineasio/wineasio-register" \
        || log_warn "wineasio-register failed — the bottle's runner may need" \
                     "to be set up/launched at least once first (Bottles" \
                     "initializes the prefix lazily on first run)."

    run_as_user cp "$build_dir/wineasio/build64/wineasio.dll.so" \
        "$prefix/drive_c/windows/system32/wineasio.dll" \
        && log_ok "WineASIO registered against '$MUSIC_BOTTLE_NAME'." \
        || log_warn "Copy step failed — check $prefix/drive_c/windows/system32 exists."
}

install_native_daws
setup_bottles_foundation
install_wineasio