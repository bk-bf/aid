#!/usr/bin/env bash
# boot.sh — curl bootstrapper for tdl
# Usage: curl -fsSL https://raw.githubusercontent.com/bk-bf/tdl/master/boot.sh | bash
set -euo pipefail

REPO="https://github.com/bk-bf/tdl.git"
DEFAULT_DEST="$HOME/.local/share/tdl"
DEST="${TDL_DIR:-$DEFAULT_DEST}"

if [[ -d "$DEST/.git" ]]; then
  echo "==> tdl already cloned at $DEST, pulling latest..."
  git -C "$DEST" pull
else
  echo "==> Cloning tdl into $DEST..."
  git clone "$REPO" "$DEST"
fi

bash "$DEST/install.sh"
