#!/usr/bin/env bash
#
# 01-pin-login.sh — set up PIN-based login (Windows Hello style) via PAM.
#
# Works at the PAM layer, so it applies regardless of display manager
# (SDDM, GDM, etc.) since they all defer to PAM for authentication.
#
# NOTE: pam_pinlock is a newer, purpose-built module for exactly this.
# It's less battle-tested than the older pam_pwdfile trick, so this
# script checks the AUR for it and falls back to printing manual
# instructions if it's not found or fails to build, rather than silently
# doing something riskier to your auth stack unattended.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

install_pin_login() {
    require_root
    log_info "Setting up PIN login..."

    if ! aur_install pam_pinlock; then
        log_warn "pam_pinlock not available or failed to build."
        log_warn "Manual fallback: the community-standard approach uses"
        log_warn "pam_pwdfile with a separate short PIN hash. See:"
        log_warn "  https://wiki.archlinux.org/title/PAM"
        log_warn "Skipping automatic PAM edits — this touches login auth"
        log_warn "and should not be configured unattended without the"
        log_warn "actual module confirmed present."
        return 1
    fi

    local target
    target="$(target_user)"

    if command -v pinlock-ctl >/dev/null 2>&1; then
        log_info "Run the following manually to set your PIN (interactive,"
        log_info "not run automatically by this script):"
        log_info "  sudo pinlock-ctl set $target"
    else
        log_warn "pam_pinlock installed but expected CLI tool not found."
        log_warn "Check the package's own docs for how to set a PIN —"
        log_warn "naming may have changed since this script was written."
    fi

    log_ok "PIN login package installed. PIN must be set manually (see above)."
    log_warn "Back up your password login before testing — do not close"
    log_warn "your session until you've confirmed PIN login works."
}

install_pin_login
