#!/usr/bin/env bash
# 13-reflector.sh — installs reflector, auto-detects the system's country
# from the locale setting (the same "read locale" approach used elsewhere
# in this script), and configures /etc/xdg/reflector/reflector.conf with:
#
#   --latest 20 --protocol https --sort rate \
#   --save /etc/pacman.d/mirrorlist --country <detected>
#
# Enables reflector.service (runs on every boot) rather than
# reflector.timer (weekly) — per your request that it run on boot, and per
# ArchWiki's own note that enabling both is redundant.

detect_country_from_locale() {
    # A locale string like "en_US.UTF-8" already carries the ISO 3166-1
    # alpha-2 territory code ("US") — reflector's --country flag accepts
    # alpha-2 codes directly, so no separate lookup table is needed.
    local lang_value=""

    if [[ -f /etc/locale.conf ]]; then
        lang_value=$(grep -m1 '^LANG=' /etc/locale.conf | cut -d= -f2)
    fi
    if [[ -z "$lang_value" ]]; then
        lang_value="${LANG:-}"
    fi

    if [[ "$lang_value" =~ _([A-Za-z]{2})(\.|@|$) ]]; then
        echo "${BASH_REMATCH[1]^^}"
    else
        echo ""
    fi
}

setup_reflector() {
    pkg_install reflector

    local country
    country=$(detect_country_from_locale)

    mkdir -p /etc/xdg/reflector
    local conf="/etc/xdg/reflector/reflector.conf"
    backup_file "$conf"

    if [[ -n "$country" ]]; then
        cat > "$conf" <<EOF
--latest 20
--protocol https
--sort rate
--country ${country}
--save /etc/pacman.d/mirrorlist
EOF
        log_success "reflector.conf written with --country ${country} (detected from system locale)"
    else
        cat > "$conf" <<EOF
--latest 20
--protocol https
--sort rate
--save /etc/pacman.d/mirrorlist
EOF
        log_warn "Could not determine a country from the system locale — reflector.conf written without --country (worldwide mirror pool)."
    fi

    # Service (not timer) per your request — runs on every boot.
    # Note: enabling both reflector.service and reflector.timer is redundant
    # (ArchWiki); this script enables only the service.
    enable_service reflector.service
}
