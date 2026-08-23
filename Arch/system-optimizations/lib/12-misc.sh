#!/usr/bin/env bash
# 12-misc.sh — replaces vim with neovim system-wide, via neovim-symlinksAUR
# (per https://wiki.archlinux.org/title/Neovim and
# https://aur.archlinux.org/packages/neovim-symlinks).
#
# IMPORTANT: neovim-symlinks ships its symlinks (vi, vim, view, ex, vedit,
# edit, vimdiff -> nvim) as normal package-owned files — confirmed via
# `pacman -Ql neovim-symlinks` listing every one of those paths as owned
# by the package, the same as any other package's installed files. That
# means they do NOT persist independently of the package: removing
# neovim-symlinks removes the symlinks along with it, just like removing
# any other package removes its files. There is no "install once, then
# remove" shortcut here — the package must stay installed for the
# symlinks to stay in place, including across neovim version updates.

replace_vim_with_neovim() {
    pkg_install neovim

    if is_pkg_installed neovim-symlinks; then
        log_skip "neovim-symlinks already installed"
        return 0
    fi

    # neovim-symlinks ships /usr/bin/vim itself, which will conflict with
    # the file already owned by the 'vim' package if it's installed —
    # remove 'vim' first so the symlink install doesn't hit a file
    # conflict. (Plain -R, not -Rc/-Rs, so pacman refuses and warns rather
    # than cascading into removing anything that depends on vim.)
    if is_pkg_installed vim; then
        log_info "Removing 'vim' package (being replaced by neovim-symlinks)..."
        pacman -R --noconfirm vim \
            || log_warn "Failed to remove 'vim' (likely a dependent package needs it) — neovim-symlinks install may fail on file conflicts. Resolve manually."
    fi

    aur_install neovim-symlinks
    log_success "vim/vi/ex/view/vedit/edit/vimdiff now symlinked to nvim system-wide (neovim-symlinks package, kept installed)"
}
