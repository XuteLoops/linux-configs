# Hardened Pacman Update Pipeline

Idempotent, modular pacman hooks that automatically verify every
transaction (dependency satisfiability + broken-linkage checks) and roll
back via BTRFS snapshots on failure — so a `pacman -Syu` that silently
breaks the system doesn't stay broken unnoticed.

**Verified working on:**

- CachyOS (original build/test environment, including forced-failure
  end-to-end rollback testing)
- Vanilla Arch Linux, fresh install, out of the box

Built for Arch and Arch-based distros generally — anything running pacman
and libalpm should be compatible, though only the two above have been
directly tested.

---

# Structure

```
Arch/
└── stable-arch/
    ├── README.md
    ├── HANDOFF.md
    ├── install-all.sh          # convenience wrapper: runs every module in order
    └── modules/
        ├── 00-aur-helpers.sh
        ├── 10-systemd-inhibit.sh
        ├── 20-verify-transaction.sh
        ├── 30-arch-audit.sh
        ├── 40-reboot-required.sh
        ├── 50-paccache.sh
        └── 60-community-hooks.sh
```

Every module is **fully standalone** — a single `curl` + `bash` of one
file is enough to run it, with no dependency on any other file in this
repo being present. Pick only what you want:

```bash
curl -fsSL https://raw.githubusercontent.com/XuteLoops/linux-configs/main/Arch/stable-arch/modules/40-reboot-required.sh -o reboot-required.sh
chmod +x reboot-required.sh
sudo ./reboot-required.sh
```

Or run everything at once:

```bash
curl -fsSL https://raw.githubusercontent.com/XuteLoops/linux-configs/main/Arch/stable-arch/install-all.sh -o install-all.sh
chmod +x install-all.sh
sudo ./install-all.sh
```

(`--local` runs modules from a locally cloned `modules/` folder instead
of fetching each from GitHub.)

All modules are idempotent — safe to re-run, individually or repeatedly.
Files are only rewritten if their content actually differs from what's
already deployed, and a timestamped backup is made before any overwrite.

---

# Prerequisites & Assumptions

This pipeline relies on a few things being in place before it has a
foundation to run on. Some distros (CachyOS included) provide these by
default; others (vanilla Arch, most other Arch-based distros) require
setting them up manually first:

- **BTRFS + Snapper.** `snapper` and `snap-pac` need to be installed and
  configured, on a BTRFS filesystem, before pacback's snapshot mechanism
  has anything to work with. If your distro doesn't set this up by
  default, this needs to happen before running the `20-verify-transaction`
  module.
- **Bootloader snapshot integration is optional, not required.** Some
  distros (e.g. CachyOS with Limine) wire snapshot-boot entries into the
  bootloader automatically as a convenience. This pipeline's own logic
  doesn't depend on that — it works the same either way — but don't
  expect boot-time snapshot entries to appear unless your
  distro/bootloader combination provides that itself. (Bringing this to
  non-CachyOS systems is an open item — see `HANDOFF.md`.)
- **`base-devel` and `git`.** Required for the AUR helper bootstrap
  (building `paru` from source). Some ISOs include these by default;
  others don't. Every module that needs an AUR package installs these
  itself if missing.

None of the above are blockers — they're just prerequisites that some
distros happen to handle for you and others don't.

---

# Dependencies

What this pipeline directly relies on to function — not the dependencies
_of_ these dependencies, just the tools and packages the hooks/scripts
call directly:

- **bash** — all scripts are bash, not POSIX sh
- **sudo / root access** — required to run any module
- **git** and **base-devel** — needed to build `paru` and any AUR
  packages from source
- **paru** — the AUR helper used throughout (installed automatically if
  neither `paru` nor `yay` is already present; an existing `yay` is left
  alone rather than duplicated)
- **pacback** — the snapshot/restore-point manager the rollback
  mechanism is built on
- **snapper** and **snap-pac** — BTRFS snapshotting, triggered
  automatically around every pacman transaction
- **libsolv** (`installcheck`, `archrepo2solv`) — dependency
  satisfiability checking
- **rebuild-detector** (`checkrebuild`) — broken-linkage /
  stale-dependency checking
- **arch-audit** — CVE scanning against installed packages
- **pacman-contrib** (`paccache`) — package cache pruning
- **curl**, **openssl** — required by the `arch-audit` hook
- **systemd** (`systemd-inhibit`, `systemctl`, `journalctl`, `logger`) —
  used for the shutdown/sleep inhibitor lock, timers, and logging
- **binutils** (`strings`) and **glibc** (`ldd`) — used to detect
  whether the local pacman/libalpm build supports hook network
  sandboxing, and to locate the `libalpm` shared object itself
- **A BTRFS filesystem** — required for snapper/pacback snapshots to
  work at all

---

# Modules

| Module                     | Installs                                                                                                                                                                                             | What it does                                                                                                                                                                                                                              |
| -------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `00-aur-helpers.sh`        | `paru` (only if neither `yay` nor `paru` already present)                                                                                                                                            | Ensures an AUR helper is available. Optional — other modules bootstrap this themselves if it hasn't run.                                                                                                                                  |
| `10-systemd-inhibit.sh`    | — (no packages)                                                                                                                                                                                      | Deploys `PreTransaction`/`PostTransaction` hooks that hold a shutdown/sleep inhibitor lock for the duration of every transaction.                                                                                                         |
| `20-verify-transaction.sh` | `libsolv`, `rebuild-detector`, `pacback` (AUR)                                                                                                                                                       | **The core gate.** Runs `installcheck` + `checkrebuild` after every transaction; on failure, automatically rolls back to the latest pacback snapshot via a detached background process.                                                   |
| `30-arch-audit.sh`         | `arch-audit`, `curl`, `openssl`                                                                                                                                                                      | Informational-only CVE scan, deliberately outside the pass/fail gate. Detects at runtime (not by distro assumption) whether the local pacman build supports hook network sandboxing.                                                      |
| `40-reboot-required.sh`    | — (no packages)                                                                                                                                                                                      | Detects kernel upgrades and systemd (PID 1) upgrades that need a reboot, not just a service restart. Writes `/run/reboot-required`, prints an immediate banner during the transaction, and wires a persistent reminder into bash and zsh. |
| `50-paccache.sh`           | `pacman-contrib`                                                                                                                                                                                     | Enables `paccache.timer` for periodic package cache pruning.                                                                                                                                                                              |
| `60-community-hooks.sh`    | `linux-preserve-modules`, `pacman-hook-reload-modules`, `longoverdue`, `sync-pacman-hook-git`, `reflector-pacman-hook-git`, `systemd-cleanup-pacman-hook`, `systemd-removed-services-hook` (all AUR) | Bundle of small, independent AUR hook packages, each shipping its own pacman hook automatically.                                                                                                                                          |

## How it fits together

1. **Before a transaction** (`10-systemd-inhibit.sh`, plus `snap-pac`/
   `pacback` from `20-verify-transaction.sh`), snapshots are taken and
   the inhibitor lock blocks sleep/shutdown for the duration.
2. **The transaction runs** — packages install/upgrade/remove as normal.
3. **After the transaction**, hooks from every installed module run in
   order (pacman runs hook files alphabetically): stale-binary and
   rebuild checks, the core verification gate, CVE auditing, the
   reboot-required check, and finally the inhibitor release.
4. **If the verification gate fails**, it identifies the most recent
   pacback snapshot and launches a detached background process that
   waits for the pacman database lock to clear, then rolls the system
   back to that snapshot automatically.

## Deliberately not included: `pacman-hook-systemd-restart-git`

This AUR package restarts every service whose underlying binary/library
changed after an upgrade — including `systemd-logind.service`, since its
binary is part of the `systemd` package itself. Restarting `logind` live
kills every login session it's tracking, which on a desktop system means
an unannounced logout mid-transaction. This was confirmed by reproducing
it directly (a `systemd` reinstall kicked an active KDE session back to
the login screen, with `journalctl` logs showing the exact restart
chain). No safe exclude-list fix was found. The `40-reboot-required.sh`
module is the intended alternative for this class of change: flag that a
restart is needed and let a human choose when, rather than attempt a
live restart of something that may not be safely restartable at all.

---

# Why Use This

A rolling-release system is only as safe as its ability to detect and
recover from a bad transaction. This pipeline closes that gap, regardless
of which Arch-based distro it's running on:

- **Turns "hope it works" into "verify it worked."** A normal `pacman -Syu`
  succeeding doesn't guarantee the resulting system is actually coherent —
  broken linkage, unsatisfied dependencies, and packages needing a rebuild
  can all slip through silently. This pipeline checks for those explicitly,
  every time — and has already caught and correctly rolled back real,
  transient dependency breakage in production use (Arch mirror-sync
  timing gaps, not a bug — see `HANDOFF.md`).
- **Automatic recovery, not just automatic snapshots.** Snapper alone gives
  you the ability to _manually_ roll back if you notice something's wrong.
  This pipeline notices for you and rolls back on its own, closing the gap
  between "something broke" and "someone has to catch it."
- **Safe by default, without slowing down every update.** The checks run
  post-transaction, so they don't add friction to normal use — but they
  still catch problems before you've walked away from the machine assuming
  the update succeeded.
- **Survives interruption.** The shutdown/sleep inhibitor hooks prevent the
  system from sleeping or powering off mid-transaction, which is exactly
  the kind of interruption that turns a routine update into a broken
  bootloader or half-applied package.
- **Extra visibility without extra risk.** `arch-audit` flags known CVEs in
  installed packages as an informational layer, deliberately kept outside
  the pass/fail gate so it can't itself cause an unnecessary rollback.
- **Tells you when a reboot actually matters.** Not every update needs a
  restart — this only flags kernel and systemd upgrades specifically,
  rather than nagging on every transaction.
- **Reproducible and picks apart cleanly.** Every module is standalone and
  idempotent, so the same hardened setup can be replicated on a fresh
  install — or shared with someone who only wants one piece of it — rather
  than rebuilt by hand or accepted as an all-or-nothing bundle.

In short: this turns routine `pacman -Syu` updates from "trust that it went
fine" into a self-checking, self-healing process — which matters more, not
less, on a rolling-release distro where updates are frequent and an update
that quietly breaks the system can be hard to trace back after the fact.
