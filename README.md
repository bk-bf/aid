# AID

> **Early beta.** Works well day-to-day, but rough edges exist. Arch/CachyOS only for now. Feedback welcome.

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
aid -a           # attach to a running session (interactive list)
aid -a myproject # attach directly by name
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

## Acknowledgements

aid is an orchestration layer — the real work is done by these projects:

**Core**
- [tmux](https://github.com/tmux/tmux) — terminal multiplexer that holds the whole workspace together
- [Neovim](https://github.com/neovim/neovim) — editor and RPC host
- [opencode](https://github.com/opencode-ai/opencode) — AI assistant pane
- [lazygit](https://github.com/jesseduffield/lazygit) — terminal Git UI

**tmux plugins**
- [tpm](https://github.com/tmux-plugins/tpm) — tmux plugin manager
- [treemux](https://github.com/kiyoon/treemux) — persistent sidebar pane manager

**Neovim plugin manager**
- [lazy.nvim](https://github.com/folke/lazy.nvim) — plugin manager

**Neovim plugins**
- [nvim-tree](https://github.com/nvim-tree/nvim-tree.lua) — file explorer
- [nvim-web-devicons](https://github.com/nvim-tree/nvim-web-devicons) — filetype icons
- [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) — fuzzy finder
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim) — Lua utility library
- [gitsigns.nvim](https://github.com/lewis6991/gitsigns.nvim) — git hunk signs and navigation
- [lazygit.nvim](https://github.com/kdheepak/lazygit.nvim) — lazygit inside Neovim
- [bufferline.nvim](https://github.com/akinsho/bufferline.nvim) — tab bar
- [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter) — syntax highlighting
- [nvim-lspconfig](https://github.com/neovim/nvim-lspconfig) — LSP client configuration
- [nvim-cmp](https://github.com/hrsh7th/nvim-cmp) + [cmp-nvim-lsp](https://github.com/hrsh7th/cmp-nvim-lsp) + [cmp-buffer](https://github.com/hrsh7th/cmp-buffer) + [cmp-path](https://github.com/hrsh7th/cmp-path) — autocompletion
- [mini.nvim](https://github.com/echasnovski/mini.nvim) (pairs, cursorword, statusline) — editing utilities and statusline
- [vim-tpipeline](https://github.com/vimpostor/vim-tpipeline) — pipes Neovim statusline into tmux status bar
- [persistence.nvim](https://github.com/folke/persistence.nvim) — session save/restore
- [undotree](https://github.com/mbbill/undotree) — visual undo history
- [which-key.nvim](https://github.com/folke/which-key.nvim) — keymap popup
- [markdown-preview.nvim](https://github.com/iamcco/markdown-preview.nvim) — browser Markdown preview
- [tokyonight.nvim](https://github.com/folke/tokyonight.nvim) — colorscheme
- [oil.nvim](https://github.com/stevearc/oil.nvim) — directory editing
- [neo-tree.nvim](https://github.com/nvim-neo-tree/neo-tree.nvim) — alternative file explorer
- [nui.nvim](https://github.com/MunifTanjim/nui.nvim) — UI components
- [nvim-notify](https://github.com/rcarriga/nvim-notify) — notification popups
- [tmux.nvim](https://github.com/aserowy/tmux.nvim) — tmux/nvim clipboard and navigation sync
- [nvim-tree-remote.nvim](https://github.com/kiyoon/nvim-tree-remote.nvim) — sidebar→editor file open over Unix socket
- [tmux-send.nvim](https://github.com/kiyoon/tmux-send.nvim) — send lines from sidebar to tmux pane

## License

MIT
