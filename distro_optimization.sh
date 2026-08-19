#!/usr/bin/env bash
#
# provision.sh — distro-agnostic post-install provisioning script
#
# Steals the good ideas from Nobara/Bazzite/CachyOS/Clear Linux/BlendOS
# and applies them on top of whatever distro you already installed
# (Arch, Fedora, openSUSE Tumbleweed, or Debian/Ubuntu/Mint), rather
# than shipping as its own distro or image.
#
# Design goals:
#   - Never touch partitioning. Assumes you already installed the base
#     distro yourself (BTRFS or not — we detect and adapt).
#   - Idempotent where possible: safe to re-run.
#   - Every module is a standalone function you can comment out or
#     skip individually — nothing here is all-or-nothing.
#   - Fails loudly and stops rather than silently skipping a step,
#     UNLESS the step is explicitly optional for this system
#     (e.g. Snapper on a non-BTRFS root).

set -euo pipefail

# ---------------------------------------------------------------------------
# Globals / config
# ---------------------------------------------------------------------------

SCRIPT_NAME="$(basename "$0")"
LOG_FILE="/var/log/provision.log"
DRY_RUN="${DRY_RUN:-0}"          # set DRY_RUN=1 to print actions without running them

# Populated by detect_* functions below
DISTRO_ID=""            # raw ID from /etc/os-release, e.g. "fedora", "arch", "linuxmint"
DISTRO_ID_LIKE=""       # raw ID_LIKE from /etc/os-release, e.g. "ubuntu debian"
DISTRO_FAMILY=""        # normalized bucket: arch | fedora | opensuse | debian
CPU_VENDOR=""           # intel | amd | unknown
CPU_MICROARCH_LEVEL=""  # v1 | v2 | v3 | v4 (x86-64 psABI level, x86_64 only)
ROOT_FS=""              # filesystem type of / (btrfs, ext4, xfs, ...)

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------

log_info()  { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*" | tee -a "$LOG_FILE"; }
log_warn()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*" | tee -a "$LOG_FILE"; }
log_error() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" | tee -a "$LOG_FILE" >&2; }
log_skip()  { printf '\033[1;90m[SKIP]\033[0m  %s\n' "$*" | tee -a "$LOG_FILE"; }

# Run a command, or just print it if DRY_RUN=1
run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    log_info "DRY RUN: $*"
  else
    "$@"
  fi
}

require_root() {
  if [[ "$EUID" -ne 0 ]]; then
    log_error "This script must be run as root (it installs packages and edits system config)."
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Detection
# ---------------------------------------------------------------------------

detect_distro_family() {
  if [[ ! -r /etc/os-release ]]; then
    log_error "/etc/os-release not found — cannot detect distro. Aborting."
    exit 1
  fi

  # shellcheck disable=SC1091
  source /etc/os-release
  DISTRO_ID="${ID:-unknown}"
  DISTRO_ID_LIKE="${ID_LIKE:-}"

  case "$DISTRO_ID $DISTRO_ID_LIKE" in
    *arch*|*manjaro*|*endeavouros*|*cachyos*|*garuda*)
      DISTRO_FAMILY="arch" ;;
    *fedora*)
      DISTRO_FAMILY="fedora" ;;
    *opensuse*|*suse*)
      DISTRO_FAMILY="opensuse" ;;
    *debian*|*ubuntu*|*mint*)
      DISTRO_FAMILY="debian" ;;
    *)
      log_error "Unrecognized/unsupported distro (ID=$DISTRO_ID, ID_LIKE=$DISTRO_ID_LIKE)."
      log_error "Supported families: arch, fedora, opensuse, debian(-derivatives)."
      exit 1
      ;;
  esac

  log_info "Detected distro: ID=$DISTRO_ID ID_LIKE=$DISTRO_ID_LIKE -> family=$DISTRO_FAMILY"
}

detect_cpu_vendor() {
  local vendor
  vendor="$(lscpu | awk -F: '/Vendor ID:/ {gsub(/^[ \t]+/, "", $2); print $2}')"

  case "$vendor" in
    GenuineIntel) CPU_VENDOR="intel" ;;
    AuthenticAMD) CPU_VENDOR="amd" ;;
    *)
      CPU_VENDOR="unknown"
      log_warn "Unrecognized CPU vendor '$vendor' — power tuning module will be skipped."
      ;;
  esac

  log_info "Detected CPU vendor: $CPU_VENDOR"
}

detect_cpu_microarch_level() {
  # Ask the dynamic linker which x86-64 psABI levels this CPU+OS combo
  # supports. More authoritative than hand-parsing lscpu flags.
  # Only meaningful on x86_64; skip cleanly on other architectures.
  if [[ "$(uname -m)" != "x86_64" ]]; then
    CPU_MICROARCH_LEVEL="n/a"
    log_warn "Non-x86_64 architecture detected — microarch-level kernel/package selection will be skipped."
    return
  fi

  local supported
  supported="$(/lib64/ld-linux-x86-64.so.2 --help 2>/dev/null | grep -oE 'x86-64-v[0-9]' | sort -V | tail -n1)"

  if [[ -z "$supported" ]]; then
    CPU_MICROARCH_LEVEL="v1"
    log_warn "Could not determine microarch level, defaulting to v1 (baseline)."
  else
    CPU_MICROARCH_LEVEL="${supported##*-}"   # e.g. "x86-64-v3" -> "v3"
  fi

  log_info "Detected CPU microarch level: $CPU_MICROARCH_LEVEL"
}

detect_root_filesystem() {
  ROOT_FS="$(findmnt -no FSTYPE /)"
  log_info "Detected root filesystem: $ROOT_FS"
}

run_all_detection() {
  detect_distro_family
  detect_cpu_vendor
  detect_cpu_microarch_level
  detect_root_filesystem
}

# ---------------------------------------------------------------------------
# Modules (stubs — filled in one at a time)
# ---------------------------------------------------------------------------

module_nonfree_repos() {
  log_info "== Module: nonfree/third-party repos (RPM Fusion or equivalent) =="
  # TODO: branch on $DISTRO_FAMILY
  #   arch      -> nothing needed, AUR/multilib is opt-in via pacman.conf edit
  #   fedora    -> enable RPM Fusion free + nonfree
  #   opensuse  -> add Packman repo
  #   debian    -> enable contrib/non-free(-firmware) + optionally add a
  #                third-party PPA/repo for anything Mint doesn't ship
  log_skip "not implemented yet"
}

module_broadcom_wifi() {
  log_info "== Module: Broadcom wl/brcmfmac driver + suspend/resume fix =="
  # TODO:
  #   1. detect Broadcom chip (lspci | grep -i broadcom)
  #   2. install correct driver package per $DISTRO_FAMILY
  #   3. install systemd sleep hook to unload/reload the module around suspend
  log_skip "not implemented yet"
}

module_kernel() {
  log_info "== Module: performance kernel (BORE scheduler) =="
  # TODO: branch on $DISTRO_FAMILY + $CPU_MICROARCH_LEVEL
  #   arch/fedora/opensuse -> CachyOS kernel (native repo / COPR / OBS)
  #   debian                -> Xanmod kernel (official APT repo)
  log_skip "not implemented yet"
}

module_power_tuning() {
  log_info "== Module: power management tuning (Clear Linux-inspired) =="
  # TODO:
  #   common   -> thermald, tuned (+profile), power-profiles-daemon, powertop --auto-tune
  #   intel    -> confirm intel_pstate active
  #   amd      -> confirm amd_pstate active (active mode), install ryzenadj + corectrl
  log_skip "not implemented yet"
}

module_containers() {
  log_info "== Module: distrobox / podman / docker / waydroid =="
  # TODO: install per $DISTRO_FAMILY, enable podman.socket, set up waydroid init
  log_skip "not implemented yet"
}

module_gaming_stack() {
  log_info "== Module: gaming stack (Bottles, GE-Proton, Proton-CachyOS, GameMode, MangoHud) =="
  # TODO:
  #   - install Bottles (flatpak likely most portable choice), preconfigure a Wine runner
  #   - install ProtonUp-Qt, use it (or its CLI equivalent) to fetch GE-Proton + Proton-CachyOS
  #   - install gamemode per $DISTRO_FAMILY
  #   - install mangohud (nice-to-have)
  log_skip "not implemented yet"
}

module_snapper() {
  log_info "== Module: Snapper + BTRFS snapshots =="
  if [[ "$ROOT_FS" != "btrfs" ]]; then
    log_skip "root filesystem is '$ROOT_FS', not btrfs — skipping Snapper setup."
    return
  fi
  # TODO: install snapper, configure root config, enable pre/post pacman|dnf|zypper hooks
  log_skip "not implemented yet (btrfs detected, ready to configure)"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"

  require_root
  run_all_detection

  log_info "---- Plan ----"
  log_info "Distro family:   $DISTRO_FAMILY"
  log_info "CPU vendor:      $CPU_VENDOR"
  log_info "Microarch level: $CPU_MICROARCH_LEVEL"
  log_info "Root filesystem: $ROOT_FS"
  log_info "--------------"

  module_nonfree_repos
  module_broadcom_wifi
  module_kernel
  module_power_tuning
  module_containers
  module_gaming_stack
  module_snapper

  log_info "Done. Review $LOG_FILE for a full run log."
}

main "$@"