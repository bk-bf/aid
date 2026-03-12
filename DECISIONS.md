<!-- LOC cap: 317 (source: 3171, ratio: 0.10, updated: 2026-03-12) -->
# Decisions

Architecture decision records — why things are the way they are.

ADR statuses:
- **Under consideration** — open question, no decision made, may block other work
- **Made** — decided and implemented
- **Superseded** — previously made, overridden by a later ADR (kept for historical record)

Archived ADRs (superseded and no longer referenced by active work) are in `archive/DECISIONS-2026-03-09.md`.

---

## Under Consideration

---

### ADR-016: True in-terminal session switching — deferred research

**Date**: 2026-03-12
**Status**: Under Consideration — deferred; active workaround in place

**Context**: In `aid --mode orchestrator`, pressing Enter on a conversation owned by a
foreign `aid@*` session should ideally switch the *same* terminal window to that session
— no new window, no workspace jump — just `tmux switch-client` seamlessly from nav to
the target session.

**Why it does not work today**: The nav pane is spawned via `tmux respawn-pane`, so
its stdin is not a tty. `#{client_tty}` returns empty. `AID_CALLER_CLIENT` (the env var
that carries the calling terminal's tty to `switch-client -c`) cannot be resolved at
startup, and no `list-clients` heuristic is reliable because the user is typically
attached to a *different* session than the nav pane's session when they press Enter.

The current mitigation (commit `e74d54b`) routes focus through Hyprland instead:
- If a terminal already has the target session open → `hyprctl dispatch focuswindow` to
  bring that terminal's window to the front, crossing workspaces if needed.
- If no terminal has the session → `hyprctl dispatch exec` to spawn a new `kitty` on the
  current workspace, attaching to the target session.

This works but is Hyprland-specific and always spawns a new kitty when no terminal has
the session, rather than reusing the existing terminal.

**Research directions (not yet evaluated)**:

1. **Pass tty at respawn time** — `orchestrator.sh` could capture the invoking terminal's
   tty (`tty` or `$SSH_TTY`) and inject it as `AID_CALLER_CLIENT` into the
   `respawn-pane` command inline. Blocker: `tty` only works when the calling shell is a
   tty; the nav pane is re-spawned on every session resurrect, which may not have a
   calling tty at all.

2. **tmux hook — client-attached/client-detached** — maintain a session-local tmux env
   var `AID_LAST_CLIENT` updated by a `client-attached` hook. When the nav pane fires
   `switch-client`, read `AID_LAST_CLIENT` as the `-c` target. This is racy (hook fires
   asynchronously) but may be reliable enough in practice.

3. **Sidecar client-tracker** — a tiny daemon (shell or Bun) that `list-clients` on an
   interval or via a tmux hook and writes the most-recently-active client tty to a file.
   The nav pane reads that file at action time. Trade-off: polling overhead / staleness.

4. **tmux `display-message -c` at action time** — when the user actually presses Enter,
   query `tmux list-clients` at that instant (not at startup), take the most recently
   active client, and use it for `switch-client -c`. This avoids the startup-tty problem
   entirely. Potential issue: if the user has multiple terminals, the heuristic may pick
   the wrong one.

**Consequence for current code**: `BUG-024` is closed as mitigated. This ADR tracks the
open research question. Once a direction is validated, it should become a **Made** ADR
and the Hyprland-specific fallback in `aid-sessions.ts` should become an optional
enhancement layer rather than the primary path.

---

## Made

---

### ADR-015: bufferline redraw strategy — receiver-side `BufEnter` autocmd

**Date**: 2026-03-09
**Status**: Made

**Context**: bufferline's rendered tabline goes stale when buffers are opened via
msgpack-RPC from the treemux sidebar. Three distinct RPC commands are used depending on
context: `tabnew <file>` (new buffer), `buffer N` (dedup — file already loaded), and
`edit <file>` (neo-tree path). Each fires a different set of nvim events, which caused
the original `{ "BufAdd", "TabNew" }` autocmd to miss the `buffer N` and `edit`-on-existing-buffer cases.

**Decision**: Fix on the *receiver side* (main nvim `init.lua`) by adding `BufEnter` to
the autocmd event list:

```lua
vim.api.nvim_create_autocmd({ "BufAdd", "BufEnter", "TabNew" }, {
  callback = function() vim.cmd("redrawtabline") end,
})
```

**Why not unify the send side ("crossroad" alternative)**: The alternative was to route
all three RPC code paths through a single function in `treemux_init.lua` that opens the
file and calls `redrawtabline` atomically. This would require defining a receiver-side
Lua function in `init.lua`, calling it via `nvim_exec_lua` from `treemux_init.lua`, and
repeating similar changes for the neo-tree path. It would add cross-file coupling for a
problem that is fundamentally about the receiver not redrawing after RPC commands.
Furthermore, it would still leave the neo-tree path and any future open paths uncovered
unless similarly modified.

`BufEnter` is semantically correct — "a buffer became active, ensure the tab bar
reflects it" — and fires regardless of how the buffer switch was triggered (RPC or
normal keypress). `redrawtabline` costs ~0.1 ms and is idempotent; the extra calls on
normal keypresses are harmless. The receiver-side fix requires no changes to the send
side and covers all current and future open paths in one place.

**Scope of the same fix**: `redrawtabline` was also missing from the `<leader>tb`
tab-bar toggle, where `showtabline` was changed without a subsequent redraw. Fixed at
the same time.

**Correction (2026-03-09)**: Investigation revealed the `BufEnter` autocmd was not the
root cause of the missing-tab symptom. The real cause was `bdelete` leaving ghost buffer
entries (`buflisted=false`) that the `_remote_bufnr()` dedup helper found and switched
to — but bufferline filters on `buflisted=true` so no tab rendered. The actual fix was
changing `close_command` / `right_mouse_command` / `<leader>q` to use `bwipe` instead of
`bdelete`, which removes the buffer entry entirely. The `BufEnter` autocmd is harmless and
cheap so it remains, but it is belt-and-suspenders, not the primary fix. See
[bugs/watching/BUG-018.md](bugs/watching/BUG-018.md) for the full post-mortem.

---

### ADR-013: Sidebar architecture — treemux stays

**Date**: 2026-03-09
**Status**: Made — treemux is the permanent architecture; question closed

**Decision**: Keep treemux. The file tree sidebar remains a separate tmux pane running its own nvim process (`NVIM_APPNAME=treemux`). The layout is three tmux panes: treemux sidebar (left) | editor (middle) | opencode (right). The architecture cost is accepted.

**Trial conducted (T-020, then reverted 2026-03-09)**:
The alternative — nvim-tree inside main nvim — was implemented and reverted. Three structural problems were confirmed as not fixable without deeper surgery than the simplification was worth:

1. **Terminal bleed**: any tmux split (`M-v`, `M-h`) from the editor pane produces a new pane containing the full nvim process — nvim-tree column included. The treemux sidebar is a separate tmux pane; no nvim window can visually touch it.
2. **Tab bar spans sidebar**: bufferline renders across the full nvim width. `bufferline.offsets` is cosmetic mitigation only; it breaks on resize.
3. **Float overlaps sidebar**: any nvim float (lazygit, telescope, etc.) rendered inside the editor pane covers the full nvim width — including the column where the sidebar would be. With treemux as a separate tmux pane, floats are hard-bounded by the tmux pane edge and cannot bleed into the sidebar. 

**Why closed now**: further re-evaluation of workarounds (e.g. migrating terminal usage from tmux splits to nvim `:terminal` splits) would require ongoing UX/UI design work with no guaranteed resolution. The treemux architecture works, the bugs it carries (BUG-008, BUG-010) and the debt it carries (T-006) are concrete and fixable. Closing the question and fixing the known issues is better than continued deliberation.

**Consequence**: T-020 is closed. T-015 (BUG-010) and T-016 (BUG-008) are done. T-006 was superseded by T-016 (send-keys replaced with direct msgpack-RPC throughout).

---

### ADR-001: Install path `~/.local/share/aid`

**Date**: 2026-03-09
**Decision**: Default install to `~/.local/share/aid`, override with `AID_DIR`.
**Reason**: XDG Base Directory spec — `~/.local/share` is the correct location for user-installed application data (scripts, plugins, runtime files). Previous default `~/Documents/Projects/special_projects/tdl` was personal/idiosyncratic.

---

### ADR-002: Orphan `dev-docs` branch for private documentation

**Date**: 2026-03-09
**Decision**: Keep architecture, roadmap, bugs, and decisions in an orphan `dev-docs` branch with a git worktree at `aid/docs/`. Never merge into `master` or any code branch.
**Reason**: Documentation must be markdown + version-controlled for LLM-driven workflow, but should not be cloned by users running `boot.sh`. A separate private repo adds context-switching overhead; an orphan branch with a worktree gives file-system access without contaminating the public install.

---

### ADR-005: `--git-dir` not `--git-common-dir` for lazygit worktree detection

**Date**: 2026-03-09
**Decision**: The `<leader>gg` keybind uses `git rev-parse --git-dir` to resolve `GIT_DIR`, not `--git-common-dir`.
**Reason**: `--git-common-dir` returns the bare repo root (e.g. `aid/`). When set as `GIT_DIR` with `GIT_WORK_TREE=aid/main/`, git treats the bare root as the work-tree and sees all committed files as deleted + all files in `main/` as untracked. `--git-dir` returns the worktree-specific path (e.g. `aid/worktrees/main`) which correctly scopes the index to the checked-out branch, giving lazygit a clean view.

---

### ADR-006: Full environment isolation

**Date**: 2026-03-09 (extended 2026-03-09)
**Decision**: aid must not conflict with the user's existing nvim or tmux setup. All runtime state is isolated:

- **tmux server**: dedicated socket `tmux -L aid -f <AID_DIR>/tmux.conf` — `-f` suppresses all user tmux configs; `~/.config/tmux/` is never touched
- **tmux plugins**: TPM and all plugins installed under `$AID_DATA/tmux/plugins/` (`~/.local/share/aid/tmux/plugins/` for end users) — not `~/.config/tmux/plugins/` and not inside the source repo (see ADR-014)
- **nvim (XDG dirs)**: `XDG_CONFIG_HOME=$AID_DIR` — config source lives in the repo (`$AID_DIR/nvim/`). `XDG_DATA_HOME=~/.local/share/aid`, `XDG_STATE_HOME=~/.local/state/aid`, `XDG_CACHE_HOME=~/.cache/aid` — runtime artefacts land in the standard XDG hierarchy under an aid-specific namespace. With `NVIM_APPNAME=nvim`, nvim appends the appname, yielding `~/.local/share/aid/nvim/`, etc. `~/.config/nvim`, `~/.local/share/nvim`, `~/.local/state/nvim`, and `~/.cache/nvim` are never touched.
- **sidebar nvim**: `XDG_CONFIG_HOME=~/.config/aid` (config is a symlink there — required because treemux resolves via that path); `XDG_DATA_HOME`, `XDG_STATE_HOME`, `XDG_CACHE_HOME` as above, so sidebar data/state/cache land under `~/.local/share/aid/treemux/`, etc.
- **opencode**: `OPENCODE_CONFIG_DIR=$AID_DIR/opencode` — config reads from inside the repo, not `~/.config/opencode/`
- **install.sh**: does not inject into any user config file; only writes `~/.config/aid/treemux` (symlink) and `~/.local/bin/aid` (symlink)
- **All scripts** (`ensure_treemux.sh`, `sync.lua`): use `tmux -L aid` for every tmux command

**Extension rationale (2026-03-09)**: The original decision only set `XDG_CONFIG_HOME`, leaving `XDG_DATA_HOME`, `XDG_STATE_HOME`, and `XDG_CACHE_HOME` unset. This caused nvim to write plugin data, state (shada/swap/undo), and cache into `~/.local/share/nvim/`, `~/.local/state/nvim/`, and `~/.cache/nvim/` — violating the isolation guarantee. A second attempt set all four dirs to `$AID_DIR`, which moved the artefacts inside the source tree instead. The correct fix is `XDG_CONFIG_HOME=$AID_DIR` (config source) and the remaining three dirs pointing to `~/.local/share/aid`, `~/.local/state/aid`, `~/.cache/aid` — standard XDG locations under an aid-specific namespace. TPM and the treemux plugin were also relocated from `~/.config/tmux/plugins/` to `$AID_DIR/tmux/plugins/` (later moved to `$AID_DATA/tmux/plugins/` — see ADR-014).

**Supersedes**: ADR-003, ADR-004 (see `archive/DECISIONS-2026-03-09.md`).

---

### ADR-007: OPTIONS block must be at the top of `init.lua`

**Date**: 2026-03-09
**Decision**: The `vim.opt.*` global options block (line numbers, sign column, tab settings, etc.) is placed at the very top of `init.lua` — immediately after leader key and netrw disable — before any `require()`, plugin setup, or `vim.api.nvim_create_autocmd()` call.

**Reason**: Neovim evaluates `init.lua` top-to-bottom. Autocmds registered with `vim.api.nvim_create_autocmd` capture a reference to the option at registration time only if they read it directly. More subtly: window-local option inheritance (`setlocal x<`) falls back to the *global* option (`vim.o.x`) at the moment the `setlocal x<` command executes — not to the value that will be set later in the file.

The cheatsheet dismiss autocmd uses:
```lua
vim.cmd("setlocal number relativenumber& signcolumn=yes ...")
```
The `&` suffix on `relativenumber` means "inherit global". If `vim.opt.relativenumber = false` has not yet been set when this executes, Neovim's built-in default (`false`) happens to match — but `vim.opt.number = true` must be set before any autocmd that reads or resets `number` can see the intended value.

Placing the OPTIONS block last (or after `lazy.setup()`) meant that:
1. `VimEnter` fired before `vim.opt.number = true` was reached.
2. The cheatsheet's window-local `number = false` override was applied.
3. When the cheatsheet was dismissed via `setlocal number ...`, the global `vim.o.number` was still `false` (Neovim's built-in default), so line numbers did not appear on the restored file buffer.

**Rule**: Any option that an autocmd or plugin `config` function needs to read must be set before that code runs. The safest position is immediately after `mapleader` and netrw disable — before all `require()` calls.

---

### ADR-008: `.aidignore` live reload via `explorer.filters.ignore_list` mutation

**Date**: 2026-03-09
**Decision**: Live-updating nvim-tree filters when `.aidignore` changes is done by mutating `require("nvim-tree.core").get_explorer().filters.ignore_list` in-place, then calling `api.tree.reload()`. No `setup()` re-call.

**Reason**: `nvim-tree.setup()` is not safe to call on a live tree — it calls `purge_all_state()` internally, which destroys the window/explorer (visible as a blank pane). The `ignore_list` field is a `table<string, boolean>` read on every `should_filter()` invocation inside nvim-tree's render loop. Mutating it in-place causes the next `reload()` to use the updated patterns with zero visual disruption — no window close/reopen, cursor preserved.

**Stability evidence**: `ignore_list` has existed under this exact name since nvim-tree's multi-instance refactor (PR #2841), with 33 commits to `filters.lua` since then — name unchanged. If the field is renamed in a future nvim-tree update, the code silently skips the mutation (guarded by `if explorer and explorer.filters and explorer.filters.ignore_list`).

**S2 fallback**: documented in `aidignore.lua:99–103`. If `ignore_list` is ever removed, fall back to `tmux kill-pane <sidebar_pane_id>` + re-run `ensure_treemux.sh` to reopen the sidebar fresh. ~0.5s visual glitch but uses only public APIs.

**Alternatives rejected**:
- `setup()` re-call: destroys the live explorer (tested, reverted).
- Restart sidebar nvim entirely on every `.aidignore` change: too disruptive (~0.5s blank + state loss).

---

### ADR-009: Shared `package.path` for sidebar nvim via `AID_DIR/nvim/lua`

**Date**: 2026-03-09
**Decision**: `treemux_init.lua` prepends `AID_DIR/nvim/lua` to `package.path` at the top of the file, before any `require()`. This allows `require("aidignore")` (and other main-nvim modules) to work in the sidebar nvim without duplicating code.

**Reason**: The sidebar nvim (`NVIM_APPNAME=treemux`) is an isolated process with its own config directory. Shared Lua modules like `aidignore.lua` live in `nvim/lua/` under the main nvim config. Without the `package.path` addition, `require("aidignore")` in `treemux_init.lua` fails with `module not found`.

**Why `package.path` and not `rtp`**: `vim.opt.rtp:prepend(dir)` expects `dir` to be a directory that *contains* a `lua/` subdirectory (nvim's module resolution convention). `AID_DIR/nvim/lua` is the `lua/` dir itself — prepending it to `rtp` would make nvim look for `AID_DIR/nvim/lua/lua/aidignore.lua`, which doesn't exist. `package.path` is the correct mechanism for adding a plain directory of `.lua` files.

**Why not duplicate the file**: duplicating `aidignore.lua` into `nvim-treemux/` would create a maintenance burden — two copies of the same ignore-list logic, filter-application logic, and S2 fallback documentation would need to stay in sync.

**Note**: `package.path` is still required now that ADR-013 has confirmed treemux stays permanently.

---

### ADR-010: `tmux.conf` default keybinds

**Date**: 2026-03-09
**Decision**: `aid/tmux.conf` ships two categories of keybinds beyond the essential (reload, sidebar toggle, mouse):

1. **Pane navigation** (`M-Left/Right/Up/Down`, `C-h/j/k/l`, no prefix) — shipped as defaults.
2. **Pane management** (`M-v` split-h, `M-h` split-v, `M-q` kill-pane, `M-S-q` detach) — shipped as defaults, commented as opinionated.

The navigation binds (`C-h/j/k/l`) are functionally integrated with aid's nvim config via `tmux.nvim`, which intercepts them inside nvim and passes them to tmux when there is no nvim split in that direction. They cannot be omitted without breaking cross-pane navigation for the expected three-pane layout. The management binds are validated for aid's workflow but carry a note that users should remove or rebind if they conflict with their terminal emulator.

**Reason**: aid's tmux server is isolated — its config is the *only* config loaded; the user's personal `~/.config/tmux/.tmux.conf` is never sourced. Shipping no navigation binds would leave users unable to move between panes without mouse or the verbose `<prefix><arrow>`. The chosen binds have been validated against aid's three-pane layout over sustained daily use. Splitting, kill-pane, and detach are common enough to be useful defaults; they are clearly labelled so users know they can replace them.

---

### ADR-011: `XDG_CONFIG_HOME` injection inline (not global) for nvim config isolation

**Date**: 2026-03-09
**Decision**: `aid.sh` does **not** set `XDG_CONFIG_HOME` globally in the tmux server environment. Instead, it injects `XDG_CONFIG_HOME=$AID_DIR` inline on two specific commands only: (1) the `respawn-pane` nvim restart loop command, and (2) the `@treemux-nvim-command` tmux option that treemux uses to launch the sidebar nvim. This keeps `XDG_CONFIG_HOME` scoped to the nvim processes, not to every pane shell or opencode.

Combined with `NVIM_APPNAME=nvim` (main editor) and `NVIM_APPNAME=treemux` (sidebar), nvim resolves config paths to `$AID_DIR/nvim` and `~/.config/aid/treemux`. The user's `~/.config/nvim` is never touched.

**Reason**: `NVIM_APPNAME` alone can only be a single path component — it cannot produce nested paths like `~/.config/aid/nvim`. The only way to get everything under a single config root is to redirect `XDG_CONFIG_HOME`. However, setting it globally in the tmux server environment (via `tmux set-environment -g`) would cause every pane shell, opencode, and any other tool launched inside the aid session to see `XDG_CONFIG_HOME=$AID_DIR`, which is wrong — those processes should use their own config dirs. The inline injection scopes the override precisely to the nvim invocations.

**Scope of `XDG_CONFIG_HOME` override**: The override is scoped to the specific nvim processes (main editor and sidebar). Subprocesses launched *by nvim* (LSP servers, formatters, shell commands via `!`) will also inherit it via process inheritance, which is intentional — they should resolve config relative to the aid environment. The only known footgun is a tool that reads `XDG_CONFIG_HOME` to write user-global state (e.g. a tool that stores usage history there). Such tools are rare; document if one is found.

**Alternatives rejected**:
- `NVIM_APPNAME=aid` + `NVIM_APPNAME=aid-treemux`: gives `~/.config/aid` (main) but `~/.config/aid-treemux` (sidebar) — not truly nested.
- Pass `--cmd "set rtp+=..."` to nvim directly: requires rebuilding nvim's entire runtimepath resolution, fragile across nvim versions.
- Set `XDG_CONFIG_HOME` globally via `set-environment -g`: bleeds into opencode and other pane shells — rejected.

---

### ADR-012: User nvim and tmux config in `~/.config/aid` — intentionally separate from system config

**Date**: 2026-03-09
**Decision**: Users who want to customise nvim or tmux behaviour within aid must edit files under `~/.config/aid/` (which are symlinks back into the repo). There is no mechanism to layer a user's existing `~/.config/nvim` or `~/.config/tmux/.tmux.conf` into aid's environment.

**Reason**: The scope of safely merging arbitrary user nvim configs (plugins, autocmds, LSP setups, colorschemes) or tmux configs (key bindings, plugins, hooks) with aid's own config without breaking aid's functionality is large and undefined. Aid's nvim config depends on specific plugin load order, specific keybinds, and specific autocmds. A user's config could silently override any of these. Until aid has a defined extension/override API, the correct default is full isolation. Users are informed of this tradeoff in the README.

**Under consideration**: A structured override layer — e.g. a `~/.config/aid/nvim/lua/user.lua` that is `require()`d last in `init.lua`, giving users a safe insertion point. Not implemented yet; tracked in ROADMAP.md as T-019.

---

### ADR-014: `tmux/plugins/` moved to `AID_DATA`, not `AID_DIR`

**Date**: 2026-03-10
**Status**: Made — supersedes original ADR-014 (2026-03-09)

**Decision**: TPM and all tmux plugins are cloned into `$AID_DATA/tmux/plugins/` (`~/.local/share/aid/tmux/plugins/` for end users; `~/.local/share/aid/<branch>/tmux/plugins/` for branch sessions) rather than `$AID_DIR/tmux/plugins/` (inside the source dir).

**Reason**: The introduction of `AID_DATA` / `AID_CONFIG` isolation (for `aid --branch <name>` sessions) made the original placement untenable — two branch sessions cannot share the same `$AID_DIR/tmux/plugins/` directory, and writing runtime-installed data into the source tree is wrong regardless. Moving plugins to `AID_DATA` achieves clean source/data separation: the repo holds only source files and config; runtime-installed data (TPM, treemux, etc.) lives in the XDG data hierarchy outside the repo. `tmux.conf` references plugins via `#{E:TMUX_PLUGIN_MANAGER_PATH}` and `#{E:AID_DATA}` (lazy tmux expansion) rather than hardcoded `AID_DIR` paths.

**For end users**: `AID_DATA` defaults to `~/.local/share/aid`, which is also where `boot.sh` clones the source. Plugins land at `~/.local/share/aid/tmux/plugins/` — same physical path as before, so there is no user-visible change.

---

## Superseded

ADRs in this section were previously made but overridden by a later decision. Kept for historical record.

---

### ADR-014 (original, 2026-03-09): `tmux/plugins/` inside `AID_DIR`

Superseded by ADR-014 (2026-03-10) above. Original decision kept plugins inside the repo (`$AID_DIR/tmux/plugins/`) to keep the source self-contained. This became untenable once `AID_DATA` isolation was introduced for `aid --branch <name>` sessions.

### ADR-003, ADR-004: Earlier isolation model

Superseded by ADR-006. Full text in `archive/DECISIONS-2026-03-09.md`.
