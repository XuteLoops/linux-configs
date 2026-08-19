#!/bin/bash
#
# setup-zsh-p10k.sh
#
# Installs zsh, oh-my-zsh, the Powerlevel10k theme, and the MesloLGS Nerd
# Font, configures ~/.zshrc to use Powerlevel10k, and sets zsh as the
# target user's default login shell.
#
# Safe to re-run: each step checks whether it's already done before acting.
#
# Usage:
#   sudo ./setup-zsh-p10k.sh
#
set -euo pipefail

log() {
    echo "==> $*"
}

warn() {
    echo "WARNING: $*" >&2
}

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root (e.g. sudo $0)" >&2
    exit 1
fi

# The user to configure zsh/oh-my-zsh/p10k for — needed since these are
# all per-user installs under $HOME, not system-wide.
TARGET_USER="${SUDO_USER:-}"
if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
    echo "Could not determine a non-root target user (run this via 'sudo', not as root directly)." >&2
    exit 1
fi

TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
if [ -z "$TARGET_HOME" ] || [ ! -d "$TARGET_HOME" ]; then
    echo "Could not resolve a home directory for user '$TARGET_USER'." >&2
    exit 1
fi

as_user() {
    sudo -u "$TARGET_USER" -H bash -c "$1"
}

# ---------------------------------------------------------------------------
# 1. Install zsh and the Nerd Font
# ---------------------------------------------------------------------------

ensure_pkg_installed() {
    local pkg="$1"
    if pacman -Qi "$pkg" &>/dev/null; then
        log "Already installed: $pkg"
    else
        log "Installing: $pkg"
        pacman -S --needed --noconfirm "$pkg"
    fi
}

log "Installing zsh and MesloLGS Nerd Font..."
ensure_pkg_installed zsh
ensure_pkg_installed ttf-meslo-nerd

# ---------------------------------------------------------------------------
# 2. Install oh-my-zsh (unattended, no shell switch or auto-launch)
# ---------------------------------------------------------------------------

if [ -d "$TARGET_HOME/.oh-my-zsh" ]; then
    log "oh-my-zsh already installed for $TARGET_USER, skipping"
else
    log "Installing oh-my-zsh for $TARGET_USER..."
    as_user 'RUNZSH=no CHSH=no KEEP_ZSHRC=no sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended'
fi

ZSH_CUSTOM="$TARGET_HOME/.oh-my-zsh/custom"

# ---------------------------------------------------------------------------
# 3. Install Powerlevel10k theme
# ---------------------------------------------------------------------------

P10K_DIR="$ZSH_CUSTOM/themes/powerlevel10k"
if [ -d "$P10K_DIR" ]; then
    log "Powerlevel10k already installed, skipping"
else
    log "Cloning Powerlevel10k..."
    as_user "git clone --quiet --depth=1 https://github.com/romkatv/powerlevel10k.git '$P10K_DIR'"
fi

# ---------------------------------------------------------------------------
# 4. Configure ~/.zshrc
# ---------------------------------------------------------------------------

ZSHRC="$TARGET_HOME/.zshrc"

if [ ! -f "$ZSHRC" ]; then
    warn "$ZSHRC does not exist yet — oh-my-zsh's installer should have created it. Creating a minimal one."
    as_user "touch '$ZSHRC'"
fi

log "Configuring $ZSHRC..."

# Set ZSH_THEME to powerlevel10k, replacing any existing value.
if grep -q '^ZSH_THEME=' "$ZSHRC"; then
    sed -i 's|^ZSH_THEME=.*|ZSH_THEME="powerlevel10k/powerlevel10k"|' "$ZSHRC"
else
    printf '\nZSH_THEME="powerlevel10k/powerlevel10k"\n' >> "$ZSHRC"
fi

# Add the recommended instant-prompt snippet near the top, if not already present.
INSTANT_PROMPT_SNIPPET='if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi'

if ! grep -q 'p10k-instant-prompt' "$ZSHRC"; then
    log "Adding Powerlevel10k instant-prompt snippet..."
    TMP_ZSHRC=$(mktemp)
    {
        echo "# Enable Powerlevel10k instant prompt. Should stay close to the top of ~/.zshrc."
        echo "$INSTANT_PROMPT_SNIPPET"
        echo
        cat "$ZSHRC"
    } > "$TMP_ZSHRC"
    mv "$TMP_ZSHRC" "$ZSHRC"
    chown "$TARGET_USER:$TARGET_USER" "$ZSHRC"
fi

# Add the p10k config source line at the end, if not already present.
if ! grep -q 'p10k.zsh' "$ZSHRC"; then
    log "Adding p10k config source line..."
    printf '\n# To customize prompt, run `p10k configure` or edit ~/.p10k.zsh.\n[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh\n' >> "$ZSHRC"
fi

chown "$TARGET_USER:$TARGET_USER" "$ZSHRC"

# ---------------------------------------------------------------------------
# 5. Set zsh as the default shell
# ---------------------------------------------------------------------------

ZSH_PATH=$(command -v zsh)

if ! grep -qxF "$ZSH_PATH" /etc/shells; then
    log "Adding $ZSH_PATH to /etc/shells..."
    echo "$ZSH_PATH" >> /etc/shells
fi

CURRENT_SHELL=$(getent passwd "$TARGET_USER" | cut -d: -f7)
if [ "$CURRENT_SHELL" = "$ZSH_PATH" ]; then
    log "$TARGET_USER's default shell is already $ZSH_PATH"
else
    log "Changing $TARGET_USER's default shell to $ZSH_PATH..."
    chsh -s "$ZSH_PATH" "$TARGET_USER"
fi

# ---------------------------------------------------------------------------
# 6. Summary
# ---------------------------------------------------------------------------

echo
log "Setup complete."
log "zsh:              $ZSH_PATH"
log "oh-my-zsh:        $TARGET_HOME/.oh-my-zsh"
log "Powerlevel10k:    $P10K_DIR"
log "Font installed:   MesloLGS Nerd Font (ttf-meslo-nerd)"
log "zshrc:            $ZSHRC"
echo
log "Next steps:"
log "  1. Set your terminal emulator's font to 'MesloLGS NF' (or similar Nerd Font variant) so prompt symbols render correctly."
log "  2. Log out and back in (or open a new terminal) to start using zsh."
log "  3. On first zsh launch, since no ~/.p10k.zsh exists yet, the Powerlevel10k configuration wizard will run automatically. Re-run it anytime with: p10k configure"