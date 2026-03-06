# tdl

A portable terminal IDE layout: **treemux sidebar** | **nvim** | **opencode**, all wired up and ready to clone and run.

## Layout

```
┌──────────┬──────────────────────────────┬───────────────┐
│ nvim-tree│         nvim editor          │   opencode    │
│ sidebar  │                              │               │
│ (21 cols)│         + shell              │   (~29% wide) │
└──────────┴──────────────────────────────┴───────────────┘
```

- **Left**: treemux sidebar (nvim-tree, oil, neo-tree) — isolated `NVIM_APPNAME=nvim-treemux` instance
- **Middle**: your main nvim + a terminal below it
- **Right**: opencode, launched automatically on `tdl`

## Install

Clone anywhere, then run `install.sh`:

```bash
git clone https://github.com/bk-bf/tdl.git
cd tdl
bash install.sh
```

`install.sh` auto-detects its own location and injects the correct paths into
`~/.config/.aliases` and `~/.config/tmux/.tmux.conf`. No hardcoded paths.

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
4. Creates symlinks for `nvim-treemux/` config and `ensure_treemux.sh`
5. Bootstraps nvim-treemux plugins headlessly via `lazy sync`

## Updating treemux plugin

After `tpm update`, the custom `watch_and_update.sh` symlink gets overwritten. Re-run:

```bash
bash install.sh
```
