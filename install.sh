#!/usr/bin/env bash
# install.sh — set up tdl on a fresh machine
# Run once after cloning: bash install.sh
#
# Isolation guarantee
# ───────────────────
# tdl never touches ~/.config/nvim or ~/.config/tmux/.tmux.conf.
# The main editor runs as NVIM_APPNAME=nvim-tdl (config in ~/.config/nvim-tdl).
# The sidebar runs as NVIM_APPNAME=nvim-treemux (config in ~/.config/nvim-treemux).
# tmux runs on a dedicated server socket (tmux -L tdl) with -f pointing directly
# at tdl/tmux.conf, so the user's existing tmux setup is never loaded or modified.
set -euo pipefail

TDL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> tdl install starting from $TDL"

# ── 1. Dependencies ──────────────────────────────────────────────────────────
# Arch/CachyOS: pynvim is required by the treemux watch script
if command -v pacman &>/dev/null; then
  echo "==> Installing pynvim..."
  sudo pacman -S --needed --noconfirm python-pynvim
fi

# ── 2. TPM ───────────────────────────────────────────────────────────────────
TPM_DIR="$HOME/.config/tmux/plugins/tpm"
if [[ ! -d "$TPM_DIR" ]]; then
  echo "==> Installing TPM..."
  git clone https://github.com/tmux-plugins/tpm "$TPM_DIR"
else
  echo "==> TPM already present"
fi

# ── 3. Treemux plugin (via TPM headless install) ──────────────────────────────
TREEMUX_DIR="$HOME/.config/tmux/plugins/treemux"
if [[ ! -d "$TREEMUX_DIR" ]]; then
  echo "==> Installing treemux via TPM..."
  # TPM headless install requires a running tmux server.
  # Use the isolated tdl server so we never touch the user's tmux setup.
  tmux -L tdl -f "$TDL/tmux.conf" new-session -d -s _tdl_install 2>/dev/null || true
  TMUX_PLUGIN_MANAGER_PATH="$HOME/.config/tmux/plugins/" \
    "$TPM_DIR/bin/install_plugins"
  tmux -L tdl kill-session -t _tdl_install 2>/dev/null || true
else
  echo "==> treemux plugin already present"
fi

# ── 4. Symlinks ───────────────────────────────────────────────────────────────
echo "==> Creating symlinks..."

# ~/.config/nvim-tdl → tdl/nvim/  (main editor — isolated from ~/.config/nvim)
if [[ -d "$HOME/.config/nvim-tdl" && ! -L "$HOME/.config/nvim-tdl" ]]; then
  echo "  WARNING: ~/.config/nvim-tdl is a real directory — backing up to ~/.config/nvim-tdl.bak"
  mv "$HOME/.config/nvim-tdl" "$HOME/.config/nvim-tdl.bak"
fi
ln -sfn "$TDL/nvim" "$HOME/.config/nvim-tdl"
echo "  ~/.config/nvim-tdl -> $TDL/nvim"

# ~/.config/nvim-treemux/ → tdl/nvim-treemux/
mkdir -p "$HOME/.config/nvim-treemux"
ln -sf "$TDL/nvim-treemux/treemux_init.lua"    "$HOME/.config/nvim-treemux/treemux_init.lua"
ln -sf "$TDL/nvim-treemux/watch_and_update.sh" "$HOME/.config/nvim-treemux/watch_and_update.sh"
echo "  ~/.config/nvim-treemux/* -> $TDL/nvim-treemux/*"

# treemux plugin's watch script → our custom version
ln -sf "$TDL/nvim-treemux/watch_and_update.sh" \
       "$TREEMUX_DIR/scripts/tree/watch_and_update.sh"

# ~/.config/tmux/ensure_treemux.sh → tdl/ensure_treemux.sh
ln -sf "$TDL/ensure_treemux.sh" "$HOME/.config/tmux/ensure_treemux.sh"

# ── 5. nvim plugin bootstrap (headless lazy sync) ─────────────────────────────
_spin() {
  local frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0 msg="$1"
  while kill -0 "$2" 2>/dev/null; do
    printf "\r  \033[38;5;208m%s\033[0m  %s" "${frames:$((i%10)):1}" "$msg"
    i=$((i+1)); sleep 0.08
  done
  printf "\r\033[2K"
}

echo "==> Bootstrapping nvim-treemux plugins (lazy sync)..."
NVIM_APPNAME=nvim-treemux nvim --headless "+Lazy! sync" +qa 2>/dev/null &
_nvim_pid=$!
_spin "syncing nvim-treemux plugins…" $_nvim_pid
wait $_nvim_pid || echo "  (headless sync exited non-zero — likely fine on first run)"

echo "==> Bootstrapping nvim-tdl plugins (lazy sync)..."
NVIM_APPNAME=nvim-tdl nvim --headless "+Lazy! sync" +qa 2>/dev/null &
_nvim_pid=$!
_spin "syncing nvim-tdl plugins…" $_nvim_pid
wait $_nvim_pid || echo "  (headless sync exited non-zero — likely fine on first run)"

# ── 6. Shell integration — inject aliases source line ────────────────────────
echo "==> Wiring shell integration..."

ALIASES_FILE="$HOME/.config/.aliases"
ALIASES_LINE="source $TDL/aliases.sh"

if [[ -f "$ALIASES_FILE" ]]; then
  if grep -qF "$ALIASES_LINE" "$ALIASES_FILE"; then
    echo "==> $ALIASES_FILE already sources aliases.sh"
  else
    printf '\n# tdl IDE\n%s\n' "$ALIASES_LINE" >> "$ALIASES_FILE"
    echo "==> Added source line to $ALIASES_FILE"
  fi
else
  echo "==> $ALIASES_FILE not found — add manually: $ALIASES_LINE"
fi

echo ""
echo "==> tdl install complete. Run 'tdl' in any directory to launch the IDE."
