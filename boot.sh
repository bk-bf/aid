#!/usr/bin/env bash
# boot.sh — curl bootstrapper for aid
# Usage: curl -fsSL https://raw.githubusercontent.com/bk-bf/aid/master/boot.sh | bash
set -euo pipefail

REPO="https://github.com/bk-bf/aid.git"
DEFAULT_DEST="$HOME/.local/share/aid"
DEST="${TDL_DIR:-$DEFAULT_DEST}"

if git -C "$DEST" rev-parse --git-dir &>/dev/null 2>&1; then
  echo "==> aid already installed at $DEST, pulling latest..."
  git -C "$DEST" pull
else
  echo "==> Cloning aid into $DEST..."
  git clone "$REPO" "$DEST"
fi

bash "$DEST/install.sh"
