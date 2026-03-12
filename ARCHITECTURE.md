<!-- LOC cap: 718 (source: 7178, ratio: 0.10, updated: 2026-03-12) -->
# Architecture

## Overview

aid is an open-source, terminal-native AI IDE: tmux workspace orchestration + nvim config + persistent Opencode AI pane, all in one repo.

It reconstructs the VS Code/Cursor UX entirely in the terminal — no Electron, no GUI, SSH-friendly. Every session has two windows: an IDE window (file-tree sidebar + nvim + opencode) and an orchestrator window (session navigator + opencode with HTTP API + live diff). A single `boot.sh` curl gives a fully working IDE on any machine.

**Identity**: not a Neovim distribution (like LazyVim) — a *workspace environment* that orchestrates multiple nvim instances and tmux panes into a cohesive IDE. LazyVim configures an editor; aid builds a workspace around one.

Install path: `~/.local/share/aid` (override: `AID_DIR`).

## Boot sequence

```
boot.sh (curl | bash)
  └── git clone → $DEST   (or git pull if already installed)
  └── install.sh
        ├── 1.  pynvim (Arch only, via pacman)
        ├── 1b. delta (Arch only, via pacman — required by lazygit for diff highlighting)
        ├── 1c. bun   (Arch only, via pacman — required by aid-sessions.ts navigator)
        ├── 2. TPM clone → $AID_DATA/tmux/plugins/tpm
        ├── 3. treemux plugin clone → $AID_DATA/tmux/plugins/treemux
        │       patch watch_and_update.sh symlink → aid/nvim-treemux/
        ├── 4. symlinks + lazygit config:
        │       ~/.config/aid/treemux              → aid/nvim-treemux/
        │       ~/.config/aid/lazygit/config.yml   (copied from templates; never overwrites)
        │       ~/.local/bin/aid                   → aid/aid.sh  (production only)
        ├── 5. nvim-treemux headless lazy sync  (NVIM_APPNAME=treemux) ← spinner
        ├── 5b. main nvim headless lazy sync    (NVIM_APPNAME=nvim)    ← spinner
        └── 6. PATH symlink only for production install (AID_DATA == ~/.local/share/aid)
```

## Runtime sequence (`aid` command)

`aid.sh` is a standalone script symlinked into `~/.local/bin/aid`. `AID_DIR` is resolved via `realpath "${BASH_SOURCE[0]}"` — no shell function, no `aliases.sh` dependency.

### Session routing

```
aid -l / --list    → list sessions (tmux list-sessions) and exit
aid -a             → interactive list; auto-attach if only one session
aid -a <name>      → attach to named session directly and exit
aid -i / --install → exec boot.sh — install/update plugins and symlinks
aid --update       → same as -i (alias)
aid --branch <name>→ clone/pull remote branch into ~/.local/share/aid/<name>,
                     bootstrap on first use, re-exec into that branch's aid.sh
aid --no-ai        → create session without opencode pane; orc window also skipped
aid --mode orchestrator → exec lib/orchestrator.sh (multi-session orchestrator layout)
aid               → create a new session in $PWD
```

`attach_or_switch` helper uses `switch-client` when already inside tmux (attach fails inside a session).

### Session creation (normal `aid` launch)

Every normal `aid` session creates **two windows**:
- **Window 0 `ide`**: treemux sidebar (left) + nvim (middle) + opencode (right)
- **Window 1 `orc`**: session navigator (left ~20%) + opencode with HTTP API (center ~55%) + aid-diff (right ~25%)

`--no-ai` skips both the opencode pane in the ide window and the entire orc window.

```
aid.sh
  ├── resolve AID_DIR via realpath
  ├── gen-tmux-palette.sh (generates tmux/palette.conf from nvim/lua/palette.lua)
  ├── session name: <prefix>@<basename> (deduplicated with numeric suffix)
  │     prefix = git branch of AID_DIR; "main"/"HEAD"/empty → "aid"
  ├── bootstrap templates if absent: `.aidignore`, `.nvim.lua`, `opencode.json`
  │     (copies from `$AID_DIR/nvim/templates/`; never overwrites existing files)
  ├── parse .aidignore (walks up from launch_dir, up to 20 levels)
  ├── tmux -L aid -f <AID_DIR>/tmux.conf new-session -d -s <session>
  ├── source-file $AID_DATA/tmux/palette.conf
  ├── set-option -t <session> status-left/right → vimbridge cat strings (session-local)
  │     pre-seed vimbridge files with ' ' placeholder (BUG-022 fix)
  ├── set-environment -g:
  │       AID_DIR, AID_DATA, AID_CONFIG, AID_IGNORE
  │       OPENCODE_CONFIG_DIR, OPENCODE_TUI_CONFIG
  │       TMUX_PLUGIN_MANAGER_PATH, NVIM_APPNAME=nvim
  │       XDG_DATA_HOME=$AID_DATA, XDG_STATE_HOME, XDG_CACHE_HOME
  │   set-environment -t <session>:
  │       AID_NVIM_SOCKET → /tmp/aid-nvim-<session>.sock  (session-local)
  ├── set @treemux-key-Tab / @treemux-key-Bspace directly
  │     (sidebar.tmux targets default socket — aid.sh sets options itself)
  │
  │  ── Window 0: ide ──
  ├── capture editor_pane_id
  ├── split-window -h -p 29 → opencode process directly (skipped with --no-ai)
  ├── run-shell ensure_treemux.sh -t editor_pane_id  (opens sidebar)
  ├── respawn-pane -k editor_pane_id → nvim restart loop:
  │       cd <launch_dir>; while true; do
  │         rm -f <nvim_socket>
  │         XDG_CONFIG_HOME=<AID_DIR> XDG_DATA_HOME=<AID_DATA>
  │         LG_CONFIG_FILE=<AID_CONFIG>/lazygit/config.yml
  │         NVIM_APPNAME=nvim nvim --listen <nvim_socket>
  │       done
  │
  │  ── Window 1: orc (skipped with --no-ai) ──
  ├── new-window -n "orc"
  ├── set-environment -t <session>: AID_ORC_PORT, AID_ORC_REPO,
  │       AID_ORC_NAV_PANE, AID_ORC_ORC_PANE, AID_ORC_DIFF_PANE
  ├── split nav_pane right 80% → orc_pane; split orc_pane right 25% → diff_pane
  ├── respawn orc_pane  → opencode --port <AID_ORC_PORT> <launch_dir>
  ├── respawn nav_pane  → bun run aid-sessions.ts
  ├── respawn diff_pane → bun run aid-diff.ts
  │
  ├── select-window 0 (return to ide for initial attach)
  └── attach_or_switch <session>
```

The editor pane bypasses the interactive shell entirely — `respawn-pane -k` drops straight into the nvim restart loop. Quitting nvim (`:q`) restarts it immediately; the pane is never a bare shell.

## Environment variables (tmux server scope)

Set via `tmux -L aid set-environment -g`; all child shells inherit them. `XDG_CONFIG_HOME` and `LG_CONFIG_FILE` are **not** global — injected inline only on the nvim `respawn-pane` command.

| Variable | Value | Purpose |
|---|---|---|
| `AID_DIR` | path to `aid/main/` | Lets scripts locate the repo without assumptions about install path |
| `AID_DATA` | `~/.local/share/aid` | Runtime artifact root (tmux plugins, palette.conf). Same as `AID_DIR` for end users; differs for branch sessions |
| `AID_CONFIG` | `~/.config/aid` | Personal config root (treemux symlink, lazygit config). Branch sessions use `~/.config/aid/<branch>` |
| `AID_IGNORE` | comma-separated patterns | Populated from `.aidignore` (found by walking up from `$PWD`) |
| `NVIM_APPNAME` | `nvim` | Main editor appname; with `XDG_CONFIG_HOME=$AID_DIR` (inline) resolves config to `$AID_DIR/nvim` |
| `XDG_DATA_HOME` | `$AID_DATA` | nvim plugin data / lazy.nvim → `$AID_DATA/nvim/` |
| `XDG_STATE_HOME` | `~/.local/state/aid` | nvim shada / swap / undo |
| `XDG_CACHE_HOME` | `~/.cache/aid` | nvim cache |
| `OPENCODE_CONFIG_DIR` | `$AID_DIR/opencode` | Isolates opencode config from `~/.config/opencode` |
| `OPENCODE_TUI_CONFIG` | `$AID_DIR/opencode/tui.json` | Points opencode at aid's TUI config |
| `TMUX_PLUGIN_MANAGER_PATH` | `$AID_DATA/tmux/plugins/` | Needed by TPM scripts running inside the aid server |
| `AID_NVIM_SOCKET` | `/tmp/aid-nvim-<session>.sock` | Session-local (`-t`); sidebar nvim reads at startup |
| `AID_ORC_PORT` | `4200 + cksum(session) % 1000` | Opencode HTTP API port for the orc window; stable across restarts |
| `AID_ORC_REPO` | `<launch_dir>` | Repo path for aid-diff and aid-sessions |
| `AID_ORC_NAV_PANE` | `%<id>` | Pane ID of navigator (orc window left) |
| `AID_ORC_ORC_PANE` | `%<id>` | Pane ID of opencode TUI (orc window center) |
| `AID_ORC_DIFF_PANE` | `%<id>` | Pane ID of diff pane (orc window right) |

## Pane ownership

All pane geometry is owned by `aid.sh` and `ensure_treemux.sh`. `tmux.conf` owns only plugin config and keybinds — **never sizes** — with one exception: `@treemux-tree-width 26` must live in `tmux.conf` so treemux reads it before `sidebar.tmux` runs.

`aid.sh` does the initial editor/opencode split at `-p 29` (29% for opencode). After `ensure_treemux.sh` opens the sidebar, it re-enforces the opencode column count to 28% of the total window width via `resize-pane -x`.

Window switching: `prefix+1` → ide window, `prefix+2` → orc window.

## Isolation strategy

| Layer | Isolation mechanism |
|---|---|
| tmux server | `tmux -L aid` — dedicated named socket, separate from the default server |
| tmux config | `tmux -L aid -f <AID_DIR>/tmux.conf` — `-f` suppresses `~/.tmux.conf` and `~/.config/tmux/tmux.conf` entirely |
| tmux plugins | TPM and all plugins installed under `$AID_DATA/tmux/plugins/` |
| main nvim | `XDG_CONFIG_HOME=$AID_DIR` (inline) + `XDG_DATA_HOME=$AID_DATA`, `XDG_STATE_HOME`, `XDG_CACHE_HOME`; with `NVIM_APPNAME=nvim` all paths resolve under `aid/nvim/` subdirs |
| sidebar nvim | `XDG_CONFIG_HOME=~/.config/aid` + `NVIM_APPNAME=treemux` → config at `~/.config/aid/treemux/` → `aid/nvim-treemux/` |
| opencode | `OPENCODE_CONFIG_DIR=$AID_DIR/opencode` — not `~/.config/opencode` |
| shell | standalone script in `~/.local/bin` — no shell function injection, no `~/.bashrc` modification |

| Config path | Points to |
|---|---|
| `~/.config/aid/treemux` | `aid/nvim-treemux/` |
| `~/.config/aid/lazygit/config.yml` | copied from `aid/nvim/templates/lazygit.yml` |
| `~/.local/bin/aid` | `aid/aid.sh` |

`~/.config/nvim`, `~/.config/aid/nvim`, and `~/.config/tmux/` are **not touched**.

## `nvim/init.lua` structure

The load order within `init.lua` is intentional and must be preserved:

```
1. LEADER KEY           — vim.g.mapleader before any plugin reads it
2. netrw disable        — vim.g.loaded_netrw before VimEnter
3. OPTIONS              — vim.opt.* globals before plugins/autocmds fire
                          includes: vim.opt.exrc = true + vim.opt.secure = true
4. PALETTE              — local p = require("palette")
5. GIT-SYNC require     — local sync = require("sync")
6. CHEATSHEET           — _cs_open() (plain edit, no styling/autocmds)
7. BOOTSTRAP LAZY       — vim.opt.rtp:prepend(lazypath)
8. KEYMAPS              — vim.keymap.set() calls
9. PLUGINS              — require("lazy").setup({...})
                          includes: persistence.nvim, nvim-cmp, mason + mason-lspconfig,
                          nvim-lspconfig, conform.nvim, nvim-lint, nvim-dap + nvim-dap-ui,
                          mason-nvim-dap, mini.cursorword, lspkind.nvim
10. APPEARANCE          — _G.apply_palette(): nvim_set_hl for all groups + guicursor
11. DIAGNOSTICS         — vim.diagnostic.config()
12. AUTOCMDS            — FileType, FocusGained, TermClose, DirChanged, VimEnter
```

The `VimEnter` autocmd lives at the **top level** of `init.lua` — not inside any plugin `config` function — to guarantee registration before the event fires.

## Cheatsheet system

`nvim/cheatsheet.md` is opened as a normal file buffer (`vim.cmd("edit " .. path)`) when nvim starts with no file argument. No special read-only styling, no buffer tracking, no window-option autocmds — just a plain `edit`. Re-open at any time with `<leader>?`. Dismissed by opening any other file; no auto-restore logic.

## Autocompletion (`nvim-cmp`)

`hrsh7th/nvim-cmp` provides the completion popup. Sources (priority order): `nvim_lsp`, `nvim_lsp_signature_help`, `snippets` (nvim 0.10+ built-in via `garymjr/nvim-snippets`), `buffer`, `path`. Keymaps: `<Tab>`/`<S-Tab>` navigate, `<CR>` confirms, `<C-e>` aborts, `<C-Space>` forces open. `<C-d>`/`<C-u>` scroll docs (active only when completion popup is open).

LSP capabilities are passed to all servers via the `LspAttach` autocmd. No servers are pre-installed — users install via `:Mason`; `mason-lspconfig` with `automatic_enable = true` bridges them automatically.

## Git-sync coordinator (`nvim/lua/sync.lua`)

Because the two nvim instances are isolated processes, external git operations leave both with stale state. `sync.lua` exports five functions:

**`sync()`** — full git-state refresh:
```
1. silent! checktime           — reload all buffers changed on disk
2. gitsigns.refresh()          — re-read HEAD, recompute hunk signs + branch name
3. nvim-tree.api.tree.reload() — full tree rebuild + git status
4. msgpack-RPC to treemux nvim — pcall(require('nvim-tree.api').tree.reload)
```

**`checktime()`** — lightweight: `silent! checktime` only. Safe for high-frequency events.

**`reload()`** — full workspace reload (`<leader>R`):
```
1. gen-tmux-palette.sh && tmux -L aid source-file $AID_DIR/tmux.conf
2. source $MYVIMRC
3. aidignore.reset()
4. sync()
```

**`watch_palette()`** — `fs_event` watcher on `$AID_DIR/nvim/lua/` filtered to `palette.lua`. On change: `_G.apply_palette()`, then `gen-tmux-palette.sh && tmux -L aid source-file <AID_DIR>/tmux/palette.conf`.

**`watch_buf(bufnr)`** — watches buffer's parent directory. On change: calls `sync()`.

**`stop_watchers()`** — stops all `fs_event` handles on `VimLeave`.

### Trigger points

| Trigger | Function | Why |
|---|---|---|
| `FocusGained` | `sync()` | nvim regains focus after external tool |
| `TermClose` | `sync()` | lazygit float closes |
| `BufEnter` / `CursorHold` / `CursorHoldI` | `checktime()` | buffer reload only; no sign-column redraws |
| `pane-focus-in` tmux hook | `sync()` | `nvim --remote-send` into `AID_NVIM_SOCKET` on pane switch (T-014/BUG-009) |

### Treemux RPC (T-016)

1. On `VimEnter`, `treemux_init.lua` writes `vim.v.servername` into tmux option `@-treemux-nvim-socket-<editor_pane_id>`. Removed on `VimLeave`.
2. `sync.lua` reads that option, calls `vim.fn.sockconnect("pipe", socket, {rpc=true})`, then `vim.rpcnotify(chan, "nvim_exec_lua", "pcall(require('nvim-tree.api').tree.reload)", {})`.
3. Fire-and-forget. Channel closed after 500ms. `pcall` guards against dead socket.

### Treemux self-heal

`treemux_init.lua` autocmds for branch-switch recovery:
- `FileChangedShell` — `vim.v.fcs_choice = "reload"` + `nvim-tree.api.tree.reload()`
- `FileChangedShellPost` — `silent! checktime` + `nvim-tree.api.tree.reload()`

## Palette system (`nvim/lua/palette.lua`)

All aid colors in one file. No hex strings duplicated anywhere else.

### Color groups

| Group | Keys | Purpose |
|---|---|---|
| Core accent | `purple`, `blue`, `lavender` | Statusline segments, tmux status bar |
| Bufferline | `tab_bg`, `tab_sel`, `tab_fg` | Inactive/active tab colors |
| Git signs | `git_add`, `git_del`, `git_chg`, `git_del_ln`, `git_chg_ln`, `git_dot` | Gitsigns highlight groups |
| Completion | `cmp_bg`, `cmp_sel`, `cmp_border`, `cmp_item_fg`, `cmp_kind_fg`, `cmp_ghost` | nvim-cmp popup |
| Misc | `fg`, `cursor_fg`, `none` | Universal foreground, cursor text, transparency sentinel |

### Consumers

- **`nvim/init.lua`** — `require("palette")` at top; bufferline highlights + `_G.apply_palette()`.
- **`nvim-treemux/treemux_init.lua`** — `pcall(dofile, aid_dir .. "/nvim/lua/palette.lua")`; applies `git_dot` highlight + git sign groups. Fallback table if palette missing.
- **`gen-tmux-palette.sh`** — reads via `lua loadfile()`, emits shell assignments, writes `tmux/palette.conf`.
- **`aid-sessions.ts` / `aid-diff.ts`** — `loadPalette()` reads `palette.lua` at startup via regex; palette.lua is the single source of truth for navigator and diff pane colors.

### tmux bridge

```
gen-tmux-palette.sh
  1. lua - "$PALETTE": loadfile() → pairs(p) → print "key=value"
  2. eval "$(lua ...)"  → palette keys become shell variables
  3. cat >tmux/palette.conf  — interpolates into tmux set-g directives
```

`tmux/palette.conf` is generated (`DO NOT EDIT`). `tmux.conf` sources it; `aid.sh` generates it before starting the server.

### Hot-reload

Saving `palette.lua` triggers `sync.watch_palette()`: re-applies nvim highlights, rewrites and hot-reloads `tmux/palette.conf`. The watcher is directory-level (Linux inotify limitation) filtered to `palette.lua`.

## Opencode integration

### IDE window

Opencode runs in the rightmost pane of the ide window (initial split 29%; resized to 28% after sidebar opens). Isolated from `~/.config/opencode` via `OPENCODE_CONFIG_DIR=$AID_DIR/opencode`.

### Orc window

A second opencode instance runs in the orc window center pane with `--port <AID_ORC_PORT>` (HTTP API enabled). This allows `aid-sessions.ts` to load conversations via `POST /tui/select-session`. `XDG_DATA_HOME` is injected inline on `respawn-pane` to keep this instance's conversation store isolated.

### Custom slash commands

Custom slash commands live in `aid/opencode/commands/`:
- `commit.md` — generates a conventional commit message from staged diff
- `udoc.md` — updates `aid/docs/` to reflect recent code changes
- `spec.md` — generates a feature specification from a description or existing code
- `lsp.md` — wires Mason LSP binaries into `opencode.json`; diagnoses and fixes LSP issues

## Orchestrator mode (`aid --mode orchestrator`)

Orchestrator mode is for running many opencode conversations in parallel, each in its own isolated tmux session, navigable from a persistent sidebar. `aid.sh` dispatches to `lib/orchestrator.sh` via `exec`.

**Note**: Every normal `aid` session also gets an orc window (Window 1). Orchestrator mode is distinct — it creates standalone `aid@<name>` sessions without the ide window, each session containing only the 3-pane orc layout. The nvim window in orchestrator sessions is currently disabled (T-ORC-6).

### Boot sequence

```
aid.sh --mode orchestrator
  └── exec lib/orchestrator.sh
        ├── _ensure_server          — start tmux -L aid server if not running
        ├── check for existing sessions (@aid_mode=orchestrator)
        │     none found → _new_session_from_cwd
        │     found      → _attach_or_switch to most recently used
        └── spawn_orc_session <name> <repo_path>
              ├── tmux new-session -d -s aid@<name>
              ├── source-file palette.conf + set vimbridge status bar (same as ide)
              ├── set-environment: AID_ORC_PORT, AID_ORC_NAME, AID_ORC_REPO,
              │                    AID_NVIM_SOCKET, AID_ORC_NAV_PANE,
              │                    AID_ORC_ORC_PANE, AID_ORC_DIFF_PANE
              ├── [debug] split bottom 3 lines → dbg_pane
              ├── split right 80% → orc_pane; split orc_pane right 25% → diff_pane
              ├── respawn orc_pane  → opencode --port <AID_ORC_PORT> <repo_path>
              ├── respawn nav_pane  → aid-sessions.ts
              ├── respawn diff_pane → aid-diff.ts
              ├── [debug] respawn dbg_pane → aid-sessions-debug
              ├── set-option @aid_mode orchestrator
              ├── _meta_write <name> <repo_path>  (persist to sessions.json)
              ├── set-hook pane-focus-in → aid-meta-touch
              └── _attach_or_switch aid@<name>
```

Session name: `aid@<sanitised-basename-of-repo>`. Numeric suffix if name exists.

### Session metadata (`lib/sessions/aid-meta`)

Records stored in `$AID_DATA/sessions.json`. Dead sessions (tmux gone, metadata present) are shown in the navigator and can be resurrected.

```json
{
  "tmux_session": "aid@project",
  "repo_path":    "/home/user/project",
  "branch":       "main",
  "created_at":   "2026-03-11T22:00:00Z",
  "last_active":  "2026-03-12T00:01:00Z"
}
```

| Function | Purpose |
|---|---|
| `_meta_write <name> <repo>` | Upsert; preserves `created_at` |
| `_meta_touch <session>` | Update `last_active` (called by `pane-focus-in` hook) |
| `_meta_remove <session>` | Delete by session name |
| `_meta_get <session> <field>` | Read one field; `""` when missing or jq absent |

All functions degrade gracefully when `jq` is absent. `pruneDead()` in `aid-sessions.ts` removes stale entries at startup.

## `aid-sessions.ts` — the navigator

`lib/sessions/aid-sessions.ts` is a self-contained Bun/TypeScript process owning the nav pane. Renders via ANSI escape codes (alternate screen buffer, absolute cursor positioning), handles raw key input, calls the opencode HTTP API and tmux via `Bun.spawn` / `fetch`. No fzf dependency.

### Visual structure

```
 aid@aid          sessions    ← title bar (row 1): blue bg, full-width
❯ aid          live           ← session header: purple caret when current
 ├─ ● Conv title    2m ago    ← active conv: purple ●, bold white title
 └─ ○ Other conv    5m ago    ← inactive conv: dim gray ○
```

Selection: purple `▌` left-edge bar. Timestamps: dim gray, right-aligned. Colors loaded from `palette.lua` at startup (`loadPalette()`).

### Sync strategy

| Tier | Trigger | What it does |
|---|---|---|
| Optimistic patch | Immediately on action | Mutates `state.items` + `render()` |
| Fast active sync (`refreshActiveConvs`) | Every cursor move | Re-queries `AID_ORC_ACTIVE_CONV` from tmux env |
| Full refresh (`refresh`) | After mutating actions; 5s interval | Rebuilds item list from tmux + opencode HTTP |

### Keys

| Key | Action |
|---|---|
| `↑`/`k`, `↓`/`j` | Move cursor |
| `PgUp`/`PgDn` | Move ±10 rows |
| `Enter` | Conv: load (switches foreign session if needed). Session header: focus terminal. Dead session: resurrect. |
| `n` | New conversation |
| `r` | Inline rename |
| `d` | Delete with `y`/`n` confirm |
| `Ctrl-R` | Force full refresh |
| `q`/`Esc`/`Ctrl-C` | Quit |

### Cross-session conversation loading

When a conversation belongs to a different session, `switchToForeignConv`:

```
1. POST /tui/select-session {"sessionID":"<convId>"}  (fires before focus change)
2. tmux set-environment -t foreignSession AID_ORC_ACTIVE_CONV=<convId>
3. tmux list-clients -t foreignSession → foreignClients[]

Case A — terminal already has session open:
  hyprlandWindowForPid(pid) → hyprctl dispatch focuswindow address:<addr>
  fallback: switch-client -c <tty> -t foreignSession

Case B — no terminal has session open:
  hyprctl dispatch exec "[workspace <ws>] kitty -- tmux -L aid attach -t foreignSession"
  fallback: plain kitty spawn
```

All `hyprctl` calls degrade gracefully when unavailable.

### `resolveClient`

Resolution order for the terminal tty:
1. `AID_CALLER_CLIENT` (set at startup via `tmux display-message -t $TMUX_PANE -p "#{client_tty}"`). Filtered if it contains `"not a tty"`.
2. `tmux list-clients` sorted by activity descending — most recently active client wins.

## `aid-diff.ts` — the diff pane

`lib/sessions/aid-diff.ts` owns the right pane (~25%). Renders live `git diff` updated via `inotifywait`, keyboard-driven scrolling, inline per-file expansion. Same self-contained render-loop pattern as `aid-sessions.ts`.

### Diff modes (cycle with `t`)

| Mode | Command |
|---|---|
| HEAD (default) | `git diff HEAD` |
| staged | `git diff --cached` |
| unstaged | `git diff` |

`delta` used for syntax highlighting if on `$PATH`; falls back to `git diff --color=always`.

### Keys

| Key | Action |
|---|---|
| `↑`/`k`, `↓`/`j` | Cursor |
| `Enter`/`Space` | Toggle inline diff expand |
| `t` | Cycle diff mode |
| `r`/`Ctrl-R` | Force refresh |
| `q`/`Esc`/`Ctrl-C` | Quit |

### Env vars

| Variable | Required | Purpose |
|---|---|---|
| `AID_DIR` | yes | For `palette.lua` |
| `AID_ORC_REPO` | yes | Git repo path to watch |
| `AID_DEBUG_LOG` | no | Debug logging |

## `aid-sessions-debug` — log viewer (debug mode)

Runs when `AID_DEBUG=1`. Tails `AID_DEBUG_LOG`; renders events with colour-coded labels and `+Δms` delta column.

Categories: `INIT`, `SPAWN`, `SYNC`, `KEY`, `ACTN`, `CONV`, `CLIENT`, `SWITCH`, `RENAME`, `DEL`, `PRUNE`, `ERR`.

## `.aidignore` system (`nvim/lua/aidignore.lua`)

`.aidignore` is a per-project file (one pattern per line, `#` comments) that drives file hiding in nvim-tree and Telescope.

| Function | What it does |
|---|---|
| `patterns()` | Returns `{ raw, telescope }` — cached until `reset()` fires |
| `watch()` | `vim.uv fs_event` on the `.aidignore` file; on change: bust cache + re-apply |
| `reset()` | Bust cache + `_apply_to_nvimtree()` + `_apply_to_telescope()` + restart `watch()` |

### Live filter update

Mutates `require("nvim-tree.core").get_explorer().filters.ignore_list` in-place (avoids `setup()` re-call which destroys the window), then `api.tree.reload()`. S2 fallback: `tmux kill-pane` + re-run `ensure_treemux.sh`.

### Sidebar integration

`treemux_init.lua` prepends `AID_DIR/nvim/lua` to `package.path` so `require("aidignore")` works in the sidebar nvim. Supports a user override file at `~/.config/aid/treemux_user.lua` (loaded if present). Live filter changes handled by `aidignore.watch()` inside the sidebar nvim; `sync()` RPC only triggers `nvim-tree.api.tree.reload()`.

`_apply_to_telescope()` mutates `require("telescope.config").values.file_ignore_patterns` in-place.
