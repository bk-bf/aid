# Roadmap

## Phase 1 — Harden (fix before any promotion)

- [x] **T-001**: Replace `sleep 1.5` in `aid.sh` with a poll loop — `until tmux -L tdl show-option -gqv @treemux-key-Tab | grep -q .; do sleep 0.1; done` with a timeout escape hatch; current fixed sleep races on slow machines / high-latency SSH
- [x] **T-002**: Complete `tdl` → `aid` rename across the backend — ~104 token replacements across 7 files in a single coordinated commit; touch points: `TDL_DIR` → `AID_DIR`, `TDL_IGNORE` → `AID_IGNORE`, `TDL_NVIM_SOCKET` → `AID_NVIM_SOCKET`, `tmux -L tdl` → `tmux -L aid`, `NVIM_APPNAME=nvim-tdl` → `nvim-aid`, `~/.config/nvim-tdl` → `~/.config/nvim-aid`, local var `TDL`/`tdl_dir` → `AID`/`aid_dir`, temp session `_tdl_install` → `_aid_install`, socket path `/tmp/tdl-nvim-*` → `/tmp/aid-nvim-*`; files: `aid.sh`, `install.sh`, `boot.sh`, `nvim/init.lua`, `nvim/lua/sync.lua`, `nvim-treemux/treemux_init.lua`, `README.md`
- [ ] **T-003**: Test on non-Arch machines and environments (Ubuntu, macOS, SSH, tmux version variance)
- [ ] **T-004**: Audit `.aidignore` patterns in Telescope (`file_ignore_patterns` applied consistently?)
- [ ] **T-013**: Fix BUG-007 — eliminate `~/.config/nvim-tdl` symlink; replace with `XDG_CONFIG_HOME` override at nvim launch time so dotfile-manager git ops can never silently break aid's config (see [bugs/BUG-007.md](bugs/BUG-007.md))
- [ ] **T-014**: Fix BUG-009 — opencode file edits not visible in nvim until focus switch; add a push-based `checktime` trigger (tmux `pane-focus-in` hook or `vim.uv` fs_event watcher) so buffers reload without requiring manual pane switch (see [bugs/BUG-009.md](bugs/BUG-009.md))
- [ ] **T-015**: Fix BUG-010 — opening an already-open file from the sidebar creates a duplicate tab; add `bufnr()` dedup check in `tabnew_follow_symlinks()` before issuing `tabnew` (see [bugs/BUG-010.md](bugs/BUG-010.md))
- [ ] **T-016**: Fix BUG-008 — treemux bottom bar flickers and editor line numbers bleed on `.aidignore` reset; suppress the Lua `require` notification in the treemux bar and isolate the redraw to the sidebar pane only

## Phase 2 — Differentiate (architectural upgrades)

- [ ] **T-005**: **Language tooling layer** — centralised install and management of LSP servers, linters, formatters, and debuggers via mason.nvim. No per-language binaries shipped with aid; users install what they need via `:Mason` or a declarative `ensure_installed` list. Stack:
  - `mason.nvim` — binary package manager (~700 packages: LSP servers, DAP adapters, linters, formatters); `:Mason` UI; `ensure_installed` for declarative setup; one-liner `require("mason").setup()`
  - `mason-lspconfig.nvim` — bridges mason ↔ `nvim-lspconfig`; `automatic_enable = true` wires installed LSP servers to the correct filetypes with zero per-server boilerplate (Neovim 0.11+ native `vim.lsp.config` API)
  - `conform.nvim` — formatter runner; one line per language in `formatters_by_ft`; applies results as a minimal diff (preserves cursor/folds); `format_on_save` one-liner; mason-installed binaries found automatically via PATH
  - `nvim-lint` — linter runner; one line per language in `linters_by_ft`; reports via `vim.diagnostic`; requires one BufWritePost autocmd (not auto-created by the plugin)
  - `nvim-dap` + `nvim-dap-ui` + `mason-nvim-dap` — debugger layer; `mason-nvim-dap` with `handlers = {}` provides working default adapter + launch configs for common languages (Python/debugpy, Node/vscode-js-debug, etc.); nvim-dap-ui auto-opens on session start; keymaps for continue/step/breakpoint
  - **Scope boundary**: aid wires these plugins together with sensible defaults and pre-configured keymaps. It does not attempt to provide zero-config per-project debugging (virtualenv paths, source maps, attach configs are inherently project-specific and belong in per-project `.nvim.lua` or `launch.json`). The seam aid smooths is "none of these tools are installed or connected" → "they are installed, connected, and have sane keymaps". The remaining per-project tuning is user-land.
  - **Known rough edge**: Python debugging — debugpy installed by mason runs in mason's own venv, not the project venv. Users must point `dap.configurations.python[n].pythonPath` at their project interpreter. Document this prominently rather than attempting a fragile auto-detect.

- [ ] **T-006**: Upgrade sidebar sync to RPC — replace `tmux send-keys :NvimTreeRefresh` with `vim.fn.sockconnect` to sidebar's `$NVIM` socket; current send-keys path silently injects keystrokes if user is typing in the sidebar, risking file corruption
- [ ] **T-007**: Self-contained theme system — aid owns its color palette; bufferline, statusbar, treemux, and opencode driven from a single source in the repo (no external theme dependency)
- [ ] **T-008**: Add `aid update` command — git pull + re-run `install.sh`
- [ ] **T-017**: Replace `lazygit.nvim` env-var integration with a raw terminal float — build the lazygit command directly (`lazygit -w <work_tree> -g <git_dir>`), never touch `GIT_DIR`/`GIT_WORK_TREE` env vars; eliminates BUG-006 class of env leaks permanently (see [bugs/BUG-006.md](bugs/BUG-006.md))

## Phase 3 — Publicize

- [ ] **T-009**: Opencode pane opt-in via flag (`aid --no-ai` skips opencode pane) — removes "requires opencode" adoption barrier
- [ ] **T-010**: Terminal theme sync hook — optional integration point for syncing aid's palette with the host terminal emulator theme

## Deferred / under consideration

- [ ] **T-011**: Dev branch for bleeding-edge work
- [ ] **T-012**: Consider `main` + feature-branches workflow (currently single `master`)
- [ ] **T-018**: Allow `~/.config/opencode/` passthrough — currently `OPENCODE_CONFIG_DIR` is always set to `$AID_DIR/opencode`, which means users cannot carry their existing opencode config (custom models, API keys stored in opencode's config, etc.) into an aid session. A flag or env var to opt out of the override would remove this friction for users who already have an opencode setup they're happy with. Deferred until the scope of config merging is clearer.
- [ ] **T-019**: User nvim/tmux override layer — a structured insertion point (e.g. `~/.config/aid/nvim/lua/user.lua` required last in `init.lua`) that lets users extend aid's config without forking the repo. Currently deferred because the scope of safely composing arbitrary user configs with aid's own plugin load order, keybinds, and autocmds is undefined. See ADR-012.

## Done

- [x] **2026-03**: Fix GIT_DIR env leak after lazygit closes (BUG-006) — clear `vim.env.GIT_DIR/GIT_WORK_TREE` immediately after `vim.cmd("LazyGit")` so gitsigns re-attaches cleanly on `gs.refresh()` and statusline git info is not lost
- [x] **2026-03**: Fix lazygit `--git-dir` worktree detection (final): `find_git_root()` handles both worktree (`.git` file) and normal repo (`.git` dir); `cwd` fallback; always sets `GIT_DIR`+`GIT_WORK_TREE` so lazygit context tracks the open buffer's worktree — push and branch ops work correctly from any worktree
- [x] **2026-03**: `.aidignore` live reload — `aidignore.lua`: disk-based pattern read, `vim.uv` fs_event watcher, `explorer.filters.ignore_list` mutation, live reload in both nvim instances without `setup()` re-call (see ADR-008)
- [x] **2026-03**: Sidebar nvim shares `aidignore.lua` via `package.path` — `TDL_DIR/nvim/lua` prepended in `treemux_init.lua`; sidebar calls `aidignore.watch()` after setup (see ADR-009)
- [x] **2026-03**: Session naming `aid@<dirname>` (was `nvim@<basename>`)
- [x] **2026-03**: Treemux sidebar width 26 cols (was 21)
- [x] **2026-03**: Cheatsheet simplified — removed `_cs_apply_style`, `_cs_buf` tracking, 3 autocmds, styling, read-only setup; now just `vim.cmd("edit " .. _cs_path)`
- [x] **2026-03**: BUG-003 fix — opencode launched via `split-window` direct arg (not `send-keys`); editor pane via `respawn-pane -k` (not `send-keys`); bypasses zsh autocorrect entirely
- [x] **2026-03**: `sync.lua`: `reload()` now has explicit step 3 (`aidignore.reset()`) before `sync()`; sidebar refresh sends `:lua require('aidignore').reset()` instead of `:NvimTreeRefresh`
- [x] **2026-03**: `aid.sh` creates empty `.aidignore` in launch dir if none found up the tree (ensures file watcher always has a target)
- [x] **2026-03**: Move nvim config into aid repo (`aid/nvim/`), symlink `~/.config/nvim → aid/nvim/`
- [x] **2026-03**: Default install path → `~/.local/share/aid` (XDG compliant)
- [x] **2026-03**: Braille spinner on headless nvim sync steps
- [x] **2026-03**: Bare repo + worktree structure (`aid/main/` + `aid/docs/`)
- [x] **2026-03**: Full environment isolation — dedicated tmux server socket (`tmux -L tdl -f`), `NVIM_APPNAME=nvim-tdl`, no tmux.conf injection, `~/.config/nvim` left untouched
- [x] **2026-03**: `sync.lua` — added `reload()` entry point (`<leader>R`): hot-reloads tmux + nvim config then calls `sync()`
- [x] **2026-03**: Fix cheatsheet auto-open (was broken by `nvim .` → fixed to bare `nvim`)
- [x] **2026-03**: Fix `ensure_treemux.sh` layout enforcement (sidebar_pane scoping bug + early exit bug)
- [x] **2026-03**: Fix `status-interval 0` breaking prefix indicator in status bar
- [x] **2026-03**: Move `sync.lua` → `nvim/lua/sync.lua` (fix `module 'sync' not found`)
- [x] **2026-03**: Convert `aid()` shell function in `aliases.sh` to standalone `aid.sh` script; symlinked into `~/.local/bin/aid` by `install.sh`; `TDL_DIR` resolved via `realpath "${BASH_SOURCE[0]}"`
- [x] **2026-03**: POSIX CLI flags — `aid` always launches new session; `-a`/`--attach [name]` to attach; `-l`/`--list`; `-h`/`--help`; unknown flags error with hint; `attach_or_switch` helper handles in-session context; `-d`/`--debug` pre-pass enables `set -x` and `dbg()` step tracing throughout launch sequence
- [x] **2026-03**: Session routing in `aid.sh` — auto-attach to single session; numbered menu for multiple; `aid ls` / `aid new` / `aid <name>` subcommands
- [x] **2026-03**: Stable pane IDs — capture `editor_pane_id` and `opencode_pane_id` by `#{pane_id}` immediately after creation; immune to treemux sidebar insertion
- [x] **2026-03**: Editor pane restart loop — `while true; do rm -f <socket>; nvim --listen <socket>; done`; pane is never a bare shell
- [x] **2026-03**: `NVIM_APPNAME` set in tmux server env (`set-environment -g`) and inline in send-keys (belt-and-suspenders)
- [x] **2026-03**: `OPENCODE_CONFIG_DIR` set in tmux server env + inline in opencode send-keys; isolates opencode config to `aid/opencode/`
- [x] **2026-03**: `TDL_NVIM_SOCKET` set in tmux server env before `ensure_treemux.sh` runs; sidebar nvim reads it at startup to set `g:nvim_tree_remote_socket_path`
- [x] **2026-03**: `@treemux-tree-width 21` moved to `tmux.conf` (must be set before `sidebar.tmux` runs)
- [x] **2026-03**: Fix treemux file-open creating unwanted split — `tabnew_follow_symlinks` sets `tmux_opts.pane = nil` to disable fallback split
- [x] **2026-03**: Fix line numbers / sign column missing after cheatsheet dismissed (BUG-004) — moved OPTIONS block to top of `init.lua` before all plugins/autocmds; explicit `setlocal number signcolumn=yes` in dismiss + `BufWinEnter` belt-and-suspenders autocmd
- [x] **2026-03**: Fix cheatsheet `VimEnter` autocmd registered too late — moved from inside nvim-tree's `config` function to top-level AUTOCMDS section of `init.lua`
- [x] **2026-03**: Fix cheatsheet restore when last file is closed — `BufEnter` autocmd detects empty unnamed buffer and calls `_cs_open()`
- [x] **2026-03**: Fix bufferline not rendering on startup — `event = "VimEnter"` + `config` with `vim.defer_fn(redrawtabline, 50)`
- [x] **2026-03**: Fix cheatsheet gmatch crash (`init.lua:82`) — `for pre, key, post` had 3 captures but pattern only yielded 2; fixed to `for pre, post`
- [x] **2026-03**: Add `numhl = true` to gitsigns — line numbers colored by git status (add/change/delete)
- [x] **2026-03**: Disable spell checking by default — removed `spell = true` from FileType autocmd; `<leader>sS` still toggles; German (`de`) spelllang still available via `<leader>sd`
- [x] **2026-03**: Add opencode custom commands — `commit.md` (conventional commit from staged diff), `udoc.md` (update docs to reflect code changes)
- [x] **2026-03**: README — usage gif/screenshot added
- [x] **2026-03**: Expand nvim config docs — plugin list, keymaps, LSP setup documented
