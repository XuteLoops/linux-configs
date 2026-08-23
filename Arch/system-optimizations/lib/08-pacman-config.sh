#!/usr/bin/env bash
# 08-pacman-config.sh
#
# Included: ParallelDownloads (conditional on thread count), DownloadUser=alpm,
#   pacman-contrib (pacdiff + paccache), paccache hook (default -r only, NOT
#   -ruk0 — keeps last 3 versions of uninstalled packages too, for rollback
#   safety), arch-manwarn, arch-update, pacman database backup,
#   installed-package list snapshot.
# Excluded: namcap, lostfiles (contingent on unresolved systemd live-reload
#   issue), booster (kept out of the distributable script by design),
#   CompressXZ/CompressZst (removed by request — caused more problems on
#   the target system than the faster package-cache compression was worth).

configure_pacman_conf() {
    local conf="/etc/pacman.conf"
    backup_file "$conf"

    local pd_value=5
    if (( $(nproc) >= 8 )); then
        pd_value=10
    fi
    set_pacman_option "ParallelDownloads" "$pd_value" "$conf"
    log_success "ParallelDownloads = $pd_value (nproc=$(nproc))"

    set_pacman_option "DownloadUser" "alpm" "$conf"
    log_success "DownloadUser = alpm set"
}

install_pacman_contrib() {
    # Provides pacdiff (config-file manager for .pacnew/.pacsave) and paccache.
    pkg_install pacman-contrib
}

setup_paccache_hook() {
    # Default behaviour only: keep the last 3 versions of INSTALLED packages'
    # cached files. Deliberately NOT running `paccache -ruk0` (which would
    # purge all cached versions of uninstalled packages) — keeping a few
    # around is useful in case of an accidental uninstall.
    enable_service paccache.timer 2>/dev/null \
        || log_info "paccache.timer not found as a systemd unit — falling back to a weekly cron-style timer."

    if ! systemctl is-enabled paccache.timer &>/dev/null; then
        cat > /etc/systemd/system/paccache-weekly.timer <<'EOF'
[Unit]
Description=Weekly paccache cleanup (keep last 3 versions of installed packages)

[Timer]
OnCalendar=weekly
Persistent=true

[Install]
WantedBy=timers.target
EOF
        cat > /etc/systemd/system/paccache-weekly.service <<'EOF'
[Unit]
Description=paccache cleanup

[Service]
Type=oneshot
ExecStart=/usr/bin/paccache -r
EOF
        systemctl daemon-reload
        enable_service paccache-weekly.timer
    fi
}

install_arch_manwarn_and_update() {
    aur_install arch-manwarn arch-update
}

setup_pacman_db_backup() {
    local script="/usr/local/bin/pacman-db-backup"
    cat > "$script" <<'EOF'
#!/usr/bin/env bash
# Backs up the pacman local database (installed-package metadata).
set -euo pipefail
dest_dir="/var/backups/pacman"
mkdir -p "$dest_dir"
timestamp=$(date +%Y%m%d)
tar -czf "$dest_dir/pacman-db-${timestamp}.tar.gz" -C /var/lib/pacman local
# Keep the last 8 weekly backups
ls -1t "$dest_dir"/pacman-db-*.tar.gz | tail -n +9 | xargs -r rm --
EOF
    chmod +x "$script"

    cat > /etc/systemd/system/pacman-db-backup.timer <<'EOF'
[Unit]
Description=Weekly pacman database backup

[Timer]
OnCalendar=weekly
Persistent=true

[Install]
WantedBy=timers.target
EOF
    cat > /etc/systemd/system/pacman-db-backup.service <<EOF
[Unit]
Description=Back up pacman local database

[Service]
Type=oneshot
ExecStart=${script}
EOF
    systemctl daemon-reload
    enable_service pacman-db-backup.timer
    log_success "Weekly pacman database backup configured ($script)"
}

setup_installed_pkg_list_snapshot() {
    local script="/usr/local/bin/pacman-pkglist-snapshot"
    cat > "$script" <<'EOF'
#!/usr/bin/env bash
# Snapshots the list of explicitly-installed packages for disaster recovery.
set -euo pipefail
dest="/var/backups/pacman/installed-packages.txt"
mkdir -p "$(dirname "$dest")"
pacman -Qqe > "$dest"
EOF
    chmod +x "$script"

    cat > /etc/systemd/system/pacman-pkglist.timer <<'EOF'
[Unit]
Description=Daily installed-package list snapshot

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF
    cat > /etc/systemd/system/pacman-pkglist.service <<EOF
[Unit]
Description=Snapshot installed package list

[Service]
Type=oneshot
ExecStart=${script}
EOF
    systemctl daemon-reload
    enable_service pacman-pkglist.timer
    log_success "Daily installed-package list snapshot configured ($script)"
}