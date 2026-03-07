# AID

Terminal IDE built on tmux + Neovim + [Opencode](https://opencode.ai). Three persistent panes — file browser, editor, AI assistant — that survive reboots, SSH drops, and branch switches.

![aid screenshot](screenshot-20260307-041411.png)

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/bk-bf/aid/master/boot.sh | bash
```

Installs to `~/.local/share/aid`. Override: `TDL_DIR=~/aid curl ...`

Re-running is safe — idempotent.

## Usage

```bash
aid              # new session in current directory
aid myproject    # attach to existing session
```

Sessions are named `aid@<dirname>` automatically.

## What makes it different

Most Neovim setups configure the editor. aid orchestrates a full workspace.

**Persistent sidebar.** The file browser is a separate, isolated `nvim` instance (`NVIM_APPNAME=nvim-treemux`). It never closes, survives editor restarts, and communicates with the main editor over a Unix socket.

**AI as a first-class pane.** Opencode lives in a tmux pane, not a plugin. It persists context across file switches and can read your terminal output directly.

**Git-sync coordinator.** A central `sync.lua` module refreshes gitsigns, nvim-tree, and the sidebar after every branch switch — no stale state after lazygit.

**Cross-project bookmarks.** A global plain-text file (`~/.local/share/nvim/global_bookmarks`) that works across unrelated directories, unlike project-scoped tools.

**SSH-native.** Everything runs in tmux — detach, reattach, or connect from another machine without losing state.

## Requirements

- tmux ≥ 3.2
- nvim ≥ 0.9
- python-pynvim (`sudo pacman -S python-pynvim` on Arch/CachyOS)
- opencode (`npm i -g opencode` or see [opencode.ai](https://opencode.ai))
- A Nerd Font

## Updating

```bash
bash install.sh
```

Safe to re-run after `tpm update` — restores the custom `watch_and_update.sh` symlink.

## License

MIT
