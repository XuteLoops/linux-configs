#!/usr/bin/env bash
#
# 00-audio-routing.sh — GUI patchbay/routing tool for the sound server.
#
# We're on pipewire-jack (see 01-daws.sh's JACK conflict handling), so
# qpwgraph is used rather than the older QjackCtl — it's the PipeWire-
# native equivalent, recommended directly by the ArchWiki's PipeWire page
# as QjackCtl's successor, and is in the official extra repo (no AUR
# build needed).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

install_qpwgraph() {
    log_info "Installing qpwgraph (PipeWire routing GUI)..."

    if pkg_install qpwgraph; then
        log_ok "qpwgraph installed."
    else
        log_warn "qpwgraph install failed — check if it's still in the"
        log_warn "official extra repo."
    fi
}

install_qpwgraph
