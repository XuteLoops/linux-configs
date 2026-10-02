#!/bin/bash

### This script makes a few assumptions:
### -It assumes it is being run from the archiso
### -It assumes that there is an active network connection
### -It assumes that partitioning has already been performed
### -It assumes that ESP is sda1, / is sda2, and swap is on sda3
### -It assumed the filesystem on the / partition is Btrfs
###
### If any of the above assumptions are incorrect please modify this script accordingly

# Set keyboard layout and locale for NTP
loadkeys en
ln -sf /usr/share/zoneinfo/America/New_York /etc/localtime
timedatectl set-timezone America/New_York
timedatectl set-ntp true
hwclock --systohc

# mount partitions (assuming sda1 = boot, sda2 = swap, sda3 = /)
mount /dev/sda3 /mnt
mount --mkdir /dev/sda1 /mnt/boot
swapon /dev/sda2

# Update Mirrors and Pacstrap base and other packages
pacman -Syu
pacman -S reflector
reflector
pacstrap -K /mnt base linux-lts linux-firmware linux-lts-headers curl wget git amd-ucode intel-ucode nano vim btrfs-progs os-prober dosfstools

# Gen FSTAB
genfstab -U /mnt | tee /mnt/etc/fstab

# Stage part 2 inside the new system and chroot in.
# Both files are pulled via git on the archiso, so part 2 is copied over
# instead of git-cloning from inside the chroot (network assumed for pacman).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cp "$SCRIPT_DIR/custom_arch_part2.sh" /mnt/root/custom_arch_part2.sh
chmod +x /mnt/root/custom_arch_part2.sh
arch-chroot -S /mnt /root/custom_arch_part2.sh
