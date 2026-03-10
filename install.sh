#!/usr/bin/env bash
# install.sh — set up aid on a fresh machine. Run once after cloning.
# Always invoked via boot.sh (directly or via `aid -i`), which ensures it runs
# from the correct install location (~/.local/share/aid by default).
# See docs/ARCHITECTURE.md for the full isolation and symlink docs.

set -euo pipefail

AID="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"

AID_CONFIG="$HOME/.config/aid"
TPM_DIR="$AID/tmux/plugins/tpm"
TREEMUX_DIR="$AID/tmux/plugins/treemux"
_XDG_DATA="$HOME/.local/share/aid"
_XDG_STATE="$HOME/.local/state/aid"
_XDG_CACHE="$HOME/.cache/aid"

echo "==> aid install: $AID"

# ── Distro detection ──────────────────────────────────────────────────────────
# Returns one of: arch | debian | fedora | alpine | opensuse | macos | unknown
_detect_distro() {
  if [[ "$OSTYPE" == darwin* ]]; then
    echo "macos"; return
  fi
  if command -v pacman &>/dev/null; then
    echo "arch"; return
  fi
  if [[ -f /etc/os-release ]]; then
    local id
    # Check ID_LIKE first (e.g. Ubuntu has ID=ubuntu, ID_LIKE=debian)
    id=$(. /etc/os-release && echo "${ID_LIKE:-}" | tr '[:upper:]' '[:lower:]')
    case "$id" in
      *debian*|*ubuntu*) echo "debian"; return ;;
      *fedora*|*rhel*|*centos*) echo "fedora"; return ;;
      *suse*) echo "opensuse"; return ;;
    esac
    # Fall back to ID
    id=$(. /etc/os-release && echo "${ID}" | tr '[:upper:]' '[:lower:]')
    case "$id" in
      debian|ubuntu|linuxmint|pop) echo "debian"; return ;;
      fedora|rhel|centos|rocky|almalinux) echo "fedora"; return ;;
      alpine) echo "alpine"; return ;;
      opensuse*|sles) echo "opensuse"; return ;;
    esac
  fi
  echo "unknown"
}

DISTRO="$(_detect_distro)"
echo "==> Detected distro family: $DISTRO"

# ── _require helper ───────────────────────────────────────────────────────────
# Usage: _require <cmd>
# Verifies <cmd> exists on PATH; hard-aborts with a distro-specific install hint
# if it is missing. Special case: lsof on Alpine is non-fatal (we use /proc/).
_require() {
  local cmd="$1"
  if command -v "$cmd" &>/dev/null; then return 0; fi

  echo "" >&2
  echo "ERROR: required command '$cmd' not found." >&2
  case "$cmd" in
    tmux)
      case "$DISTRO" in
        arch)     echo "  Install with: sudo pacman -S tmux" >&2 ;;
        debian)   echo "  Install with: sudo apt install tmux" >&2 ;;
        fedora)   echo "  Install with: sudo dnf install tmux" >&2 ;;
        alpine)   echo "  Install with: sudo apk add tmux" >&2 ;;
        opensuse) echo "  Install with: sudo zypper install tmux" >&2 ;;
        macos)    echo "  Install with: brew install tmux" >&2 ;;
        *)        echo "  Install tmux >= 3.2 via your package manager." >&2 ;;
      esac
      exit 1 ;;
    git)
      case "$DISTRO" in
        arch)     echo "  Install with: sudo pacman -S git" >&2 ;;
        debian)   echo "  Install with: sudo apt install git" >&2 ;;
        fedora)   echo "  Install with: sudo dnf install git" >&2 ;;
        alpine)   echo "  Install with: sudo apk add git" >&2 ;;
        opensuse) echo "  Install with: sudo zypper install git" >&2 ;;
        macos)    echo "  Install with: xcode-select --install" >&2 ;;
        *)        echo "  Install git via your package manager." >&2 ;;
      esac
      exit 1 ;;
    node)
      case "$DISTRO" in
        arch)     echo "  Install with: sudo pacman -S nodejs npm" >&2 ;;
        debian)   echo "  Install with: sudo apt install nodejs npm  (or use nvm)" >&2 ;;
        fedora)   echo "  Install with: sudo dnf install nodejs npm" >&2 ;;
        alpine)   echo "  Install with: sudo apk add nodejs npm" >&2 ;;
        opensuse) echo "  Install with: sudo zypper install nodejs npm" >&2 ;;
        macos)    echo "  Install with: brew install node" >&2 ;;
        *)        echo "  Install Node.js from https://nodejs.org or your package manager." >&2 ;;
      esac
      exit 1 ;;
    lsof)
      if [[ "$DISTRO" == "alpine" ]]; then
        # On Alpine, watch_and_update.sh uses /proc/<pid>/cwd — lsof not required
        echo "  Note: lsof is unavailable on Alpine; /proc/<pid>/cwd will be used instead." >&2
        return 0
      fi
      case "$DISTRO" in
        arch)     echo "  Install with: sudo pacman -S lsof" >&2 ;;
        debian)   echo "  Install with: sudo apt install lsof" >&2 ;;
        fedora)   echo "  Install with: sudo dnf install lsof" >&2 ;;
        opensuse) echo "  Install with: sudo zypper install lsof" >&2 ;;
        macos)    echo "  lsof should be pre-installed on macOS." >&2 ;;
        *)        echo "  Install lsof via your package manager." >&2 ;;
      esac
      exit 1 ;;
    curl)
      case "$DISTRO" in
        arch)     echo "  Install with: sudo pacman -S curl" >&2 ;;
        debian)   echo "  Install with: sudo apt install curl" >&2 ;;
        fedora)   echo "  Install with: sudo dnf install curl" >&2 ;;
        alpine)   echo "  Install with: sudo apk add curl" >&2 ;;
        opensuse) echo "  Install with: sudo zypper install curl" >&2 ;;
        macos)    echo "  curl is pre-installed on macOS." >&2 ;;
        *)        echo "  Install curl via your package manager." >&2 ;;
      esac
      exit 1 ;;
    *)
      echo "  Install '$cmd' via your package manager." >&2
      exit 1 ;;
  esac
}

# ── _ver_ge helper ────────────────────────────────────────────────────────────
# Usage: _ver_ge <actual> <minimum>  — returns 0 if actual >= minimum
_ver_ge() {
  printf '%s\n%s\n' "$2" "$1" | sort -V -C
}

# ── 0. Pre-flight checks ──────────────────────────────────────────────────────
echo "==> Running pre-flight checks..."

_require git
_require curl
_require tmux

_tmux_ver=$(tmux -V | sed 's/tmux //')
if ! _ver_ge "$_tmux_ver" "3.2"; then
  echo "ERROR: tmux >= 3.2 required, found $_tmux_ver. Upgrade via your package manager." >&2
  exit 1
fi

_require node
_require lsof   # non-fatal on Alpine (handled inside _require)

# nvim: check presence and version separately — may need AppImage on Debian/Ubuntu
_nvim_ok=0
if command -v nvim &>/dev/null; then
  _nvim_ver=$(nvim --version 2>/dev/null | head -1 | sed 's/NVIM v//')
  if _ver_ge "$_nvim_ver" "0.9.0"; then
    _nvim_ok=1
  fi
fi

echo "==> Pre-flight checks passed."

# ── 1. Ensure nvim >= 0.9 ─────────────────────────────────────────────────────
# Debian/Ubuntu may ship an older nvim; install official AppImage into ~/.local/bin.
# All other distros ship >= 0.9 in their current repos — hard-abort if missing.
if [[ $_nvim_ok -eq 0 ]]; then
  if [[ "$DISTRO" == "debian" ]]; then
    echo "==> nvim < 0.9 (or not found) — installing official AppImage to ~/.local/bin/nvim..."
    _bin_dir="$HOME/.local/bin"
    mkdir -p "$_bin_dir"
    echo "  Fetching latest nvim stable release tag from GitHub..."
    _nvim_tag=$(curl -fsSL "https://api.github.com/repos/neovim/neovim/releases/latest" \
                  | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\(.*\)".*/\1/')
    if [[ -z "$_nvim_tag" ]]; then
      echo "ERROR: Could not fetch nvim release tag from GitHub. Check your internet connection." >&2
      exit 1
    fi
    echo "  Downloading nvim $_nvim_tag AppImage..."
    curl -fsSL \
      "https://github.com/neovim/neovim/releases/download/$_nvim_tag/nvim-linux-x86_64.appimage" \
      -o "$_bin_dir/nvim"
    chmod +x "$_bin_dir/nvim"
    # AppImages require FUSE. If unavailable (common on minimal VMs), extract in-place.
    if ! "$_bin_dir/nvim" --version &>/dev/null 2>&1; then
      echo "  FUSE unavailable — extracting AppImage in place..."
      _extract_dir="$HOME/.local/share/nvim-appimage"
      rm -rf "$_extract_dir"
      mkdir -p "$_extract_dir"
      (cd "$_extract_dir" && "$_bin_dir/nvim" --appimage-extract &>/dev/null) || true
      ln -sf "$_extract_dir/squashfs-root/usr/bin/nvim" "$_bin_dir/nvim"
    fi
    echo "  Installed nvim to $_bin_dir/nvim"
    export PATH="$_bin_dir:$PATH"
    # Verify
    if ! command -v nvim &>/dev/null || \
       ! _ver_ge "$(nvim --version 2>/dev/null | head -1 | sed 's/NVIM v//')" "0.9.0"; then
      echo "ERROR: nvim AppImage install failed — still below 0.9." >&2
      exit 1
    fi
  else
    echo "ERROR: nvim >= 0.9.0 is required but not found." >&2
    case "$DISTRO" in
      arch)     echo "  Install with: sudo pacman -S neovim" >&2 ;;
      fedora)   echo "  Install with: sudo dnf install neovim" >&2 ;;
      alpine)   echo "  Install with: sudo apk add neovim" >&2 ;;
      opensuse) echo "  Install with: sudo zypper install neovim" >&2 ;;
      macos)    echo "  Install with: brew install neovim" >&2 ;;
      *)        echo "  Install neovim >= 0.9 from https://neovim.io" >&2 ;;
    esac
    exit 1
  fi
fi

# ── 2. Dependencies ──────────────────────────────────────────────────────────

# pynvim — required by the treemux watch script (change_root.py / wait_treeinit.py)
echo "==> Checking pynvim..."
if ! python3 -c "import pynvim" &>/dev/null 2>&1; then
  echo "==> Installing pynvim..."
  case "$DISTRO" in
    arch)
      sudo pacman -S --needed --noconfirm python-pynvim
      ;;
    debian)
      # python3-neovim (pynvim) is in the apt repo on most Debian/Ubuntu versions
      if apt-cache show python3-neovim &>/dev/null 2>&1; then
        sudo apt-get install -y python3-neovim
      else
        pip3 install --user pynvim
      fi
      ;;
    fedora)
      pip3 install --user pynvim
      ;;
    alpine)
      pip3 install --user pynvim
      ;;
    opensuse)
      pip3 install --user pynvim
      ;;
    macos)
      pip3 install --user pynvim
      ;;
    *)
      echo "  Unknown distro — attempting: pip3 install pynvim"
      pip3 install --user pynvim || true
      ;;
  esac
fi

# delta (git-delta) — required by lazygit for diff highlighting
echo "==> Checking delta..."
if ! command -v delta &>/dev/null; then
  echo "==> Installing delta..."
  case "$DISTRO" in
    arch)
      sudo pacman -S --needed --noconfirm git-delta
      ;;
    debian)
      # git-delta entered the apt repos in Ubuntu 22.04 / Debian 12
      if apt-cache show git-delta &>/dev/null 2>&1; then
        sudo apt-get install -y git-delta
      else
        echo "  Note: git-delta not available in this distro's repos."
        echo "  Install manually from https://github.com/dandavison/delta/releases for diff highlighting in lazygit."
      fi
      ;;
    fedora)
      echo "  Note: git-delta is not in default Fedora/RHEL repos."
      echo "  Install manually from https://github.com/dandavison/delta/releases for diff highlighting in lazygit."
      ;;
    alpine)
      echo "  Note: git-delta is not available for Alpine."
      echo "  Install manually from https://github.com/dandavison/delta/releases if needed."
      ;;
    opensuse)
      sudo zypper install -y git-delta
      ;;
    macos)
      brew install git-delta
      ;;
    *)
      echo "  Note: Could not install delta automatically."
      echo "  Install manually from https://github.com/dandavison/delta/releases if needed."
      ;;
  esac
fi

# ── 3. TPM ───────────────────────────────────────────────────────────────────
if [[ ! -d "$TPM_DIR" ]]; then
  echo "==> Installing TPM..."
  mkdir -p "$AID/tmux/plugins"
  git clone https://github.com/tmux-plugins/tpm "$TPM_DIR"
else
  echo "==> TPM already present"
fi

# ── 4. Treemux plugin ────────────────────────────────────────────────────────
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

# ── 5. Symlinks ───────────────────────────────────────────────────────────────
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

# ── 6. nvim plugin bootstrap (headless lazy sync) ────────────────────────────
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
_spin "syncing treemux plugins…" $_nvim_pid
wait $_nvim_pid || echo "  (headless sync exited non-zero — likely fine on first run)"

echo "==> Bootstrapping main nvim plugins (lazy sync)..."
XDG_CONFIG_HOME="$AID" XDG_DATA_HOME="$_XDG_DATA" XDG_STATE_HOME="$_XDG_STATE" XDG_CACHE_HOME="$_XDG_CACHE" \
  NVIM_APPNAME=nvim nvim --headless "+Lazy! sync" +qa &
_nvim_pid=$!
_spin "syncing nvim plugins…" $_nvim_pid
wait $_nvim_pid || echo "  (headless sync exited non-zero — likely fine on first run)"

# ── 7. Shell integration — symlink aid into PATH ─────────────────────────────
echo "==> Wiring shell integration..."

mkdir -p "$HOME/.local/bin"
ln -sf "$AID/aid.sh" "$HOME/.local/bin/aid"
echo "==> Symlinked: ~/.local/bin/aid -> $AID/aid.sh"
echo "==> Ensure ~/.local/bin is on your PATH (it is by default on most distros)."

echo ""
echo "==> aid install complete. Run 'aid' in any directory to launch the IDE."
