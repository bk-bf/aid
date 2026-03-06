# tdl

A terminal-native AI development environment built on tmux, Neovim, and [Opencode](https://opencode.ai). It reconstructs the familiar three-pane IDE layout — persistent file browser, tabbed editor, AI assistant — entirely inside a terminal session.

No Electron. No GUI. Runs over SSH.

## Layout

```
┌──────────┬──────────────────────────────┬───────────────┐
│  file    │         nvim editor          │   opencode    │
│ sidebar  │                              │   AI agent    │
│          │         + shell              │               │
└──────────┴──────────────────────────────┴───────────────┘
```

- **Left** — Persistent file sidebar. A separate, isolated `nvim` instance (`NVIM_APPNAME=nvim-treemux`) that stays visible at all times and tracks directory changes globally across `cd` calls.
- **Center** — Main Neovim editor with a shell below. Full LSP, Treesitter, Telescope, bufferline tabs.
- **Right** — Opencode AI assistant in a dedicated tmux pane. Persists across editor restarts and session reattachments.

## What makes this different

Most terminal Neovim setups are *editor configurations* — they configure Neovim itself. `tdl` is a *workspace environment* that orchestrates multiple processes within a tmux session.

**Persistent sidebar, not a toggle.** The file browser is a completely separate Neovim instance with its own isolated config. It never disappears on focus loss, survives editor restarts, and communicates with the main editor over a Unix socket.

**AI as a first-class pane.** The AI assistant lives in a tmux pane alongside the editor, not as a plugin inside Neovim. This means it can read terminal output, persists context across file switches, and doesn't fight Neovim for screen real estate.

**Workspace session state.** `ensure_treemux.sh` is an idempotent session manager — it re-creates the full three-pane layout if it doesn't exist, and attaches to the existing session if it does. The workspace survives reattachments, `cd` calls, and machine restarts.

**Cross-project bookmarks.** A plain-text global bookmark file (`~/.local/share/nvim/global_bookmarks`) that spans all directories and projects, unlike project-scoped mark tools.

**Provider-agnostic AI.** Opencode is MIT-licensed and works with any LLM backend — including free tiers — so there's no vendor dependency baked into the workflow.

**SSH-native.** Because everything runs in tmux, the full IDE environment is available over any SSH connection without forwarding ports or installing desktop software.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/bk-bf/tdl/master/boot.sh | bash
```

Clones to `~/.local/share/tdl` by default. Override with `TDL_DIR`:

```bash
TDL_DIR=~/tdl curl -fsSL https://raw.githubusercontent.com/bk-bf/tdl/master/boot.sh | bash
```

Re-running is safe — the installer is idempotent.

## Usage

```bash
tdl              # open current directory in a new session
tdl myproject    # attach to an existing session named "myproject"
```

Sessions are named `nvim@<dirname>` automatically.

## Requirements

- tmux ≥ 3.2
- nvim ≥ 0.9
- python-pynvim (`sudo pacman -S python-pynvim` on Arch/CachyOS)
- opencode (`npm i -g opencode` or see [opencode.ai](https://opencode.ai))
- A Nerd Font for icons

## What install.sh does

1. Installs `python-pynvim` (Arch/CachyOS only, skipped otherwise)
2. Clones TPM if not present
3. Installs the `kiyoon/treemux` plugin via TPM headless install
4. Creates symlinks:
   - `~/.config/nvim` → `tdl/nvim/` (main nvim config)
   - `~/.config/nvim-treemux/` → `tdl/nvim-treemux/` (isolated sidebar config)
   - `~/.config/tmux/ensure_treemux.sh` → `tdl/ensure_treemux.sh`
5. Bootstraps both nvim configs headlessly via `lazy sync`
6. Injects `source` lines into `~/.config/.aliases` and `~/.config/tmux/.tmux.conf`

## Updating

After `tpm update`, the custom `watch_and_update.sh` symlink gets overwritten. Re-run:

```bash
bash install.sh
```

## License

MIT
