# system-optimizations

Modular post-install customization script for a fresh Arch Linux install.
Auto-detects hardware/environment (CPU vendor, GPU vendor, bootloader,
root filesystem, initramfs style) and configures accordingly — meant to
run unmodified across different machines.

## Usage

```bash
sudo ./install.sh                        # run everything
sudo ./install.sh --list                 # list task names
sudo ./install.sh --only kernel,gpu       # run specific tasks only
sudo ./install.sh --skip security,swap    # run everything except these
```

Reboot after running — kernel, bootloader, and group-membership changes
need a fresh boot to take effect. Log: `/var/log/system-optimizations.log`.

## Module map

| File | Task name | What it does |
|---|---|---|
| `00-utils.sh` | — | Shared logging/package/file-editing helpers |
| `01-detect.sh` | — | Detects CPU vendor, march tier, GPU vendor(s), bootloader, root fs, initramfs style |
| `02-bootloader-helper.sh` | — | `add_kernel_param()` — works across GRUB / systemd-boot / Limine |
| `03-aur-helper.sh` | `aur-helper` | Installs `paru` if no AUR helper exists |
| `13-reflector.sh` | `reflector` | reflector — auto-detects country from system locale, `--latest 20 --protocol https --sort rate`, enables reflector.service (runs on boot) |
| `04-compiler-flags.sh` | `compiler-flags` | Global CFLAGS/CXXFLAGS/MAKEFLAGS in makepkg.conf, `Architecture` directive, ALHP repo, linux-headers |
| `05-kernel.sh` | `kernel` | linux-cachyos, `preempt=full`, conditional `libahci.ignore_sss=1` |
| `06-security.sh` | `security` | AppArmor, PAM enforced login delay (no lockout) |
| `07-audio.sh` | `audio` | rtkit, audio group, PipeWire latency config |
| `08-pacman-config.sh` | `pacman-config` | ParallelDownloads, compression threads, DownloadUser, pacdiff, paccache, arch-manwarn/update, backups |
| `09-gpu.sh` | `gpu` | AMD/Nvidia/Intel driver stacks, only if discrete GPU detected |
| `10-swap-hibernate.sh` | `swap` | Btrfs/ext4-aware swapfile creation + hibernate config |
| `11-utilities.sh` | `utilities` | preload, linux-firmware, cronie, fwupd, fonts |
| `12-misc.sh` | `misc` | vim→nvim alias |

## Key decisions baked into this script (from the planning conversation)

**Compiler/build flags:** `-O3 -march=native -flto=auto -pipe -fno-plt`,
`CXXFLAGS=$CFLAGS`, `MAKEFLAGS="-j$(nproc)"`. Default `ld` and `make` are
kept — **mold and ninja were explicitly evaluated and rejected**: mold only
speeds up linking (doesn't change binary runtime performance) and Arch's
own devtools team found it breaks kernel builds (no linker-script support)
and some Go builds; ninja can't read Makefiles, so it's not a true
system-wide replacement for `make`.

**`Architecture` directive:** auto-detects microarch tier (from
`01-detect.sh`'s `MARCH_LEVEL`) and sets `Architecture = x86_64_v3 x86_64`
(specific tier first, baseline as fallback) in `/etc/pacman.conf`. Note:
this is separate from ALHP working — ALHP packages are still tagged
plain `x86_64` and rely on repo *ordering* instead (see below), so this
setting is forward-compatible for any repo that does tag packages at
the microarch level, rather than something ALHP itself needs.

**ALHP repo ordering (fixed):** the ALHP repo blocks are inserted *above*
`[core]`/`[extra]` in pacman.conf, not appended to the end. Pacman
resolves same-named packages by whichever repo is listed first — an
earlier version of this script appended to the end of the file, which
would have silently put stock repos ahead of the optimized ones,
defeating the entire point of adding ALHP. Confirmed this coexists with
(doesn't replace) standard repos: packages ALHP doesn't build fall
through to `[core]`/`[extra]` normally, since only same-named packages
are shadowed. `Usage = Sync Install Upgrade` is set on the ALHP sections
per their own README, to avoid duplicate entries in `pacman -Ss` search
results without changing that fallback behavior.

**ALHP is not Intel-specific** — the x86-64-v2/v3/v4 levels it targets are
vendor-neutral psABI standards (AMD reached x86-64-v3 with Excavator in
2015, the same tier Intel reached with Haswell in 2013). `MARCH_LEVEL`
detection in `01-detect.sh` reads CPU feature flags via `ld.so --help`,
not vendor ID, so it was already correct for both AMD and Intel.

**hardened_malloc:** evaluated and **excluded** — documented to break
Xorg on desktop systems via `/etc/ld.so.preload`, which conflicts with the
"don't risk breaking the system" condition it was gated on.

**PAM:** enforced delay after failed login only — **no lockout counter**.

**paccache:** default `-r` only (keep last 3 versions of installed
packages). Deliberately **not** running `-ruk0` (which would purge all
cached versions of uninstalled packages) — keeping a few around covers
accidental-uninstall rollback.

**Swap:** a **swapfile**, not a partition — creating a new partition on an
already-partitioned disk requires resizing/free space that can't be safely
automated across arbitrary machines. Filesystem-aware creation (Btrfs vs.
ext4) since Btrfs's CoW behavior can silently invalidate a plain
fallocate'd swapfile's resume offset. Only proceeds if the swapfile would
leave ≥20% of *current* free space still free afterward.

**Excluded on purpose:** namcap, lostfiles (blocked on a separate,
unresolved systemd live-reload bug), booster (kept out of this
redistributable script — noted for a separate personal-use script),
ProtonPlus/ProtonUp-Qt (neither wanted), mold, ninja.

**reflector:** country is auto-detected from the system locale (e.g.
`en_US.UTF-8` → `US`) — the same territory code reflector's `--country`
flag accepts directly, no separate geo-lookup needed. Falls back to no
`--country` filter (worldwide mirror pool) if the locale has no territory
(e.g. `C.UTF-8`). `reflector.service` is enabled (not `reflector.timer`) so
it runs on every boot, per request — ArchWiki notes enabling both is
redundant.

## Requirements assumed

- Vanilla Arch install (busybox-based mkinitcpio initramfs by default —
  the `resume` hook is added explicitly rather than assumed automatic)
- One of GRUB / systemd-boot / Limine as the bootloader
- Root or ext4/Btrfs filesystem (other filesystems fall through to the
  conventional swapfile path, untested)

## Known gaps / things to verify on real hardware before trusting fully

- The AMD "discrete GPU" detection heuristic (looking for a "3D
  controller" PCI class) hasn't been validated against a real
  APU+dGPU hybrid system — worth confirming on your actual hardware.
- PipeWire latency values in `07-audio.sh` are reasonable defaults, not
  tuned to any specific interface — adjust `quantum`/`min-quantum` to taste.
- CachyOS repo bootstrap in `05-kernel.sh` shells out to their install
  script; if their hosting/script changes, this step may need updating.
