#!/usr/bin/env bash
# install.sh — set up aid on a fresh machine. Run once after cloning.
# Always invoked via boot.sh (directly or via `aid -i`), which ensures it runs
# from the correct install location (~/.local/share/aid by default).
# For branch installs (aid --branch <name>), AID_DATA and AID_CONFIG are passed
# in as env vars by aid.sh — artifacts land in ~/.local/share/aid/<branch> and
# config in ~/.config/aid/<branch>.
# See docs/ARCHITECTURE.md for the full isolation and symlink docs.

set -euo pipefail

AID="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"

# AID_DATA — runtime artifact root (tmux plugins, palette.conf, nvim data).
# AID_CONFIG — personal config root (treemux symlink, lazygit config).
# Both default to the production paths; branch launches override via env.
AID_DATA="${AID_DATA:-$HOME/.local/share/aid}"
AID_CONFIG="${AID_CONFIG:-$HOME/.config/aid}"

TPM_DIR="$AID_DATA/tmux/plugins/tpm"
TREEMUX_DIR="$AID_DATA/tmux/plugins/treemux"
_XDG_DATA="$AID_DATA"
_XDG_STATE="$HOME/.local/state/aid"
_XDG_CACHE="$HOME/.cache/aid"

echo "==> aid install: source=$AID  data=$AID_DATA  config=$AID_CONFIG"

# ── 1. Dependencies ──────────────────────────────────────────────────────────
# Arch/CachyOS: pynvim is required by the treemux watch script
if command -v pacman &>/dev/null && ! python3 -c "import pynvim" &>/dev/null; then
  echo "==> Installing pynvim..."
  sudo pacman -S --needed --noconfirm python-pynvim
fi

# Arch/CachyOS: delta is required by lazygit for diff highlighting
if command -v pacman &>/dev/null && ! command -v delta &>/dev/null; then
  echo "==> Installing delta..."
  sudo pacman -S --needed --noconfirm git-delta
fi

# Arch/CachyOS: bun is required by the aid-sessions.ts navigator
if command -v pacman &>/dev/null && ! command -v bun &>/dev/null; then
  echo "==> Installing bun..."
  sudo pacman -S --needed --noconfirm bun
fi

# ── 2. TPM ───────────────────────────────────────────────────────────────────
if [[ ! -d "$TPM_DIR" ]]; then
  echo "==> Installing TPM..."
  mkdir -p "$AID_DATA/tmux/plugins"
  git clone https://github.com/tmux-plugins/tpm "$TPM_DIR"
else
  echo "==> TPM already present"
fi

# ── 3. Treemux plugin ────────────────────────────────────────────────────────
# Clone directly — TPM's headless install_plugins reads @plugin options from a
# running tmux server and a bare server (no tmux.conf loaded) has none set.
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
echo "==> Creating symlinks and config files under $AID_CONFIG ..."
mkdir -p "$AID_CONFIG"

# ~/.config/aid/treemux/ → aid/nvim-treemux/  (sidebar — NVIM_APPNAME=treemux)
if [[ -d "$AID_CONFIG/treemux" && ! -L "$AID_CONFIG/treemux" ]]; then
  echo "  WARNING: $AID_CONFIG/treemux is a real directory — backing up to $AID_CONFIG/treemux.bak"
  mv "$AID_CONFIG/treemux" "$AID_CONFIG/treemux.bak"
fi
ln -sfn "$AID/nvim-treemux" "$AID_CONFIG/treemux"
echo "  $AID_CONFIG/treemux -> $AID/nvim-treemux"

# lazygit config — copy template if not already present (preserves user edits)
mkdir -p "$AID_CONFIG/lazygit"
if [[ ! -f "$AID_CONFIG/lazygit/config.yml" ]]; then
  cp "$AID/nvim/templates/lazygit.yml" "$AID_CONFIG/lazygit/config.yml"
  echo "  created: $AID_CONFIG/lazygit/config.yml"
else
  echo "  lazygit config already present: $AID_CONFIG/lazygit/config.yml"
fi

# ── 5. nvim plugin bootstrap (headless lazy sync) ────────────────────────────
_spin() {
  local frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0 msg="$1"
  while kill -0 "$2" 2>/dev/null; do
    printf "\r  \033[38;5;208m%s\033[0m  %s" "${frames:$((i%10)):1}" "$msg"
    i=$((i+1)); sleep 0.08
  done
  printf "\r\033[2K"
}

echo "==> Bootstrapping treemux sidebar plugins (lazy sync)..."
XDG_CONFIG_HOME="$AID_CONFIG" XDG_DATA_HOME="$_XDG_DATA" XDG_STATE_HOME="$_XDG_STATE" XDG_CACHE_HOME="$_XDG_CACHE" \
  NVIM_APPNAME=treemux nvim --headless "+Lazy! sync" +qa &
_nvim_pid=$!
_spin "syncing treemux plugins…" "$_nvim_pid"
wait "$_nvim_pid" || echo "  (headless sync exited non-zero — likely fine on first run)"

echo "==> Bootstrapping main nvim plugins (lazy sync)..."
XDG_CONFIG_HOME="$AID" XDG_DATA_HOME="$_XDG_DATA" XDG_STATE_HOME="$_XDG_STATE" XDG_CACHE_HOME="$_XDG_CACHE" \
  NVIM_APPNAME=nvim nvim --headless "+Lazy! sync" +qa &
_nvim_pid=$!
_spin "syncing nvim plugins…" "$_nvim_pid"
wait "$_nvim_pid" || echo "  (headless sync exited non-zero — likely fine on first run)"

# ── 6. Shell integration — symlink aid into PATH ─────────────────────────────
# Only wire the PATH symlink for the production install (AID_DATA == default).
# Branch bootstraps (AID_DATA=~/.local/share/aid/<branch>) don't touch PATH.
if [[ "$AID_DATA" == "$HOME/.local/share/aid" ]]; then
  echo "==> Wiring shell integration..."
  mkdir -p "$HOME/.local/bin"
  ln -sf "$AID/aid.sh" "$HOME/.local/bin/aid"
  echo "==> Symlinked: ~/.local/bin/aid -> $AID/aid.sh"
  echo "==> Ensure ~/.local/bin is on your PATH (it is by default on most distros)."
fi

_branch="$(git -C "$AID" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")"
_commit="$(git -C "$AID" rev-parse --short HEAD 2>/dev/null || echo "unknown")"
echo "==> aid install complete ($( [[ "$_branch" == "HEAD" ]] && echo "detached@${_commit}" || echo "${_branch}@${_commit}" )). Run 'aid' in any directory to launch the IDE."
