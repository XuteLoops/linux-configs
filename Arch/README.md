# Hardened Pacman Update Pipeline

Idempotent pacman hooks that automatically verify every transaction
(dependency satisfiability + broken-linkage checks) and roll back via
BTRFS snapshots on failure — so a `pacman -Syu` that silently breaks the
system doesn't stay broken unnoticed.

**Verified working on:**

- CachyOS (original build/test environment, including end-to-end via the
  `--verify` smoke test flag)
- Vanilla Arch Linux, fresh install, out of the box

Built for Arch and Arch-based distros generally — anything running pacman
and libalpm should be compatible, though only the two above have been
directly tested.

---

# Prerequisites & Assumptions

This pipeline relies on a few things being in place before it has a
foundation to run on. Some distros (CachyOS included) provide these by
default; others (vanilla Arch, most other Arch-based distros) require
setting them up manually first:

- **BTRFS + Snapper.** `snapper` and `snap-pac` need to be installed and
  configured, on a BTRFS filesystem, before pacback's snapshot mechanism
  has anything to work with. If your distro doesn't set this up by
  default, this needs to happen before running the pipeline.
- **Bootloader snapshot integration is optional, not required.** Some
  distros (e.g. CachyOS with Limine) wire snapshot-boot entries into the
  bootloader automatically as a convenience. This pipeline's own logic
  doesn't depend on that — it works the same either way — but don't expect
  boot-time snapshot entries to appear unless your distro/bootloader
  combination provides that itself.
- **`base-devel` and `git`.** Required for the AUR helper bootstrap step
  (building `yay` and `paru` from source). Some ISOs include these by
  default; others don't. Confirm both are installed, or let the script
  install them itself.

None of the above are blockers — they're just prerequisites that some
distros happen to handle for you and others don't.

---

# Dependencies

What this pipeline directly relies on to function — not the dependencies
_of_ these dependencies, just the tools and packages the hooks/scripts
call directly:

- **bash** — all scripts are bash, not POSIX sh
- **sudo / root access** — required to run the setup script and to deploy
  files under `/etc/pacman.d/`
- **git** and **base-devel** — needed to build the AUR helpers and AUR
  packages below from source
- **yay** and **paru** — AUR helpers (bootstrapped by the setup script if
  not already present)
- **pacback** — the snapshot/restore-point manager the rollback mechanism
  is built on
- **snapper** and **snap-pac** — BTRFS snapshotting, triggered automatically
  around every pacman transaction
- **libsolv** (`installcheck`, `archrepo2solv`) — dependency satisfiability
  checking
- **rebuild-detector** (`checkrebuild`) — broken-linkage / stale-dependency
  checking
- **arch-audit** — CVE scanning against installed packages
- **pacman-contrib** (`paccache`) — package cache pruning
- **curl**, **openssl** — required by the `arch-audit` hook
- **systemd** (`systemd-inhibit`, `systemctl`, `journalctl`, `logger`) —
  used for the shutdown/sleep inhibitor lock, timers, and logging
- **binutils** (`strings`) and **glibc** (`ldd`) — used by the setup
  script itself to detect whether the local pacman/libalpm build supports
  hook network sandboxing
- **A BTRFS filesystem** — required for snapper/pacback snapshots to work
  at all

---

# What This Pipeline Includes

## Packages installed

**Official repos:**
| Package | Purpose |
|---|---|
| `pacman-contrib` | Provides `paccache`, used to prune the package cache on a timer |
| `libsolv` | Provides `installcheck`/`archrepo2solv`, used to verify dependency satisfiability after every transaction |
| `rebuild-detector` | Provides `checkrebuild`, detects packages with broken linkage or stale interpreter dependencies (ldd/python/perl/ruby/haskell) |
| `arch-audit` | Checks installed packages against Arch's CVE database |
| `pkgfile` | File-to-package lookup (companion tooling) |
| `curl`, `openssl` | Dependencies of the `arch-audit` hook |
| `snapper`, `snap-pac` | BTRFS snapshotting; `snap-pac` auto-snapshots around every pacman transaction |

**AUR:**
| Package | Purpose |
|---|---|
| `pacback` | Snapshot/restore-point manager; provides the rollback mechanism this pipeline relies on |
| `linux-preserve-modules` | Preserves out-of-tree kernel modules across kernel upgrades |
| `pacman-hook-reload-modules` | Reloads affected kernel modules after relevant package upgrades |
| `longoverdue` | Notifies about running daemons still referencing deleted shared library handles |
| `sync-pacman-hook-git` | Syncs `/` and `/boot` after transactions |
| `reflector-pacman-hook-git` | Refreshes the mirrorlist when `pacman-mirrorlist` updates |
| `pacman-hook-systemd-restart-git` | Restarts affected systemd services after relevant upgrades |
| `systemd-cleanup-pacman-hook` | Cleans up orphaned systemd units |
| `systemd-removed-services-hook` | Flags services removed by a package but still referenced |

## Custom hooks & scripts

These are hand-written for this pipeline (not provided by any package) and
deployed to `/etc/pacman.d/hooks/` and `/etc/pacman.d/hooks/scripts/`:

| File                                                       | When it runs      | What it does                                                                                                                                                                                                                                      |
| ---------------------------------------------------------- | ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `00-systemd-inhibit-pre.hook` + `inhibit-start.sh`         | `PreTransaction`  | Acquires a shutdown/sleep inhibitor lock so the system can't sleep or power off mid-transaction                                                                                                                                                   |
| `zy-verifytransaction-post.hook` + `verify-transaction.sh` | `PostTransaction` | The core gate: runs `installcheck` (dependency satisfiability) and `checkrebuild` (broken linkage). On failure, finds the latest pacback snapshot and triggers an automatic, detached rollback                                                    |
| `arch-audit.hook`                                          | `PostTransaction` | Informational-only CVE scan against installed packages; not part of the pass/fail gate. Automatically adds `NetworkAccess = allowed` if the local pacman build has hook/scriptlet network sandboxing (detected at runtime, not assumed by distro) |
| `zz-systemd-inhibit-post.hook` + `inhibit-stop.sh`         | `PostTransaction` | Releases the shutdown/sleep inhibitor lock acquired at the start of the transaction                                                                                                                                                               |

Hook filenames are prefixed to control execution order (pacman runs hooks
alphabetically): the inhibitor lock is acquired first (`00-`) and released
last (`zz-`), with the verification gate (`zy-`) and other check hooks
(`arch-audit.hook`, `rebuild-detector`'s own hook, etc.) running in between,
after `pacback`'s own snapshot hook has already captured a pre-transaction
state to roll back to if needed.

## How it fits together

1. **Before a transaction**, `snap-pac` and `pacback` take snapshots, and
   the inhibitor hook blocks sleep/shutdown for the duration.
2. **The transaction runs** — packages install/upgrade/remove as normal.
3. **After the transaction**, a chain of `PostTransaction` hooks runs in
   order: stale-binary checks, rebuild detection, the core verification
   gate (`installcheck` + `checkrebuild`), CVE auditing, and finally the
   inhibitor release.
4. **If the verification gate fails**, it identifies the most recent
   pacback snapshot and launches a detached background process that waits
   for the pacman database lock to clear, then rolls the system back to
   that snapshot — automatically, without user intervention.

---

# Why Use This

A rolling-release system is only as safe as its ability to detect and
recover from a bad transaction. This pipeline closes that gap, regardless
of which Arch-based distro it's running on:

- **Turns "hope it works" into "verify it worked."** A normal `pacman -Syu`
  succeeding doesn't guarantee the resulting system is actually coherent —
  broken linkage, unsatisfied dependencies, and packages needing a rebuild
  can all slip through silently. This pipeline checks for those explicitly,
  every time.
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
- **Reproducible, not just "it works on my machine."** The automation
  script that deploys all of this is idempotent and safe to re-run, so the
  same hardened setup can be replicated on a fresh install — CachyOS,
  vanilla Arch, or in principle any Arch-based distro with pacman/libalpm —
  rather than rebuilt by hand each time.

In short: this turns routine `pacman -Syu` updates from "trust that it went
fine" into a self-checking, self-healing process — which matters more, not
less, on a rolling-release distro where updates are frequent and an update
that quietly breaks the system can be hard to trace back after the fact.
