#!/bin/bash
set -euo pipefail

### This script makes a few assumptions:
### -It assumes it is being run from the archiso
### -It assumes that there is an active network connection
### -It assumes that DISK holds no data you care about (it will be wiped)
### -It creates: 1GiB ESP, 8GiB swap, remaining Btrfs for /
### -Root filesystem is Btrfs with @, @home, @snapshots, @log, @cache
###
### If any of the above assumptions are incorrect please modify this script accordingly

DISK="${DISK:-/dev/sda}" # override with DISK=/dev/nvme0n1 ./custom_arch.sh
# Handle nvme/mmcblk naming (p1) vs sda/vda (1).
if [[ "$DISK" =~ [0-9]$ ]]; then PSEP="p"; else PSEP=""; fi
ESP="${DISK}${PSEP}1"
SWAP="${DISK}${PSEP}2"
ROOT="${DISK}${PSEP}3"

# Set keyboard layout and locale for NTP
loadkeys en
ln -sf /usr/share/zoneinfo/America/New_York /etc/localtime
timedatectl set-timezone America/New_York
timedatectl set-ntp true
hwclock --systohc

# Partition (GPT): 1GiB ESP, 8GiB swap, rest for Btrfs /. THIS WIPES $DISK.
lsblk "$DISK"
read -rp "WIPE and repartition $DISK (ESP 1GiB / swap 8GiB / Btrfs rest)? Type YES to continue: " confirm
if [ "$confirm" != "YES" ]; then
    echo "Aborted."
    exit 1
fi
swapoff "${SWAP}" 2>/dev/null || true
umount -R /mnt 2>/dev/null || true
sgdisk --zap-all "$DISK"
sgdisk --new=1:0:+1GiB --typecode=1:EF00 --change-name=1:ESP "$DISK"
sgdisk --new=2:0:+8GiB --typecode=2:8200 --change-name=2:swap "$DISK"
sgdisk --new=3:0:0 --typecode=3:8300 --change-name=3:root "$DISK"
partprobe "$DISK"
udevadm settle

# Filesystems.
mkfs.fat -F 32 "$ESP"
mkswap "$SWAP"
mkfs.btrfs -f "$ROOT"

# mount partitions (ESP, / on Btrfs subvolumes, swap)
# Top-level mount so subvolumes can be created if missing (idempotent).
mount "$ROOT" /mnt
for sv in @ @home @snapshots @log @cache; do
    if [ ! -e "/mnt/$sv" ]; then
        btrfs subvolume create "/mnt/$sv"
    fi
done
umount /mnt

# Remount with standard subvolume layout + mountpoints for genfstab/pacstrap.
BTRFS_OPTS="noatime,compress=zstd,space_cache=v2"
mount -o "$BTRFS_OPTS",subvol=@ "$ROOT" /mnt
mount --mkdir -o "$BTRFS_OPTS",subvol=@home "$ROOT" /mnt/home
mount --mkdir -o "$BTRFS_OPTS",subvol=@snapshots "$ROOT" /mnt/.snapshots
mount --mkdir -o "$BTRFS_OPTS",subvol=@log "$ROOT" /mnt/var/log
mount --mkdir -o "$BTRFS_OPTS",subvol=@cache "$ROOT" /mnt/var/cache
mount --mkdir "$ESP" /mnt/boot
swapon "$SWAP"

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
echo "$DISK" > /mnt/root/.install-disk
arch-chroot -S /mnt /root/custom_arch_part2.sh
