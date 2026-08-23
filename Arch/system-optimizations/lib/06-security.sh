#!/usr/bin/env bash
# 06-security.sh
#
# Included:
#   - AppArmor + kernel param
#   - PAM enforced delay after failed login (pam_faildelay) — NO lockout
#     counter, by explicit decision.
# Excluded:
#   - hardened_malloc — documented to break Xorg on desktop systems via
#     /etc/ld.so.preload; skipped per the "don't risk breaking the system"
#     condition.

install_apparmor() {
    pkg_install apparmor
    enable_service apparmor.service
    add_kernel_param "apparmor=1" "security=apparmor"
}

configure_login_delay() {
    local pam_file="/etc/pam.d/system-login"
    [[ -f "$pam_file" ]] || { log_warn "$pam_file not found — skipping PAM delay config"; return 0; }

    if grep -q 'pam_faildelay.so' "$pam_file"; then
        log_skip "pam_faildelay already configured in $pam_file"
        return 0
    fi

    backup_file "$pam_file"
    # 3-second delay after a failed login attempt. No pam_faillock / lockout
    # counter is added here — enforced delay only, per decision.
    sed -i '/^auth.*pam_unix.so/i auth       optional     pam_faildelay.so delay=3000000' "$pam_file"
    log_success "Configured 3s enforced delay after failed login (no lockout) in $pam_file"
}
