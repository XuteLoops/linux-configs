#!/bin/bash

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
pacman -Sy
pacman -S reflector
reflector
pacstrap -K /mnt base linux linux-firmware linux-headers curl wget git amd-ucode intel-ucode nano vim btrfs-progs os-prober dosfstools

# Gen FSTAB
genfstab -U /mnt >> /mnt/etc/fstab

# CHROOT in to the new system 
arch-chroot -S /mnt

# Install extra utilities
pacman -Syyu
pacman -S linux-lts linux-lts-headers wireless-regdb alsa-firmware sof-firmware exfatprogs e2fsprogs jfsutils mtd-utils nilfs-utils ntfs-3g udftools xfsprogs bcachefs-tools apfsprogs fsck fdisk cfdisk gdisk udev ndiswrapper overlayfs squashfs networkmanager iwd modemmanager ppp flatpak

# Set Locale and Locale.conf
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Make console keyboard layout permanent
echo "KEYMAP=us" > /etc/vconsole.conf

# Set HOSTNAME
read -p "Enter the desired hostname: " hostname
echo "$hostname" > /etc/hostname

# Regenerate initramfs
mkinitcpio -P

# Set root password
read -p "Enter desired root password: " rootpass
echo -e "$rootpass\$rootpass" | passwd

# Install bootloader and customize entries
pacman -Sy
pacman -S grub grub-btrfs
if [ -d /sys/firmware/efi ]; then
	echo "BIOS"
	grub-install --target=i386-pc /dev/sda
else 
	echo "UEFI"
	grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
lsblk --noheadings --raw -o NAME,MOUNTPOINT | awk '$1~/[[:digit:]]/ && $2 == ""' | while read name mountpoint; do
    udisksctl mount -b /dev/$name	
grub-mkconfig -o /boot/grub/grub.cfg
sudo sed -i '$s/^#//' /etc/default/grub 

cat >> /etc/grub.d/40_custom << 'EOF'
menuentry "System shutdown" {
	echo "System shutting down..."
	halt
}
menuentry "System restart" {
	echo "System rebooting..."
	reboot
}
if [ ${grub_platform} == "efi" ]; then
	menuentry 'UEFI Firmware Settings' --id 'uefi-firmware' {
		fwsetup
	}
	menuentry 'UEFI Shell' {
		insmod fat
		insmod chain
		search --no-floppy --set=root --file /shellx64.efi
		chainloader /shellx64.efi
	}
fi
EOF
grub-mkconfig -o /boot/grub/grub.cfg

# Switch from mkinitcpio to dracut
mkdir -p /etc/pacman.d/hooks
ln -s /dev/null /etc/pacman.d/hooks/60-mkinitcpio-remove.hook
ln -s /dev/null /etc/pacman.d/hooks/90-mkinitcpio-install.hook

cat > /usr/local/bin/dracut-install.sh << 'EOF'
#!/bin/bash
shopt -s extglob
mountpoint -q /boot || { echo "ERROR: /boot not mounted, skipping" >&2; exit 1; }
args=(--force --no-hostonly-cmdline)
while read -r line; do
  [[ $line == usr/lib/modules/+([^/])/pkgbase ]] || continue
  read -r pkgbase < "/$line"
  kver=${line#usr/lib/modules/}; kver=${kver%/pkgbase}
  install -Dm0644 "/${line%/pkgbase}/vmlinuz" "/boot/vmlinuz-$pkgbase"
  dracut "${args[@]}" --hostonly    "/boot/initramfs-$pkgbase.img"          --kver "$kver"
  dracut "${args[@]}" --no-hostonly "/boot/initramfs-$pkgbase-fallback.img" --kver "$kver"
done
EOF

cat > /usr/local/bin/dracut-remove.sh << 'EOF'
#!/bin/bash
shopt -s extglob
while read -r line; do
  [[ $line == usr/lib/modules/+([^/])/pkgbase ]] || continue
  read -r pkgbase < "/$line"
  rm -f "/boot/vmlinuz-$pkgbase" "/boot/initramfs-$pkgbase.img" "/boot/initramfs-$pkgbase-fallback.img"
done
EOF

cat > /etc/pacman.d/hooks/90-dracut-install.hook << 'EOF'
[Trigger]
Type = Path
Operation = Install
Operation = Upgrade
Target = usr/lib/modules/*/pkgbase

[Action]
Description = Updating initramfs (dracut)...
When = PostTransaction
Exec = /usr/local/bin/dracut-install.sh
NeedsTargets
EOF

cat > /etc/pacman.d/hooks/60-dracut-remove.hook << 'EOF'
[Trigger]
Type = Path
Operation = Remove
Target = usr/lib/modules/*/pkgbase

[Action]
Description = Removing kernel and initramfs (dracut)...
When = PreTransaction
Exec = /usr/local/bin/dracut-remove.sh
NeedsTargets
EOF

chmod +x /usr/local/bin/dracut-install.sh
chmod +x /usr/local/bin/dracut-remove.sh
pacman -R mkinitcpio

# Configure NetworkManager with iwd backend
cat > /etc/NetworkManager/conf.d << 'EOF'
[device]
nwifi.backend=iwd
EOF

systemctl enable --now NetworkManager

# Install Xorg, Wayland, and XWayland


# Create Local User and add to wheel group/sudoers file for admin permissions