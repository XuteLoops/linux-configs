#!/usr/bin/env bash
# 11-utilities.sh — misc utility packages/services.

setup_preload() {
    aur_install preload
    enable_service preload.service
}

install_linux_firmware() {
    pkg_install linux-firmware
}

setup_cronie() {
    pkg_install cronie
    enable_service cronie.service
}

install_fwupd() {
    pkg_install fwupd
}

install_fonts() {
    # Reasonable default font set covering broad glyph coverage (noto),
    # a widely-liked hinted UI font (ttf-dejavu), and standard metric-
    # compatible fallbacks (ttf-liberation). Adjust to taste.
    pkg_install noto-fonts noto-fonts-emoji ttf-dejavu ttf-liberation freetype2
}
