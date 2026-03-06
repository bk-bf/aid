# Agents.md — AI coding agent reference for tdl

## What this repo is

tdl is a portable terminal IDE layout built on tmux + treemux + nvim.
It consists of three panes: treemux file-tree sidebar (left), nvim editor + shell (middle), opencode (right).
The full setup — shell functions, tmux config, nvim sidebar config, and install script — lives here so it can be installed independently of the main dotfiles repo.

## Repo layout

```
tdl/
├── install.sh              # one-shot setup: TPM, treemux plugin, symlinks, headless nvim bootstrap
├── aliases.sh              # sourced by ~/.config/.aliases — tdl() launcher, nvim() wrapper
├── tmux.conf               # sourced by ~/.config/tmux/.tmux.conf — treemux plugin config
├── ensure_treemux.sh       # idempotent sidebar opener; symlinked to ~/.config/tmux/ensure_treemux.sh
├── nvim-treemux/
│   ├── treemux_init.lua    # isolated nvim config for the sidebar instance (NVIM_APPNAME=nvim-treemux)
│   └── watch_and_update.sh # custom fork of upstream script; always cd-follows root
└── Agents.md
```

## Symlink map (created by install.sh)

| Repo file | Symlinked to |
|---|---|
| `nvim-treemux/treemux_init.lua` | `~/.config/nvim-treemux/treemux_init.lua` |
| `nvim-treemux/watch_and_update.sh` | `~/.config/nvim-treemux/watch_and_update.sh` |
| `nvim-treemux/watch_and_update.sh` | `~/.config/tmux/plugins/treemux/scripts/tree/watch_and_update.sh` |
| `ensure_treemux.sh` | `~/.config/tmux/ensure_treemux.sh` |

`aliases.sh` and `tmux.conf` are **sourced** (not symlinked) from the dotfiles config files.

## Pane layout and sizes

All pane geometry is owned in `aliases.sh` inside `tdl()`. Nothing in `tmux.conf` sets sizes.

| Pane | Width | How set |
|---|---|---|
| treemux sidebar (left) | 21 cols | `tmux set-option @treemux-tree-width 21` in `tdl()` |
| editor (middle) | remainder | implicit |
| opencode (right) | 29% of total | `tmux split-window -h -p 29` in `tdl()` |

At a 154-col terminal: sidebar=21, editor≈86, opencode≈45.

## Key behaviours

- `tdl` (no args): creates a new `nvim@<dirname>` session, opens nvim in middle, opencode in right, treemux sidebar auto-opens via the `session-created` hook → `ensure_treemux.sh`.
- `tdl <name>`: attaches to an existing named session.
- `nvim()` wrapper: calls `ensure_treemux.sh` before launching nvim when inside tmux, so the sidebar is always open when editing.
- Session names follow the pattern `nvim@<dirname>`, deduplicated with numeric suffix (`nvim@foo2`, etc.).

## nvim-treemux plugins

Managed by lazy.nvim, isolated via `NVIM_APPNAME=nvim-treemux` (data dir: `~/.local/share/nvim-treemux/`).

| Plugin | Purpose |
|---|---|
| `nvim-tree/nvim-tree.lua` | Primary file tree |
| `kiyoon/nvim-tree-remote.nvim` | Opens files from sidebar into the main nvim pane via Unix socket |
| `kiyoon/tmux-send.nvim` | Send lines/selections to tmux panes (`-`, `_`) |
| `stevearc/oil.nvim` | File manager toggle (`<space>o`) |
| `nvim-neo-tree/neo-tree.nvim` | Alternative tree (`<space>nn`) |
| `aserowy/tmux.nvim` | tmux/nvim pane navigation + register sync |
| `folke/tokyonight.nvim` | Colorscheme (tokyonight-night) |

`lazy-lock.json` is excluded from this repo (gitignore). Plugins install at latest on fresh machines.

## watch_and_update.sh — divergence from upstream

Upstream `kiyoon/treemux` only changes the sidebar root when you `cd` *outside* the current root. The custom version (`nvim-treemux/watch_and_update.sh`) changes root on **any** `cd`. This is the only behavioural change from upstream.

After a `tpm update` of treemux, re-run `install.sh` to restore the symlink — TPM overwrites it.

## Integration with the main dotfiles repo (bk-bf/.config)

`~/.config/.aliases` sources this repo's `aliases.sh`:
```bash
source ~/.local/share/tdl/aliases.sh
```

`~/.config/tmux/.tmux.conf` sources this repo's `tmux.conf`:
```bash
source-file ~/.local/share/tdl/tmux.conf
```

The symlinks inside `~/.config/` that point into this repo are hidden via `.git/info/exclude` in the dotfiles repo (not `.gitignore`) so they don't appear as untracked files.

## Repo structure (bare + worktrees)

This repo is cloned bare. Two worktrees are checked out:

| Worktree | Branch | Purpose |
|---|---|---|
| `tdl/main/` | `master` | All code — edit here |
| `tdl/docs/` | `dev-docs` | Private architecture/roadmap/bugs/decisions docs |

The `dev-docs` branch is an orphan — **never merge it into master or any code branch**.

Private docs live in `tdl/docs/`: `ARCHITECTURE.md`, `ROADMAP.md`, `BUGS.md`, `DECISIONS.md`.
