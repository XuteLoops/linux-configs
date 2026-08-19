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