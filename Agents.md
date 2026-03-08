# Agents.md — AI coding agent reference for aid

## Agent rules

- **Never commit or push to git unprompted.** Always wait for the user to explicitly ask, or for a slash command (e.g. `/commit`) to trigger it. This applies even when completing a large task — finish all code changes, then stop and wait. The user may have staged changes of their own that must not be conflated into your commit.
- **Roadmap task references**: open tasks in `docs/ROADMAP.md` are numbered `T-NNN` (e.g. `T-002`). When referencing a roadmap item in code comments, ADRs, bug notes, or commit messages, use the task number, not a description.

## What this repo is

aid is an open-source, terminal-native AI IDE: tmux workspace orchestration + nvim config + persistent Opencode AI pane, all in one repo.

Three persistent panes: file-tree sidebar (left), nvim editor + shell (middle), Opencode AI assistant (right). A single `boot.sh` curl gives a fully working IDE on any machine. No dotfiles repo required.

**Identity**: not a Neovim distribution (like LazyVim) — a *workspace environment* that orchestrates multiple nvim instances and tmux panes. LazyVim configures an editor; aid builds a workspace around one.

## Repo layout

```
aid/                            ← bare git repo root
├── main/                       ← master branch worktree (all code lives here)
│   ├── boot.sh                 # curl bootstrapper — clones repo then runs install.sh
│   ├── install.sh              # one-shot setup: TPM, treemux, symlinks, headless nvim bootstrap
│   ├── aid.sh                  # main entry point — symlinked to ~/.local/bin/aid by install.sh
│   ├── tmux.conf               # loaded via -f on the dedicated tmux server socket
│   ├── ensure_treemux.sh       # idempotent sidebar opener; enforces 3-pane layout proportions
│   ├── .aidignore              # patterns hidden from nvim-tree and Telescope (parsed by aid.sh at launch)
│   ├── nvim/
│   │   ├── init.lua            # main nvim config (plugins, LSP, keymaps, options, autocmds)
│   │   ├── cheatsheet.md       # styled welcome buffer — opens on fresh aid launch, <leader>?
│   │   ├── lazy-lock.json      # plugin lockfile
│   │   └── lua/
│   │       ├── sync.lua        # central git-sync coordinator (see below)
│   │       └── aidignore.lua   # reads AID_IGNORE env var, returns patterns for nvim-tree + Telescope
│   ├── nvim-treemux/
│   │   ├── treemux_init.lua    # isolated nvim config for sidebar (NVIM_APPNAME=treemux)
│   │   └── watch_and_update.sh # custom fork — cd-follows root on any cd, not just exit
│   ├── opencode/
│   │   └── commands/           # custom slash commands (commit.md, udoc.md)
│   ├── README.md
│   └── Agents.md
└── docs/                       ← dev-docs branch worktree (orphan, never merge into master)
    ├── ARCHITECTURE.md
    ├── ROADMAP.md
    ├── DECISIONS.md
    └── BUGS.md
```

## Environment isolation (ADR-006)

aid is fully isolated from the user's existing nvim and tmux setup. Nothing is shared.


| Component | Isolation mechanism |
|---|---|
| tmux | Dedicated server socket: `tmux -L aid -f <AID_DIR>/tmux.conf` |
| main nvim | `XDG_CONFIG_HOME=$AID_DIR` + `NVIM_APPNAME=nvim` → config at `$AID_DIR/nvim` (no symlink needed) |
| sidebar nvim | `XDG_CONFIG_HOME=$AID_DIR` + `NVIM_APPNAME=treemux` — treemux resolves to `~/.config/aid/treemux` symlink → `aid/nvim-treemux/` |
| opencode | `OPENCODE_CONFIG_DIR=$AID_DIR/opencode` → `aid/opencode/`, not `~/.config/opencode` |
| install.sh | Does **not** inject into `~/.config/tmux/.tmux.conf` or `~/.bashrc` |
| aid.sh | Standalone script in `~/.local/bin/aid` — no shell function injection |

`~/.config/nvim` is never touched. All `tmux` calls in scripts use `tmux -L aid`.

## Symlink map (created by install.sh)

| Repo path | Symlinked to |
|---|---|
| `aid.sh` | `~/.local/bin/aid` |
| `nvim-treemux/` | `~/.config/aid/treemux` |
| `nvim-treemux/watch_and_update.sh` | `~/.config/tmux/plugins/treemux/scripts/tree/watch_and_update.sh` |
| `ensure_treemux.sh` | `~/.config/tmux/ensure_treemux.sh` |

`aid.sh` is a standalone script in PATH (not sourced). `tmux.conf` is loaded via `-f` on the dedicated server socket (not sourced from the user's tmux config). Main nvim (`NVIM_APPNAME=nvim`) resolves config directly to `$AID_DIR/nvim` via `XDG_CONFIG_HOME=$AID_DIR` — no symlink in `~/.config/` required.

## Pane layout and sizes

All pane geometry is owned in `aid.sh`. Nothing in `tmux.conf` sets sizes.
`ensure_treemux.sh` enforces the opencode pane width after the sidebar opens.

| Pane | Width | How set |
|---|---|---|
| treemux sidebar (left) | 26 cols | `@treemux-tree-width 26` in `tmux.conf` |
| editor (middle) | remainder | implicit |
| opencode (right) | 28% of total | `tmux -L aid split-window -h -p 29` + `ensure_treemux.sh` resize |

## Key behaviours

- `aid` (no args): creates `aid@<dirname>` session on the `aid` tmux socket (`tmux -L aid`); opens `NVIM_APPNAME=nvim nvim` in middle, opencode in right, treemux sidebar via `ensure_treemux.sh`.
- `aid -a <name>`: attaches to an existing named session on the `aid` tmux socket.
- On fresh launch (no file arg), nvim opens `cheatsheet.md` as a styled read-only welcome buffer. Opening any file auto-dismisses it. `<leader>?` reopens it.
- netrw is fully disabled (`loaded_netrw = 1`); nvim-tree handles all file browsing.
- `showtabline = 2` — bufferline tab bar always visible from launch.

## Git-sync coordinator (`nvim/lua/sync.lua`)

Central coordination point for post-branch-switch refresh. Prevents stale state in all git-aware components when lazygit switches branches.

**Two entry points:**

`sync.sync()` — lightweight, safe to call from autocmds:
1. `silent! checktime` — reload buffers changed on disk
2. `gitsigns.refresh()` — re-read HEAD, recompute hunk signs + branch name
3. `nvim-tree.api.tree.reload()` — full tree rebuild + git status
4. `tmux -L aid send-keys` to treemux sidebar → `:lua require('aidignore').reset()`

`sync.reload()` — full workspace reload, bound to `<leader>R`:
1. `tmux -L aid source-file <AID_DIR>/tmux.conf`
2. `source $MYVIMRC`
3. `sync.sync()`

**Trigger points for `sync.sync()`:**
- `FocusGained` / `BufEnter` / `CursorHold` autocmds
- `TermClose` autocmd (lazygit float closes)
- Explicit call after `vim.cmd("LazyGit")` in `<leader>gg` keybind

**Sidebar pane lookup**: reads tmux option `@-treemux-registered-pane-$TMUX_PANE` (written by `ensure_treemux.sh`).

**Treemux self-heal** (`treemux_init.lua`): `FileChangedShell` sets `vim.v.fcs_choice = "reload"` (suppresses blocking prompt) + rebuilds nvim-tree. `FileChangedShellPost` does `silent! checktime` + rebuild.

## Unique features

- **Persistent sidebar**: separate `NVIM_APPNAME=treemux` nvim instance in its own tmux pane — tmux-level isolation means no nvim terminal/split can bleed into it; tracks any `cd` via custom `watch_and_update.sh`.
- **Git-sync coordinator**: `sync.lua` refreshes all git-aware components after branch switches — gitsigns, nvim-tree, treemux sidebar, buffers.
- **Cross-project bookmarks**: `~/.local/share/aid/nvim/global_bookmarks` — works across unrelated directories, unlike Harpoon (project-scoped). `<leader>ba/bd/bb`.
- **Unified statusline**: `vim-tpipeline` exports nvim statusline to the tmux status bar, visible across all panes.
- **Lazygit worktree fix**: `<leader>gg` uses `git rev-parse --git-dir` (not `--git-common-dir`) to set `GIT_DIR`/`GIT_WORK_TREE` — correct for bare-repo worktrees.
- **Full environment isolation**: dedicated `tmux -L aid` server + `XDG_CONFIG_HOME=$AID_DIR`. Zero conflict with existing nvim/tmux config.

## Main nvim plugins

| Plugin | Purpose |
|---|---|
| `nvim-tree/nvim-tree.lua` | File tree (netrw disabled) |
| `lewis6991/gitsigns.nvim` | Git hunk signs + `<leader>j/k/hp/hl` |
| `kdheepak/lazygit.nvim` | Lazygit float (`<leader>gg`) |
| `nvim-telescope/telescope.nvim` | Fuzzy find (`<leader>f/1/2`) |
| `akinsho/bufferline.nvim` | Tab bar (always visible, `showtabline=2`) |
| `echasnovski/mini.statusline` | Statusline content (hidden, piped to tmux) |
| `vimpostor/vim-tpipeline` | Embed nvim statusline into tmux status bar |
| `folke/persistence.nvim` | Session save/restore (`<leader>ss/sl/sd`) |
| `mbbill/undotree` | Undo history tree (`<leader>u`) |
| `neovim/nvim-lspconfig` + `hrsh7th/nvim-cmp` | LSP + autocompletion (gopls by default) |
| `nvim-treesitter/nvim-treesitter` | Syntax highlighting |
| `iamcco/markdown-preview.nvim` | Browser preview (`<leader>mp/ms`) |
| `folke/which-key.nvim` | Keymap help popup |

## nvim-treemux plugins

| Plugin | Purpose |
|---|---|
| `nvim-tree/nvim-tree.lua` | Primary file tree |
| `kiyoon/nvim-tree-remote.nvim` | Opens files from sidebar into main nvim via Unix socket |
| `kiyoon/tmux-send.nvim` | Send lines/selections to tmux panes (`-`, `_`) |
| `stevearc/oil.nvim` | File manager toggle (`<space>o`) |
| `nvim-neo-tree/neo-tree.nvim` | Alternative tree (`<space>nn`) |
| `aserowy/tmux.nvim` | tmux/nvim pane navigation + register sync |
| `folke/tokyonight.nvim` | Colorscheme (tokyonight-night, transparent) |

## Repo structure (bare + worktrees)

```
aid/              ← bare git root
├── main/         ← master branch (worktree) — all code
└── docs/         ← dev-docs branch (orphan worktree) — private docs
```

`aid/main/.git` and `aid/docs/.git` are files (worktree gitdir pointers), not directories.

The `dev-docs` branch is an orphan — **never merge into master or any code branch**.

For lazygit from inside a worktree: use `git rev-parse --git-dir` (returns `aid/worktrees/main`), not `--git-common-dir` (returns bare root — causes phantom deleted files).
