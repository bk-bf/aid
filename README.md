# tdl

An open-source, terminal-native AI IDE. VS Code's layout and Cursor's AI workflow — built on tmux + Neovim + Opencode. No Electron. No vendor lock-in. Runs over SSH.

## Layout

```
┌──────────┬──────────────────────────────┬───────────────┐
│ file     │         nvim editor          │   opencode    │
│ sidebar  │                              │               │
│ (21 cols)│         + shell              │   (~29% wide) │
└──────────┴──────────────────────────────┴───────────────┘
```

- **Left**: persistent treemux sidebar — isolated `NVIM_APPNAME=nvim-treemux` instance, always visible, tracks `cd` globally
- **Middle**: main nvim editor + terminal below
- **Right**: Opencode AI assistant, persistent tmux pane, survives editor restarts

## Why tdl

| | VS Code / Cursor | LazyVim | tdl |
|---|---|---|---|
| Terminal-native | No | Yes | Yes |
| Persistent AI pane | Cursor only (proprietary) | No | Yes (Opencode, MIT) |
| Persistent sidebar | Yes | Toggle only | Yes |
| Cross-project bookmarks | Yes | No (Harpoon is project-scoped) | Yes |
| Workspace session state | Yes | No | Yes |
| SSH-friendly | No | Yes | Yes |
| Single `curl` install | No | No | Yes |

## Install

One-liner:

```bash
curl -fsSL https://raw.githubusercontent.com/bk-bf/tdl/master/boot.sh | bash
```

Clones to `~/.local/share/tdl` by default. Override with `TDL_DIR`:

```bash
TDL_DIR=~/tdl curl -fsSL https://raw.githubusercontent.com/bk-bf/tdl/master/boot.sh | bash
```

`install.sh` auto-injects the correct paths into `~/.config/.aliases` and
`~/.config/tmux/.tmux.conf`. Re-running is safe — idempotent.

## Usage

```bash
tdl           # create new session in current directory
tdl myproject # attach to existing session named "myproject"
```

Session names are auto-generated as `nvim@<dirname>`.

## Requirements

- tmux ≥ 3.2
- nvim ≥ 0.9
- python-pynvim (`sudo pacman -S python-pynvim` on Arch/CachyOS)
- opencode (`npm i -g opencode` or your preferred install)
- A Nerd Font for icons

## What install.sh does

1. Installs `python-pynvim` (Arch/CachyOS only, skipped otherwise)
2. Clones TPM if not present
3. Installs the `kiyoon/treemux` plugin via TPM headless install
4. Creates symlinks:
   - `~/.config/nvim` → `tdl/nvim/` (main nvim config)
   - `~/.config/nvim-treemux/` files → `tdl/nvim-treemux/`
   - `~/.config/tmux/ensure_treemux.sh` → `tdl/ensure_treemux.sh`
5. Bootstraps nvim-treemux and main nvim plugins headlessly via `lazy sync`
6. Injects `source` lines into `~/.config/.aliases` and `~/.config/tmux/.tmux.conf` (idempotent)

## Updating treemux plugin

After `tpm update`, the custom `watch_and_update.sh` symlink gets overwritten. Re-run:

```bash
bash install.sh
```
