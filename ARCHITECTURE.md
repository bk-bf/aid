<!-- LOC cap: 427 (source: 3052, ratio: 0.14, updated: 2026-03-09) -->
# Architecture

## Overview

aid is an open-source, terminal-native AI IDE: tmux workspace orchestration + nvim config + persistent Opencode AI pane, all in one repo.

It reconstructs the VS Code/Cursor UX entirely in the terminal — no Electron, no GUI, SSH-friendly. Three persistent panes: file-tree sidebar (left), nvim editor (middle), Opencode AI assistant (right). A single `boot.sh` curl gives a fully working IDE on any machine.

**Identity**: not a Neovim distribution (like LazyVim) — a *workspace environment* that orchestrates multiple nvim instances and tmux panes into a cohesive IDE. LazyVim configures an editor; aid builds a workspace around one.

Install path: `~/.local/share/aid` (override: `AID_DIR`).

## Boot sequence

```
boot.sh (curl | bash)
  └── git clone → $DEST   (or git pull if already installed)
  └── install.sh
        ├── 1. pynvim (Arch only)
        ├── 2. TPM clone
        ├── 3. treemux plugin via TPM headless (tmux -L aid -f <AID_DIR>/tmux.conf)
        ├── 4. symlinks:
        │       ~/.config/aid/treemux                              → aid/nvim-treemux/
        │       $AID_DIR/tmux/plugins/treemux/.../watch_and_update.sh → aid/nvim-treemux/
        │       ~/.local/bin/aid                                   → aid/aid.sh
        │       (main nvim: no symlink — XDG_CONFIG_HOME=$AID_DIR is injected inline on the nvim respawn-pane command; DATA/STATE/CACHE go to ~/.local/{share,state}|.cache/aid)
        ├── 5. nvim-treemux headless lazy sync  (NVIM_APPNAME=treemux) ← spinner
        ├── 5b. main nvim headless lazy sync    (NVIM_APPNAME=nvim)    ← spinner
        └── 6. (no shell injection — aid is a standalone script in PATH)
```

## Runtime sequence (`aid` command)

`aid.sh` is a standalone script symlinked into `~/.local/bin/aid`. `AID_DIR` is resolved via `realpath "${BASH_SOURCE[0]}"` — no shell function, no `aliases.sh` dependency.

### Session routing

```
aid -l / --list    → list sessions (tmux list-sessions) and exit
aid -a             → interactive list; auto-attach if only one session
aid -a <name>      → attach to named session directly and exit
aid -i / --install → (re)run install.sh — install/update plugins and symlinks
aid --update       → git pull + re-run install.sh (alias for -i)
aid --branch <name>→ clone/pull remote branch into ~/.local/share/aid/<name>,
                     bootstrap on first use, re-exec into that branch's aid.sh
aid --no-ai        → create session without the opencode pane (T-009)
aid               → create a new session in $PWD
```

`attach_or_switch` helper uses `switch-client` when already inside tmux (attach fails inside a session).

### Session creation

```
aid.sh
  ├── resolve AID_DIR via realpath
  ├── session name: <prefix>@<basename> (deduplicated with numeric suffix)
  │     prefix = git branch of AID_DIR; "main"/"HEAD"/empty → "aid"
  ├── parse .aidignore (walks up from launch_dir, up to 20 levels)
  ├── gen-tmux-palette.sh (generates tmux/palette.conf from nvim/lua/palette.lua)
  ├── tmux -L aid -f <AID_DIR>/tmux.conf new-session -d -s <session>
   ├── set-environment -g:
   │       AID_DIR                  → <AID_DIR>
   │       AID_IGNORE               → comma-separated .aidignore entries
   │       OPENCODE_CONFIG_DIR      → <AID_DIR>/opencode
   │       OPENCODE_TUI_CONFIG      → <AID_DIR>/opencode/tui-config.json
   │       TMUX_PLUGIN_MANAGER_PATH → <AID_DIR>/tmux/plugins/tpm
   │       NVIM_APPNAME             → nvim
   │       XDG_DATA_HOME            → ~/.local/share/aid   (nvim plugin data → ~/.local/share/aid/nvim/)
   │       XDG_STATE_HOME           → ~/.local/state/aid   (nvim shada/swap  → ~/.local/state/aid/nvim/)
   │       XDG_CACHE_HOME           → ~/.cache/aid         (nvim cache       → ~/.cache/aid/nvim/)
   │   set-environment -t <session>:
   │       AID_NVIM_SOCKET     → /tmp/aid-nvim-<session>.sock  (session-local)
  ├── set @treemux-key-Tab / @treemux-key-Bspace directly (sidebar.tmux targets default
  │       tmux socket, not -L aid — so aid.sh sets the options itself)
  ├── capture editor_pane_id (list-panes -F "#{pane_id}" | head -1)
  ├── split-window -h -p 29 → spawned directly into opencode process
  │       (skipped when --no-ai is set — editor + sidebar only)
  │       (no shell prompt — bypasses zsh autocorrect, no send-keys mangling)
  │       capture opencode_pane_id
  ├── select-pane editor_pane_id  (skipped when --no-ai)
  ├── run-shell ensure_treemux.sh -t editor_pane_id  (opens sidebar)
  ├── respawn-pane -k editor_pane_id → nvim restart loop
   │       cd <launch_dir>; while true; do
   │         rm -f <nvim_socket>
   │         XDG_CONFIG_HOME=<AID_DIR>
   │         XDG_DATA_HOME=~/.local/share/aid  XDG_STATE_HOME=~/.local/state/aid
   │         XDG_CACHE_HOME=~/.cache/aid
   │         LG_CONFIG_FILE=<AID_DIR>/lazygit.yml
   │         NVIM_APPNAME=nvim nvim --listen <nvim_socket>
   │       done
  │       (bypasses interactive shell entirely — zsh autocorrect/send-keys
  │        mangling cannot fire; pane is never a bare shell)
  └── attach -t <session>
```

### Editor pane restart loop

The editor pane is respawned via `respawn-pane -k` directly into the nvim restart loop — bypassing the interactive shell entirely. When the user quits nvim (`:q`), the loop immediately restarts it on the same socket path. The pane is **never** a bare shell — the only way to exit is to close the tmux window.

### Stable pane IDs

`editor_pane_id` and `opencode_pane_id` are captured by stable `#{pane_id}` tokens immediately after creation. Subsequent operations (treemux inserting the sidebar, layout changes) do not affect them.

## Environment variables (tmux server scope)

Set via `tmux -L aid set-environment -g` before any pane is created. All child shells inherit them automatically. `XDG_CONFIG_HOME` is **not** global — it is injected inline only on the nvim `respawn-pane` command and the treemux `@treemux-nvim-command` option, so it does not leak into opencode or other panes. `LG_CONFIG_FILE` is similarly injected inline on the `respawn-pane` command only.

| Variable | Value | Purpose |
|---|---|---|
| `AID_DIR` | path to `aid/main/` | Lets scripts locate the repo without assumptions about install path |
| `AID_IGNORE` | comma-separated patterns | Populated from `.aidignore` (found by walking up from `$PWD`) |
| `NVIM_APPNAME` | `nvim` | Main editor appname; with `XDG_CONFIG_HOME=$AID_DIR` (inline) resolves config to `$AID_DIR/nvim` |
| `XDG_DATA_HOME` | `~/.local/share/aid` | nvim plugin data / lazy.nvim → `~/.local/share/aid/nvim/` — not `~/.local/share/nvim/` |
| `XDG_STATE_HOME` | `~/.local/state/aid` | nvim shada / swap / undo → `~/.local/state/aid/nvim/` — not `~/.local/state/nvim/` |
| `XDG_CACHE_HOME` | `~/.cache/aid` | nvim cache → `~/.cache/aid/nvim/` — not `~/.cache/nvim/` |
| `OPENCODE_CONFIG_DIR` | `$AID_DIR/opencode` | Isolates opencode config from `~/.config/opencode` |
| `OPENCODE_TUI_CONFIG` | `$AID_DIR/opencode/tui-config.json` | Points opencode at aid's TUI config (theme, layout) |
| `TMUX_PLUGIN_MANAGER_PATH` | `$AID_DIR/tmux/plugins/tpm` | Needed by TPM scripts running inside the aid server |
| `AID_NVIM_SOCKET` | `/tmp/aid-nvim-<session>.sock` | Sidebar nvim reads at startup to set `g:nvim_tree_remote_socket_path`; set session-local (`-t`) so multiple concurrent sessions don't clobber each other |

## Pane ownership

All pane geometry is owned by `aid.sh` and `ensure_treemux.sh`. `tmux.conf` owns only plugin config and keybinds — **never sizes** — with one exception: `@treemux-tree-width 26` must live in `tmux.conf` so treemux reads it before `sidebar.tmux` runs.

`aid.sh` does the initial editor/opencode split at `-p 29` (29% for opencode). After `ensure_treemux.sh` opens the sidebar, it re-enforces the opencode column count to 28% of the total window width via `resize-pane -x`.

## Isolation strategy

aid runs entirely isolated from the user's existing nvim and tmux setup.

| Layer | Isolation mechanism |
|---|---|
| tmux server | `tmux -L aid` — dedicated named socket, separate from the default server |
| tmux config | `tmux -L aid -f <AID_DIR>/tmux.conf` — `-f` suppresses `~/.tmux.conf` and `~/.config/tmux/tmux.conf` entirely |
| tmux plugins | TPM and all plugins installed under `$AID_DIR/tmux/plugins/` — not `~/.config/tmux/plugins/` |
| main nvim | `XDG_CONFIG_HOME=$AID_DIR` (config source) + `XDG_DATA_HOME=~/.local/share/aid`, `XDG_STATE_HOME=~/.local/state/aid`, `XDG_CACHE_HOME=~/.cache/aid`; with `NVIM_APPNAME=nvim` all nvim paths resolve under the respective `aid/nvim/` subdirs |
| sidebar nvim | `XDG_CONFIG_HOME=~/.config/aid` + `NVIM_APPNAME=treemux` → config at `~/.config/aid/treemux/` → `aid/nvim-treemux/`; data/state/cache → `~/.local/share/aid/treemux/`, etc. |
| opencode | `OPENCODE_CONFIG_DIR=$AID_DIR/opencode` — commands and package.json at `aid/opencode/`, not `~/.config/opencode` |
| shell | `aid` is a standalone script in `~/.local/bin` — no shell function injection, no `~/.bashrc` modification |

Symlink table:

| Config path | Points to |
|---|---|
| `~/.config/aid/treemux` | `aid/nvim-treemux/` |
| `$AID_DIR/tmux/plugins/treemux/.../watch_and_update.sh` | `aid/nvim-treemux/watch_and_update.sh` |
| `~/.local/bin/aid` | `aid/aid.sh` |

`~/.config/nvim`, `~/.config/aid/nvim`, and `~/.config/tmux/` are **not touched** — the user's existing nvim and tmux config (if any) is preserved.

## `nvim/init.lua` structure

The load order within `init.lua` is intentional and must be preserved:

```
1. LEADER KEY           — vim.g.mapleader before any plugin reads it
2. netrw disable        — vim.g.loaded_netrw before VimEnter
3. OPTIONS              — vim.opt.* globals before plugins/autocmds fire
                          (critical: autocmds reading vim.o.number must see
                          the global value, not Neovim's built-in default)
                          includes: vim.opt.exrc = true + vim.opt.secure = true
                          for per-project .nvim.lua support
4. PALETTE              — local p = require("palette")  (colors available to plugin opts)
5. GIT-SYNC require     — local sync = require("sync")
6. CHEATSHEET           — _cs_open() (plain edit, no styling/autocmds/buffer tracking)
7. BOOTSTRAP LAZY       — vim.opt.rtp:prepend(lazypath)
8. KEYMAPS              — vim.keymap.set() calls (reference sync, _cs_open, etc.)
9. PLUGINS              — require("lazy").setup({...})
                          includes: persistence.nvim for session save/restore
                          includes: nvim-cmp (autocompletion), mason + mason-lspconfig,
                          nvim-lspconfig, conform.nvim (format on save), nvim-lint
10. APPEARANCE          — _G.apply_palette(): nvim_set_hl for all groups + guicursor
11. DIAGNOSTICS         — vim.diagnostic.config()
12. AUTOCMDS            — FileType, FocusGained, TermClose, DirChanged, VimEnter
```

The `VimEnter` autocmd (opens nvim-tree outside tmux; opens cheatsheet on empty buffer) lives at the **top level** of `init.lua` in the AUTOCMDS section — not inside any plugin's `config` function. Plugin `config` functions run during `lazy.setup()`, which itself runs before `VimEnter` fires. Registering a `VimEnter` autocmd inside a plugin config is safe only if the plugin loads eagerly before `VimEnter`; for reliability, top-level registration is required.

## Cheatsheet system

`nvim/cheatsheet.md` is opened as a normal file buffer (`vim.cmd("edit " .. path)`) when nvim starts with no file argument. No special read-only styling, no buffer tracking, no window-option autocmds — just a plain `edit`. Re-open at any time with `<leader>?`. Dismissed by opening any other file; no auto-restore logic.

The path is built from `AID_DIR` (env, real path) rather than `stdpath("config")` (symlink) to avoid W13 "file created after editing started" on writes.

## Autocompletion (`nvim-cmp`)

`hrsh7th/nvim-cmp` provides the completion popup. It is configured to auto-show on every keypress (`completeopt = "menu,menuone,noinsert"`) — no manual trigger required. Keymaps: `<Tab>`/`<S-Tab>` navigate the list, `<CR>` confirms, `<C-e>` aborts, `<C-Space>` forces the popup open, `<C-d>`/`<C-u>` scroll the docs window.

Sources (in priority order):

| Source | Plugin | What it provides |
|---|---|---|
| `nvim_lsp` | `cmp-nvim-lsp` | Completions from attached LSP servers (symbols, methods, fields) |
| `nvim_lsp_signature_help` | `cmp-nvim-lsp-signature-help` | Function parameter hints shown inline while typing inside a call |
| `snippets` | `garymjr/nvim-snippets` | Snippet expansion via `vim.snippet` (nvim 0.10+ built-in engine) |
| `buffer` | `cmp-buffer` | Words from the current buffer |
| `path` | `cmp-path` | Filesystem path completions |

LSP capabilities (`cmp_nvim_lsp.default_capabilities()`) are passed to all servers via `nvim-lspconfig`'s `LspAttach` autocmd — this tells each LSP server that the client supports snippet insertText and other completion features, enabling richer results.

No LSP servers are pre-installed. Users install them via `:Mason`; `mason-lspconfig` with `automatic_enable = true` bridges any installed server to lspconfig automatically.

## Git-sync coordinator (`nvim/lua/sync.lua`)

Because the two nvim instances are isolated processes, external git operations (branch switch, pull, stash pop via lazygit) leave both instances with stale state: gitsigns shows old-branch hunks, the statusline branch name is wrong, nvim-tree holds paths that no longer exist on the new branch (→ crash on next refresh).

`nvim/lua/sync.lua` exports five functions:

**`sync()`** — full git-state refresh; call only on events that signal an external state change:
```
sync.sync()
  1. silent! checktime           — reload all buffers changed on disk
  2. gitsigns.refresh()          — re-read HEAD, recompute hunk signs + branch name
  3. nvim-tree.api.tree.reload() — full tree rebuild + git status
  4. msgpack-RPC to treemux nvim — pcall(require('nvim-tree.api').tree.reload)
     (fire-and-forget; does NOT send aidignore.reset() — see note below)
```

**`checktime()`** — lightweight: `silent! checktime` only. No sign-column or tree redraws. Safe for high-frequency events (BufEnter, CursorHold) to avoid visual flicker.

**`reload()`** — full workspace reload, bound to `<leader>R`:
```
sync.reload()
  1. gen-tmux-palette.sh && tmux -L aid source-file $AID_DIR/tmux.conf
     — regenerate tmux/palette.conf from palette.lua, then hot-reload tmux config
  2. source $MYVIMRC                             — hot-reload nvim config
  3. aidignore.reset()                           — re-read .aidignore, re-apply
                                                   nvim-tree filters, restart watcher
  4. sync()                                      — git state + buffers + sidebar
```

**`watch_palette()`** — registers an `fs_event` watcher on `$AID_DIR/nvim/lua/` (filtered to `palette.lua` only). Called once on `VimEnter`. On change: calls `_G.apply_palette()` to re-apply all nvim highlight groups, then runs `gen-tmux-palette.sh && tmux -L aid source-file <AID_DIR>/tmux/palette.conf` as a detached job. Notifies `"palette reloaded"`. Stored under `_watchers["__palette__"]`; stops and re-registers if called again (idempotent).

**`watch_buf(bufnr)`** — watches the parent directory of a buffer's file via `fs_event`. Called on `BufEnter`. Skips special/non-file buffers. Idempotent: no-op if the directory is already watched. On any change in the directory, calls `sync()` so external edits (e.g. from opencode) appear immediately without a pane switch.

**`stop_watchers()`** — stops all active `fs_event` handles (both `__palette__` and per-directory buffer watchers). Called on `VimLeave`.

### Trigger points

| Trigger | Function | Why |
|---|---|---|
| `FocusGained` | `sync()` | nvim regains focus after any external tool |
| `TermClose` | `sync()` | fires when the lazygit float buffer closes |
| explicit call after `vim.cmd("LazyGit")` | `sync()` | belt-and-suspenders for TermClose timing |
| `BufEnter` / `CursorHold` / `CursorHoldI` | `checktime()` | buffer reload only; no sign-column redraws |
| `pane-focus-in` tmux hook | `sync()` | `nvim --remote-send lua require("sync").sync()` into `AID_NVIM_SOCKET` on pane switch; updates gitsigns line highlights without requiring the user to physically focus nvim (T-014/BUG-009) |

### Treemux RPC (T-016)

The treemux sidebar is a separate nvim process. `sync()` reaches it via direct msgpack-RPC:

1. On `VimEnter`, `treemux_init.lua` writes `vim.v.servername` into tmux option `@-treemux-nvim-socket-<editor_pane_id>`. Removed on `VimLeave`.
2. `sync.lua` reads that option, calls `vim.fn.sockconnect("pipe", socket, {rpc=true})`, then `vim.rpcnotify(chan, "nvim_exec_lua", "pcall(require('nvim-tree.api').tree.reload)", {})`.
3. `rpcnotify` is fire-and-forget — does not stall the main nvim event loop. Channel is closed after 500ms via `vim.defer_fn`. `pcall` guards against a dead socket.

**Why `tree.reload()` and not `aidignore.reset()`**: sending `reset()` via RPC would cause the sidebar nvim to run `_apply_to_nvimtree()` → `pcall(s.sync)` → `checktime` in the sidebar context, which opens `.aidignore` as a buffer and destroys the nvim-tree window. The sidebar inherits filters from `AID_IGNORE` at startup; live filter changes are handled by `aidignore.watch()` running inside the sidebar nvim directly (not via RPC from the main nvim).

### Treemux self-heal

`treemux_init.lua` registers its own autocmds for branch-switch recovery (separate process, cannot receive `sync()` directly):

- `FileChangedShell` — sets `vim.v.fcs_choice = "reload"` (suppresses the blocking prompt) and calls `nvim-tree.api.tree.reload()`
- `FileChangedShellPost` — `silent! checktime` + `nvim-tree.api.tree.reload()` for files deleted by a branch switch

## Palette system (`nvim/lua/palette.lua`)

All aid colors are defined in a single file: `nvim/lua/palette.lua`. No hex strings are duplicated anywhere else — every component that needs a color imports this module or is driven by it.

### Color groups

| Group | Keys | Purpose |
|---|---|---|
| Core accent | `purple`, `blue`, `lavender` | Statusline segments, tmux status bar |
| Bufferline | `tab_bg`, `tab_sel`, `tab_fg` | Inactive/active tab colors |
| Git signs | `git_add`, `git_del`, `git_chg`, `git_del_ln`, `git_chg_ln` | Gitsigns highlight groups |
| Misc | `fg`, `cursor_fg`, `none` | Universal foreground, cursor text, transparency sentinel |

### Consumers

- **`nvim/init.lua`** — `require("palette")` at top; bufferline highlight table and the `_G.apply_palette()` function use `p.*` references. `apply_palette()` sets every `nvim_set_hl` call and is invoked at startup and on hot-reload.
- **`nvim-treemux/treemux_init.lua`** — `pcall(dofile, aid_dir .. "/nvim/lua/palette.lua")` with a hardcoded fallback table; accent highlights (`NvimTreeFolderName`, git sign groups) use palette values.
- **`gen-tmux-palette.sh`** — reads `palette.lua` via `lua - "$PALETTE"` with `loadfile()`, emits `key=value` shell assignments, `eval`s them, then writes `tmux/palette.conf`.

### tmux bridge (`gen-tmux-palette.sh` → `tmux/palette.conf`)

tmux cannot `require()` Lua, so the bridge works as follows:

```
gen-tmux-palette.sh
  1. lua - "$PALETTE": loadfile() → pairs(p) → print "key=value" for each string
  2. eval "$(lua ...)"            → palette keys become shell variables
  3. cat >tmux/palette.conf <<EOF — interpolates shell variables into tmux set-g directives
```

`tmux/palette.conf` is a generated file (`DO NOT EDIT` header). `tmux.conf` sources it with `source-file "$AID_DIR/tmux/palette.conf"`.

`aid.sh` calls `gen-tmux-palette.sh` before starting the tmux server so `palette.conf` exists before `tmux.conf` is loaded.

### Hot-reload

Saving `palette.lua` while aid is running instantly updates all colors — no restart, no `<leader>R`:

```
palette.lua saved
  → sync.watch_palette() inotify event
  → _G.apply_palette()          — re-applies all nvim highlight groups immediately
  → gen-tmux-palette.sh         — rewrites tmux/palette.conf
  → tmux -L aid source-file <AID_DIR>/tmux/palette.conf  — tmux status bar updates
  → vim.notify("palette reloaded")
```

The watcher uses `vim.uv.new_fs_event` on `$AID_DIR/nvim/lua/` (directory-level, because Linux inotify cannot watch a single file directly) and filters events to `filename == "palette.lua"` only.

## Opencode integration

Opencode runs in the rightmost pane (initial split 29%; resized to 28% after sidebar opens). Isolated from the user's `~/.config/opencode` via `OPENCODE_CONFIG_DIR=$AID_DIR/opencode`.

Custom slash commands live in `aid/opencode/commands/`:
- `commit.md` — generates a conventional commit message from staged diff
- `udoc.md` — updates `aid/docs/` to reflect recent code changes (with LOC cap, archiving, and pruning)
- `spec.md` — generates a feature specification from a description or existing code
- `lsp.md` — Setup: wires Mason LSP binaries into `opencode.json`; Diagnose: runs available CLI diagnostic tools against source files and fixes reported issues

`aid/opencode/package.json` declares the project name for the opencode workspace.

## `.aidignore` system (`nvim/lua/aidignore.lua`)

`.aidignore` is a per-project file (one pattern per line, `#` comments, blank lines ignored) that drives file hiding in both nvim-tree and Telescope. `aid.sh` walks up from the launch dir to find the nearest `.aidignore` at startup; if none is found, an empty one is created in the launch dir so the file watcher has a target from day one.

### Module API

```
aidignore.patterns()  — returns { raw = {...}, telescope = {...} }
                         raw:       plain strings for nvim-tree filters.custom
                                    (glob patterns excluded — triggers E33 in vim.fn.match)
                         telescope: Lua patterns for file_ignore_patterns
                         result is cached until reset() or watch() fires

aidignore.watch()     — start (or restart) a vim.uv fs_event watcher on the
                         nearest .aidignore file directly; on change: bust cache + re-apply
                         Called from reset() and directly after nvim-tree setup.

aidignore.reset()     — bust cache + _apply_to_nvimtree() + _apply_to_telescope()
                         + restart watch(). Called from DirChanged autocmd,
                         reload(), and from the sidebar nvim's own watch() handler.
```

### Live filter update mechanism (`_apply_to_nvimtree`)

nvim-tree does not expose a public API to change filters without calling `setup()` again. Calling `setup()` re-calls `purge_all_state()` which destroys the window/explorer — unacceptable for live reload.

The solution: mutate `require("nvim-tree.core").get_explorer().filters.ignore_list` in-place, then call `api.tree.reload()`. `ignore_list` is a `table<string, boolean>` read on every `should_filter()` call in nvim-tree's render loop. Mutating it + reloading updates the visible tree with zero visual disruption (no window close/reopen, cursor preserved).

**Stability**: `ignore_list` has existed under this exact name since nvim-tree's multi-instance refactor (PR #2841), with 33 commits to `filters.lua` since then — name unchanged.

**Fallback (S2)**: if `ignore_list` is ever renamed/removed, the fallback is `tmux kill-pane <sidebar_pane_id>` + re-run `ensure_treemux.sh`. ~0.5s visual glitch but fully public API. See comment in `aidignore.lua`.

### Sidebar integration

`aidignore.lua` lives in `nvim/lua/`. `treemux_init.lua` prepends `AID_DIR/nvim/lua` to `package.path` before any `require()`, allowing `require("aidignore")` from the sidebar nvim.

At startup, `treemux_init.lua` populates nvim-tree `filters.custom` from `AID_IGNORE` env (set by `aid.sh` at session start). After `nvim-tree.setup()`, it calls `aidignore.watch()` for live updates. When the main nvim's `sync()` fires, it contacts the sidebar via msgpack-RPC to call `nvim-tree.api.tree.reload()` — rebuilding the file tree to reflect any external git changes. Live `.aidignore` filter changes are handled independently by `aidignore.watch()` running inside the sidebar nvim.

### Telescope integration

`_apply_to_telescope()` mutates `require("telescope.config").values.file_ignore_patterns` in-place. Called from all `reset()` paths. No restart required.

## Differentiators

### vs. GUI IDEs (VS Code, Cursor)
- Terminal-native: runs in tmux, SSH-friendly, no Electron
- Opencode (MIT, provider-agnostic) replaces proprietary Copilot/Cursor AI
- AI lives in a tmux pane — persistent across editor restarts, can interact with the terminal directly

### vs. Neovim distributions (LazyVim, SpaceVim)
- **Workspace vs. editor**: aid orchestrates multiple nvim instances + tmux panes; LazyVim only configures the editor process
- **Persistent sidebar**: separate `NVIM_APPNAME=treemux` instance — never closes on focus loss, tracks any `cd`
- **Cross-project bookmarks**: `$AID_DIR/nvim/global_bookmarks` — unlike Harpoon, works across unrelated directories
- **Unified statusline**: `vim-tpipeline` exports nvim statusline to tmux status bar, visible across all panes
- **Session management**: `ensure_treemux.sh` auto-recreates the layout on reattach

## Key design decisions

- **`aid.sh` is a standalone script, not a shell function**: symlinked into `~/.local/bin/aid` by `install.sh`. `AID_DIR` resolved via `realpath "${BASH_SOURCE[0]}"`. No `aliases.sh`, no shell injection, no `~/.bashrc` modification.
- **Session routing in `aid.sh`**: `aid` with no args creates a new session named `<prefix>@<basename>` where prefix is derived from the git branch of `AID_DIR` (`main`/`HEAD` → `"aid"`, any other branch → the branch name). `-a` attaches (interactive list or named). `-l` lists sessions.
- **`NVIM_APPNAME=nvim`** (not `nvim-aid`): `XDG_CONFIG_HOME=$AID_DIR` keeps the config source in the repo; `XDG_DATA_HOME`, `XDG_STATE_HOME`, and `XDG_CACHE_HOME` point to `~/.local/share/aid`, `~/.local/state/aid`, and `~/.cache/aid` respectively — runtime artefacts land in the standard XDG hierarchy under an aid-specific namespace, not inside the source tree and not in the nvim defaults (`~/.local/share/nvim` etc.).
- **`tmux -L aid`** for all tmux commands: every script (`aid.sh`, `ensure_treemux.sh`, `sync.lua`) targets the named socket explicitly — no ambiguity about which server is being addressed.
- **`AID_DIR` env var** exported into the tmux server: `set-environment -g AID_DIR` so all panes and scripts can locate the repo root without assumptions about install path.
- **`--git-dir` not `--git-common-dir`** for lazygit worktree detection: `--git-common-dir` returns the bare repo root, causing git to use it as the work-tree and see all files as deleted. `--git-dir` returns the worktree-specific path (`aid/worktrees/main`) which correctly scopes the index.
