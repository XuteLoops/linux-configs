#!/usr/bin/env bash
# 04-compiler-flags.sh — sets global build flags in /etc/makepkg.conf so
# ANY package compiled locally (including AUR builds) picks them up.
#
# Flags decided on:
#   -O3 -march=native -flto=auto -pipe -fno-plt
#   CXXFLAGS = CFLAGS (no separate C++-specific exceptions needed)
#   LDFLAGS: left at distro default (-Wl,-z,now already present, pairs
#            correctly with -fno-plt). No mold (skipped — breakage risk).
#   MAKEFLAGS="-j$(nproc)"
#   make/ninja: left as default `make` (ninja skipped — not a true
#            drop-in replacement for Makefile-based builds).
#
# Also sets up the ALHP repo (matched to detected MARCH_LEVEL) so
# official-repo binary packages ALSO benefit from -march optimization,
# not just locally-built ones.

configure_makepkg_flags() {
    local makepkg_conf="/etc/makepkg.conf"
    [[ -f "$makepkg_conf" ]] || die "$makepkg_conf not found"
    backup_file "$makepkg_conf"

    local cflags='-O3 -march=native -flto=auto -pipe -fno-plt'

    # set_shell_assignment (not set_kv) — required here because stock
    # Arch's makepkg.conf ships CFLAGS as a multi-line value via
    # backslash continuation. set_kv's sed-based single-line replace
    # left orphaned continuation-line fragments behind, corrupting the
    # file's shell syntax (confirmed for real: `source /etc/makepkg.conf`
    # failed with "unexpected EOF while looking for matching `'"` after
    # an earlier version of this function ran). set_shell_assignment
    # removes the ENTIRE old assignment, continuation lines included.
    set_shell_assignment "CFLAGS" "$cflags" "$makepkg_conf"
    set_shell_assignment "CXXFLAGS" '${CFLAGS}' "$makepkg_conf"
    set_shell_assignment "MAKEFLAGS" '-j$(nproc)' "$makepkg_conf"

    log_success "Set CFLAGS/CXXFLAGS/MAKEFLAGS in $makepkg_conf"
    log_info "  CFLAGS=$cflags"
    log_info "  LDFLAGS left at distro default (already includes -Wl,-z,now, pairs with -fno-plt)"
}

install_linux_headers() {
    pkg_install linux-headers
}

set_pacman_architecture() {
    # Multi-value Architecture directive: x86_64 MUST come first.
    #
    # Confirmed directly on pacman.conf(5): pacman sets the $arch variable
    # used in mirrorlist URL construction to the FIRST listed Architecture
    # value, not "whichever makes sense per-repo". Putting the microarch
    # tier first (as an earlier version of this function did) makes $arch
    # resolve to e.g. "x86_64_v3" for EVERY repo sharing the standard
    # mirrorlist — including core/extra/multilib, none of which exist at
    # that path on any real mirror (only plain x86_64 does). That breaks
    # ALL package installation with 404s across every mirror, for every
    # package — a genuinely severe bug, confirmed against a real failure.
    #
    # x86_64 first keeps $arch resolving correctly for the repos that
    # need it, while still listing the microarch tier as a second allowed
    # value — forward-compatible with any repo that DOES tag packages at
    # that level, without breaking anything that doesn't.
    local conf="/etc/pacman.conf"
    if [[ "$MARCH_LEVEL" == "x86-64" ]]; then
        log_skip "Baseline x86-64 CPU — leaving Architecture = auto as-is"
        return 0
    fi
    local arch_tag="${MARCH_LEVEL//-/_}"   # x86-64-v3 -> x86_64_v3
    # set_pacman_option (not set_kv) — same [options]-section risk as
    # ParallelDownloads/CompressXZ/etc: if Architecture is still commented
    # out (a valid fresh-install state), set_kv's fallback would append to
    # EOF and risk landing under whatever repo section is last.
    set_pacman_option "Architecture" "x86_64 ${arch_tag}" "$conf"
    log_success "Set Architecture = x86_64 ${arch_tag} in $conf (x86_64 first — required for correct \$arch mirrorlist substitution)"
}

setup_alhp_repo() {
    if [[ "$MARCH_LEVEL" == "x86-64" ]]; then
        log_warn "CPU only supports baseline x86-64 — ALHP has no repo for this tier, skipping."
        return 0
    fi

    if grep -q '\[core-x86-64' /etc/pacman.conf 2>/dev/null; then
        log_skip "ALHP repo already configured in pacman.conf"
        return 0
    fi

    log_info "Configuring ALHP repo for ${MARCH_LEVEL}..."

    pacman-key --recv-keys 3056513887B78AEB --keyserver keyserver.ubuntu.com \
        || log_warn "Could not fetch ALHP signing key from keyserver — you may need to add it manually."
    # Guarded (was previously a bare, unguarded command — same silent-kill
    # risk under set -e as the bare VAR=$(...) pattern fixed in 01-detect.sh):
    # if the key wasn't fetched above, or lsign fails for any reason, warn
    # and keep going rather than dying here.
    pacman-key --lsign-key 3056513887B78AEB 2>/dev/null \
        || log_warn "Could not locally sign the ALHP key — you may need to run 'pacman-key --lsign-key 3056513887B78AEB' manually."

    # alhp-keyring/alhp-mirrorlist are AUR-only packages (confirmed on
    # ALHP's own README) — must go through the AUR helper, not pkg_install
    # (plain pacman -S can never find them, they don't exist in any
    # official repo). Uses the non-fatal aur_install_optional(): if this
    # fails for any reason, ALHP setup is skipped but the rest of the
    # script continues rather than the whole run dying.
    if ! aur_install_optional alhp-keyring alhp-mirrorlist; then
        log_warn "Skipping ALHP repo setup (alhp-keyring/alhp-mirrorlist install failed)."
        return 0
    fi

    backup_file /etc/pacman.conf

    # CRITICAL: these repo blocks must be inserted ABOVE the existing
    # [core]/[extra] sections, not appended to the end of the file.
    # pacman.conf resolves same-named packages by whichever repo is listed
    # FIRST — appending to the end would put ALHP after stock repos and
    # silently defeat the entire point of adding it.
    #
    # `Usage = Sync Install Upgrade` (per ALHP's own README) keeps `pacman
    # -Ss` search results from showing duplicate entries, without changing
    # fallback behavior — packages ALHP doesn't build still resolve from
    # [core]/[extra] normally, since only same-named packages are shadowed.
    local repo_block="[core-${MARCH_LEVEL}]
Usage = Sync Install Upgrade
Include = /etc/pacman.d/alhp-mirrorlist

[extra-${MARCH_LEVEL}]
Usage = Sync Install Upgrade
Include = /etc/pacman.d/alhp-mirrorlist

"
    if grep -q '^\[core\]' /etc/pacman.conf; then
        # Insert immediately before the first [core] line.
        awk -v block="$repo_block" '
            !inserted && /^\[core\]/ { printf "%s", block; inserted=1 }
            { print }
        ' /etc/pacman.conf > /etc/pacman.conf.new
        mv /etc/pacman.conf.new /etc/pacman.conf
    else
        log_warn "Could not find [core] section to insert ALHP repos before — appending to end instead (verify repo order manually)."
        printf '\n%s' "$repo_block" >> /etc/pacman.conf
    fi

    pacman -Syyu --noconfirm \
        && log_success "ALHP repo (${MARCH_LEVEL}) added above [core]/[extra] and synced" \
        || log_warn "ALHP sync failed — check /etc/pacman.conf and mirrorlist manually"
}