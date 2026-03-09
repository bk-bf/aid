#!/usr/bin/env bash
# install.sh — set up aid on a fresh machine
# Run once after cloning: bash install.sh
#
# Isolation guarantee
# ───────────────────
# aid never touches ~/.config/nvim or ~/.config/tmux/.tmux.conf.
# Main editor config is resolved directly at launch time:
#   XDG_CONFIG_HOME=$AID_DIR, NVIM_APPNAME=nvim → $AID_DIR/nvim (no symlink)
# Sidebar uses a symlink for its config (nvim-treemux lives outside $AID_DIR):
#   ~/.config/aid/treemux → aid/nvim-treemux/ (sidebar, NVIM_APPNAME=treemux)
# tmux plugins land in $AID_DIR/tmux/plugins/ (never ~/.config/tmux/plugins/).
# tmux runs on a dedicated server socket (tmux -L aid) with -f pointing directly
# at aid/tmux.conf, so the user's existing tmux setup is never loaded or modified.
set -euo pipefail

AID="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# All aid config lives under a single XDG root so the user has one place to look.
AID_CONFIG="$HOME/.config/aid"

echo "==> aid install starting from $AID"

# ── 1. Dependencies ──────────────────────────────────────────────────────────
# Arch/CachyOS: pynvim is required by the treemux watch script
if command -v pacman &>/dev/null; then
  echo "==> Installing pynvim..."
  sudo pacman -S --needed --noconfirm python-pynvim
fi

# ── 2. TPM ───────────────────────────────────────────────────────────────────
TPM_DIR="$AID/tmux/plugins/tpm"
if [[ ! -d "$TPM_DIR" ]]; then
  echo "==> Installing TPM..."
  git clone https://github.com/tmux-plugins/tpm "$TPM_DIR"
else
  echo "==> TPM already present"
fi

# ── 3. Treemux plugin ────────────────────────────────────────────────────────
# Clone directly — TPM's headless install_plugins reads @plugin options from a
# running tmux server and a bare server (no tmux.conf loaded) has none set.
TREEMUX_DIR="$AID/tmux/plugins/treemux"
if [[ ! -d "$TREEMUX_DIR" ]]; then
  echo "==> Installing treemux..."
  git clone https://github.com/kiyoon/treemux "$TREEMUX_DIR"
  # Patch treemux's watch script with our custom version
  ln -sf "$AID/nvim-treemux/watch_and_update.sh" \
         "$TREEMUX_DIR/scripts/tree/watch_and_update.sh"
else
  echo "==> treemux already present"
fi

# ── 4. Symlinks ───────────────────────────────────────────────────────────────
# The main editor (NVIM_APPNAME=nvim) no longer needs a symlink: aid.sh sets
# XDG_CONFIG_HOME=$AID_DIR at launch time, so nvim resolves its config directly
# to $AID_DIR/nvim — no entry in ~/.config/aid/ required.
#
# The sidebar (NVIM_APPNAME=treemux) still needs a symlink because nvim-treemux/
# lives in its own shipped location and is not co-located with $AID.
echo "==> Creating symlinks under $AID_CONFIG ..."
mkdir -p "$AID_CONFIG"

# ~/.config/aid/treemux/ → aid/nvim-treemux/  (sidebar — NVIM_APPNAME=treemux)
if [[ -d "$AID_CONFIG/treemux" && ! -L "$AID_CONFIG/treemux" ]]; then
  echo "  WARNING: $AID_CONFIG/treemux is a real directory — backing up to $AID_CONFIG/treemux.bak"
  mv "$AID_CONFIG/treemux" "$AID_CONFIG/treemux.bak"
fi
ln -sfn "$AID/nvim-treemux" "$AID_CONFIG/treemux"
echo "  $AID_CONFIG/treemux -> $AID/nvim-treemux"

# ── 5. nvim plugin bootstrap (headless lazy sync) ─────────────────────────────
_spin() {
  local frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0 msg="$1"
  while kill -0 "$2" 2>/dev/null; do
    printf "\r  \033[38;5;208m%s\033[0m  %s" "${frames:$((i%10)):1}" "$msg"
    i=$((i+1)); sleep 0.08
  done
  printf "\r\033[2K"
}

echo "==> Bootstrapping treemux sidebar plugins (lazy sync)..."
XDG_CONFIG_HOME="$AID_CONFIG" XDG_DATA_HOME="$HOME/.local/share/aid" XDG_STATE_HOME="$HOME/.local/state/aid" XDG_CACHE_HOME="$HOME/.cache/aid" \
  NVIM_APPNAME=treemux nvim --headless "+Lazy! sync" +qa &
_nvim_pid=$!
_spin "syncing treemux plugins…" $_nvim_pid
wait $_nvim_pid || echo "  (headless sync exited non-zero — likely fine on first run)"

echo "==> Bootstrapping main nvim plugins (lazy sync)..."
XDG_CONFIG_HOME="$AID" XDG_DATA_HOME="$HOME/.local/share/aid" XDG_STATE_HOME="$HOME/.local/state/aid" XDG_CACHE_HOME="$HOME/.cache/aid" \
  NVIM_APPNAME=nvim nvim --headless "+Lazy! sync" +qa &
_nvim_pid=$!
_spin "syncing nvim plugins…" $_nvim_pid
wait $_nvim_pid || echo "  (headless sync exited non-zero — likely fine on first run)"

# ── 6. Shell integration — symlink aid into PATH ─────────────────────────────
echo "==> Wiring shell integration..."

mkdir -p "$HOME/.local/bin"
ln -sf "$AID/aid.sh" "$HOME/.local/bin/aid"
echo "==> Symlinked: ~/.local/bin/aid -> $AID/aid.sh"
echo "==> Ensure ~/.local/bin is on your PATH (it is by default on most distros)."

echo ""
echo "==> aid install complete. Run 'aid' in any directory to launch the IDE."
