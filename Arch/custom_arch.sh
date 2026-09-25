#!/bin/bash
set -euo pipefail

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
genfstab -U /mnt >> /mnt/etc/fstab

# CHROOT in to the new system 
arch-chroot -S /mnt

# Install extra utilities
pacman -Syyu
pacman -S zsh xdg-user-dirs wireless-regdb alsa-firmware sof-firmware exfatprogs e2fsprogs jfsutils mtd-utils nilfs-utils ntfs-3g udftools xfsprogs bcachefs-tools apfsprogs fsck fdisk cfdisk gdisk udev ndiswrapper overlayfs squashfs networkmanager iwd modemmanager ppp flatpak reflector fwupd pipewire wireplumber network-manager-applet pkgstats cpupower power-profiles-daemon scx-scheds

# Set Locale and Locale.conf
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Make console keyboard layout permanent
echo "KEYMAP=us" > /etc/vconsole.conf

# Set HOSTNAME
read -p "Enter the desired hostname: " hostname
echo "$hostname" > /etc/hostname

# Update firmware & Regenerate initramfs
fwupdmgr refresh
fwupdmgr update
mkinitcpio -P

# Set root password
read -p "Enter desired root password: " rootpass
echo -e "$rootpass\$rootpass" | passwd

# Install bootloader and customize entries
pacman -Syu
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
: "
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
pacman -R mkinitcpio"

# Configure NetworkManager with iwd backend
cat > /etc/NetworkManager/conf.d << 'EOF'
[device]
nwifi.backend=iwd
EOF

systemctl enable --now NetworkManager

# Install and Configure Xorg, drivers, and input along with Wayland
pacman -S xorg xf86-input-libinput xf86-input-synaptics xorg-fonts xorg-apps wayland xwayland-satellite

mkdir -p /etc/X11/xorg.conf.d

# ==========================================
# 1. GPU Detection & Driver Configuration
# ==========================================
GPU_INFO=$(lspci -vnn | grep -E -i "vga|3d|display")

if echo "$GPU_INFO" | grep -iq "ATI"; then
    echo "--> Detected ATI legacy GPU. Installing xf86-video-ati..."
    pacman -S --noconfirm xf86-video-ati
    cat > /etc/X11/xorg.conf.d/20-gpudriver.conf << 'EOF'
Section "Device"
    Identifier "ATI Graphics"
    Driver     "ati"
    Option     "TearFree" "on"
    Option     "DRI" "3"
EndSection
EOF

elif echo "$GPU_INFO" | grep -iq "Advanced Micro Devices\|AMD"; then
    echo "--> Detected modern AMD GPU. Installing xf86-video-amdgpu..."
    pacman -S --noconfirm xf86-video-amdgpu
    cat > /etc/X11/xorg.conf.d/20-gpudriver.conf << 'EOF'
Section "Device"
    Identifier "AMD Graphics"
    Driver     "amdgpu"
    Option     "TearFree" "true"
    Option     "DRI" "3"
    Option     "VariableRefresh" "true"
EndSection
EOF

elif echo "$GPU_INFO" | grep -iq "NVIDIA"; then
    echo "--> Detected NVIDIA GPU. Installing proprietary drivers..."
    pacman -S --noconfirm nvidia-lts nvidia-utils
    cat > /etc/X11/xorg.conf.d/20-gpudriver.conf << 'EOF'
Section "Screen"
    Identifier "NVIDIA Screen"
    Option     "ForceCompositionPipeline" "On"
    Option     "ForceFullCompositionPipeline" "On"
EndSection
EOF

elif echo "$GPU_INFO" | grep -iq "Intel"; then
    echo "--> Detected Intel GPU. Configuring modesetting driver..."
    cat > /etc/X11/xorg.conf.d/20-gpudriver.conf << 'EOF'
Section "Device"
    Identifier "Intel Graphics"
    Driver     "modesetting"
    Option     "AccelMethod" "glamor"
EndSection
EOF

elif echo "$GPU_INFO" | grep -iq "VMware\|VirtualBox\|QEMU"; then
    echo "--> Detected Virtual Machine display driver. Using fallback modesetting..."
    cat > /etc/X11/xorg.conf.d/20-gpudriver.conf << 'EOF'
Section "Device"
    Identifier "Virtual Display"
    Driver     "modesetting"
EndSection
EOF

else
    echo "--> Unknown GPU hardware. Relying on default Xorg auto-detection."
fi

# ==========================================
# 2. Touchpad Detection (Synaptics vs Libinput)
# ==========================================
TOUCHPAD_IS_SYNAPTICS=false

if [ -f /proc/bus/input/devices ] && grep -iq "synaptics\|synps" /proc/bus/input/devices; then
    TOUCHPAD_IS_SYNAPTICS=true
elif command -v libinput &>/dev/null && libinput list-devices 2>/dev/null | grep -iq "synaptics"; then
    TOUCHPAD_IS_SYNAPTICS=true
fi

if [ "$TOUCHPAD_IS_SYNAPTICS" = true ]; then
    echo "--> Detected Synaptics hardware. Installing xf86-input-synaptics..."
    pacman -S --noconfirm xf86-input-synaptics
    cat > /etc/X11/xorg.conf.d/70-synaptics.conf << 'EOF'
Section "InputClass"
    Identifier "Touchpad Synaptics Options"
    MatchIsTouchpad "on"
    Driver "synaptics"
    Option "TapButton1" "1"
    Option "TapButton2" "3"
    Option "TapButton3" "2"
    Option "VertEdgeScroll" "off"
    Option "VertTwoFingerScroll" "on"
    Option "HorizTwoFingerScroll" "on"
    Option "CircularScrolling" "off"
    Option "PalmDetect" "1"
EndSection
EOF
else
    echo "--> Writing standard libinput configuration for touchpad/mouse..."
    cat > /etc/X11/xorg.conf.d/40-libinput.conf << 'EOF'
Section "InputClass"
    Identifier "Touchpad Configuration"
    MatchIsTouchpad "on"
    Driver "libinput"
    Option "Tapping" "on"
    Option "NaturalScrolling" "true"
    Option "ClickMethod" "clickfinger"
    Option "DisableWhileTyping" "true"
EndSection
EOF
fi

# ==========================================
# 3. Keyboard Layout Detection & Sync
# ==========================================
echo "--> Detecting system keyboard layout..."
KEYLAYOUT=""

if command -v localectl &>/dev/null; then
    KEYLAYOUT=$(localectl status | awk -F': ' '/X11 Layout/ {print $2}')
fi

if [ -z "$KEYLAYOUT" ] && [ -f /etc/vconsole.conf ]; then
    # Parse KEYMAP without executing arbitrary scripts via source
    KEYLAYOUT=$(grep -E '^KEYMAP=' /etc/vconsole.conf | cut -d'=' -f2 | tr -d '"' | tr -d "'")
fi

KEYLAYOUT="${KEYLAYOUT:-us}"

echo "--> Applying X11 keyboard layout: ${KEYLAYOUT}"
cat > /etc/X11/xorg.conf.d/00-keyboard.conf << EOF
Section "InputClass"
    Identifier "Keyboard Defaults"
    MatchIsKeyboard "on"
    Driver "libinput"
    Option "XkbLayout" "${KEYLAYOUT}"
EndSection
EOF

# ==========================================
# Mouse Acceleration (libinput flat profile)
# ==========================================
echo "--> Writing mouse acceleration configuration..."
cat > /etc/X11/xorg.conf.d/50-mouse-acceleration.conf << 'EOF'
Section "InputClass"
    Identifier "System Mouse Acceleration"
    MatchIsPointer "on"
    Driver "libinput"
    Option "AccelProfile" "flat"      # 'flat' disables acceleration, 'adaptive' enables it
    Option "AccelSpeed" "0"          # Speed range from -1.0 to 1.0 (0 = default 1:1 sensitivity)
EndSection
EOF

# ==========================================
# Mouse Buttons Setup (xbindkeys + xdotool)
# ==========================================
echo "--> Installing mouse button mapping utilities..."
pacman -S --noconfirm xbindkeys xdotool

# Create a default system-wide xbindkeys config template for users
echo "--> Writing default /etc/xbindkeysrc template..."
cat > /etc/xbindkeysrc << 'EOF'
# Sample extra mouse button mappings:
# Run 'xev' or 'xbindkeys -k' to identify mouse button numbers

# Map Mouse Button 8 (Back side button) to Alt+Left (Browser Back)
"xdotool key alt+Left"
  b:8

# Map Mouse Button 9 (Forward side button) to Alt+Right (Browser Forward)
"xdotool key alt+Right"
  b:9
EOF

# Ensure xbindkeys starts automatically in X11 user sessions
mkdir -p /etc/X11/xinit/xinitrc.d
cat > /etc/X11/xinit/xinitrc.d/90-xbindkeys.sh << 'EOF'
#!/bin/sh
if [ -f "$HOME/.xbindkeysrc" ]; then
    xbindkeys -f "$HOME/.xbindkeysrc"
elif [ -f /etc/xbindkeysrc ]; then
    xbindkeys -f /etc/xbindkeysrc
fi
EOF
chmod +x /etc/X11/xinit/xinitrc.d/90-xbindkeys.sh

# Optional: Install GUI/CLI daemon for gaming mice (Logitech, Razer, SteelSeries, etc.)
pacman -S --noconfirm libratbag piper
systemctl enable ratbagd.service

# Create Local User and add to wheel group/sudoers file for admin permissions
read -p "Enter the desired username: " newuser
read -p "Enter password for new user: " newpass
useradd -m -G wheel sudo -s /bin/zsh "$newuser"
echo -e "$newpass\$newpass" | passwd
xdg-user-dirs-update

sudo sed -i \
  -e 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' \
  -e 's/^# %sudo\tALL=(ALL:ALL) ALL/%sudo\tALL=(ALL:ALL) ALL/' \
  /etc/sudoers
  
sudo visudo -c   #checks to ensure the sudoers file is valid/has no syntax errors. if it does: fix it manually

# Install and configure 'ly' display manager
pacman -S ly brightnessctl
systemctl enable --now ly@tty1.service
systemctl disable getty@tty1.service

echo "--> Configuring consolefont before kms in /etc/mkinitcpio.conf..."

sed -i -E '/^HOOKS=/s/\bconsolefont\b\s*//g' /etc/mkinitcpio.conf # Strip existing consolefont occurrences from the HOOKS line

sed -i -E '/^HOOKS=/s/\bkms\b/consolefont kms/' /etc/mkinitcpio.conf # Place consolefont right before kms

sed -i -E '/^HOOKS=/s/\s+/ /g' /etc/mkinitcpio.conf # Clean up any trailing/double spaces inside HOOKS=(...)

# Verification step
if grep -q "consolefont kms" /etc/mkinitcpio.conf; then
    echo "[OK] consolefont successfully placed before kms."
else
    echo "[WARNING] Could not verify consolefont placement in /etc/mkinitcpio.conf"
fi

# Rebuild initramfs image
echo "--> Rebuilding initramfs image..."
mkinitcpio -P

# Install and configure xfce4 desktop environment
pacman -S xfce4 xfce4-goodies firefox 

# Install secondary tiling window manager
pacman -S qtile

# Optional: Install Cinnamon
#pacman -S cinnamon xed xviewer xreader metacity gnome-panel

# Optional: Install KDE
#pacman -S plasma-meta kde-applications-meta

# Optional: Install Gnome
#pacman -S gnome gnome-circle gnome-extra

# Optional: Install MATE 
#pacman -S mate mate-extra

# Optional: Install LXQt
#pacman -S lxqt lxqt-panel breeze-icons oxygen-icons xscreensaver

# Optional: Install Budgie
#pacman -S budgie budgie-desktop-view network-manager-applet blueman

# Optional: Install COSMIC
#pacman -S cosmic gvfs gvfs-nfs gvfs-smb gvfs-dnssd gnome-keyring

# Optional: Install Pantheon
#pacman -S pantheon 

# Optional: Install Niri and associated packages, optionally install DMS shell or noctalia
#pacman -S fuzzel mako waybar xdg-desktop-portal-gtk xdg-desktop-portal-gnome alacritty swaybg swayidle swaylock xwayland-satellite udiskie
#pacman -S dms-shell-niri
#pacman -S noctalia

# Install fonts
pacman -S adwaita-fonts powerline-fonts awesome-terminal-fonts adobe-source-code-pro-fonts adobe-source-sans-fonts adobe-source-serif-fonts
pacman -S $(pacman -Slq | grep '^noto-fonts') && pacman -S $(pacman -Slq | grep '^otf-') && pacman -S $(pacman -Slq | grep '^ttf-') && pacman -S $(pacman -Slq | grep '^woff2-')

# Optimize CPU Frequency Scaling
systemctl enable --now power-profiles-daemon.service

# Unmute alsa kernel driver
amixer sset Master unmute
amixer sset Speaker unmute
amixer sset Headphone unmute