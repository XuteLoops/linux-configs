# Prerequisites & Assumptions

This script was built and tested on CachyOS, which ships several things by
default that vanilla Arch (or other Arch-based distros) does not. Before
running it on a non-CachyOS system, confirm the following:

- **BTRFS + Snapper.** `snapper` and `snap-pac` aren't installed or
  configured by default on vanilla Arch the way they are on CachyOS. You'll
  need a BTRFS filesystem and a manual Snapper setup before pacback's
  snapshot mechanism has anything to work with — this is the same first
  step that was done on the original CachyOS test VM.
- **No Limine-snapshot integration out of the box.** CachyOS wires Limine
  into Snapper's boot-snapshot flow as a convenience; vanilla Arch doesn't.
  This shouldn't affect the pipeline's own logic, but don't expect
  boot-time snapshot entries to just appear the way they did on CachyOS.
- **`base-devel` and `git` may not be preinstalled.** Some CachyOS ISOs
  assume these are already present; vanilla Arch installs may not have
  them. Confirm both are installed before relying on the AUR helper
  bootstrap step.

None of the above are blockers — they're just setup steps that CachyOS
happens to handle for you, which need to be done manually on a vanilla Arch
(or other Arch-based) system before this pipeline has a foundation to run on.

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

| File | When it runs | What it does |
|---|---|---|
| `00-systemd-inhibit-pre.hook` + `inhibit-start.sh` | `PreTransaction` | Acquires a shutdown/sleep inhibitor lock so the system can't sleep or power off mid-transaction |
| `zy-verifytransaction-post.hook` + `verify-transaction.sh` | `PostTransaction` | The core gate: runs `installcheck` (dependency satisfiability) and `checkrebuild` (broken linkage). On failure, finds the latest pacback snapshot and triggers an automatic, detached rollback |
| `arch-audit.hook` | `PostTransaction` | Informational-only CVE scan against installed packages; not part of the pass/fail gate |
| `zz-systemd-inhibit-post.hook` + `inhibit-stop.sh` | `PostTransaction` | Releases the shutdown/sleep inhibitor lock acquired at the start of the transaction |

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

# Why Run This on CachyOS

CachyOS already ships a solid baseline (BTRFS + Snapper + Limine snapshot
integration by default), but a rolling-release system is still only as
safe as its ability to detect and recover from a bad transaction. This
pipeline closes that gap:

- **Turns "hope it works" into "verify it worked."** A normal `pacman -Syu`
  succeeding doesn't guarantee the resulting system is actually coherent —
  broken linkage, unsatisfied dependencies, and packages needing a rebuild
  can all slip through silently. This pipeline checks for those explicitly,
  every time.
- **Automatic recovery, not just automatic snapshots.** Snapper alone gives
  you the ability to *manually* roll back if you notice something's wrong.
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
  same hardened setup can be replicated on a fresh install (VM or bare
  metal) rather than rebuilt by hand each time.

In short: this turns routine `pacman -Syu` updates from "trust that it went
fine" into a self-checking, self-healing process — which matters more, not
less, on a rolling-release distro where updates are frequent and an update
that quietly breaks the system can be hard to trace back after the fact.