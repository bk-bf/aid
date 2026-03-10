<!-- LOC cap: 427 (source: 3052, ratio: 0.14, updated: 2026-03-09) -->
# Roadmap

## Phase 1 — Harden (fix before any promotion)

- [ ] **T-003**: Test on non-Arch machines and environments (Ubuntu, macOS, SSH, tmux version variance)
- [ ] **T-022**: **Cross-distro install support** — expand `install.sh` beyond Arch/CachyOS so aid works out-of-the-box on mainstream Linux distros (Ubuntu/Debian, Fedora/RHEL, Alpine, Arch) and macOS. Currently the only managed dependency is `python-pynvim` via `pacman`; every other prerequisite is assumed present, which is false on stock Ubuntu/Fedora images.

## Phase 2 — Differentiate (architectural upgrades)

- [ ] **T-008**: Add `aid --update` command — git pull + re-run `install.sh`
- [ ] **T-017**: Replace `lazygit.nvim` env-var integration with a raw terminal float — build the lazygit command directly (`lazygit -w <work_tree> -g <git_dir>`), never touch `GIT_DIR`/`GIT_WORK_TREE` env vars; eliminates BUG-006 class of env leaks permanently (see [bugs/BUG-006.md](bugs/BUG-006.md))

## Phase 3 — Publicize

- [ ] **T-009**: Opencode pane opt-in via flag (`aid --no-ai` skips opencode pane) — removes "requires opencode" adoption barrier
- [ ] **T-010**: Terminal theme sync hook — optional integration point for syncing aid's palette with the host terminal emulator theme

## Deferred / under consideration

- [ ] **T-011**: Dev branch for bleeding-edge work
- [ ] **T-012**: Consider `main` + feature-branches workflow (currently single `master`)
- [ ] **T-018**: Allow `~/.config/opencode/` passthrough — currently `OPENCODE_CONFIG_DIR` is always set to `$AID_DIR/opencode`, which means users cannot carry their existing opencode config (custom models, API keys stored in opencode's config, etc.) into an aid session. A flag or env var to opt out of the override would remove this friction for users who already have an opencode setup they're happy with. Deferred until the scope of config merging is clearer.
- [ ] **T-019**: User nvim/tmux override layer — a structured insertion point (e.g. `~/.config/aid/nvim/lua/user.lua` required last in `init.lua`) that lets users extend aid's config without forking the repo. Currently deferred because the scope of safely composing arbitrary user configs with aid's own plugin load order, keybinds, and autocmds is undefined. See ADR-012.
- [ ] **T-024 / BUG-015**: Intermittent `E5560: writefile must not be called in a fast event context` after lazygit commit; needs stack trace on next occurrence to identify call site (see [bugs/watching/BUG-015.md](bugs/watching/BUG-015.md))
- [ ] **T-025**: **Component-driven palette** — refactor `nvim/lua/palette.lua` from color-name keys (`purple`, `blue`, `lavender`) to role/component keys (`cursor_bg`, `mode_bg`, `statusline_base`, `statusline_mid`, etc.) so a reader of `palette.lua` immediately knows *what* each value affects without cross-referencing `init.lua`. The current color-name variables are consumed in multiple unrelated roles (e.g. `blue` drives both the nvim statusline devinfo segment and the tmux status bar base); splitting them into per-component keys removes that implicit coupling and makes palette customisation safe without needing to trace all call sites.

## Done

- [x] **2026-03-10**: BUG-022 — tmux status bar goes blank when switching away from nvim pane; `tpipeline_restore=1` + vimbridge cat strings pre-seeded as session-local `status-left`/`status-right` in `aid.sh` before nvim starts so `fork_job()` snapshots the correct restore target; vimbridge files pre-seeded with a space placeholder to prevent empty-cat flash during nvim startup
- [x] **2026-03-09**: T-005 — language tooling layer; mason.nvim (:Mason UI, ~700 packages), mason-lspconfig.nvim (automatic_enable bridges mason → lspconfig), conform.nvim (format_on_save, LSP fallback, `<leader>F`), nvim-lint (BufWritePost trigger), nvim-dap + nvim-dap-ui + mason-nvim-dap (auto-open UI, `handlers={}` default configs, full keymap set); no tools pre-installed — users install what they need via `:Mason`
- [x] **2026-03-09**: T-023 / BUG-014 — `<Tab>` in treemux sidebar opens file inside sidebar pane; fixed: `<Tab>` remapped to `<Nop>` in `treemux_init.lua` after plugin setup
- [x] **2026-03-09**: T-007 — self-contained theme system; palette centralized in `nvim/lua/palette.lua`; bufferline, statusline, treemux highlights, and tmux status bar all driven from single source; `tokyonight` dependency removed from treemux; `gen-tmux-palette.sh` renders tmux colors at session start
- [x] **2026-03-09**: Audit `.aidignore` patterns in Telescope (`file_ignore_patterns` applied consistently?) — audit complete; revealed BUG-011 (Telescope patterns frozen at startup, not live-updated); fix tracked as T-021
- [x] **2026-03-09**: T-014 / BUG-009 — opencode file edits not visible in nvim until focus switch; `vim.uv.new_fs_event` watcher per open buffer's directory (`sync.watch_buf()`); BUG-013 fixed: `AID_NVIM_SOCKET` scoped per-session; `pane-focus-in` hook upgraded to `sync.sync()`
- [x] **2026-03-09**: T-021 / BUG-011 — `.aidignore` changes not reflected in Telescope until nvim restart; `_apply_to_telescope()` added to `aidignore.lua`
- [x] **2026-03-09**: T-013 / BUG-007 — eliminate `~/.config/nvim-tdl` symlink; replace with `XDG_CONFIG_HOME` override at nvim launch time
- [x] **2026-03-09**: T-020 / ADR-013 — sidebar architecture decided: treemux stays
- [x] **2026-03-09**: T-015 / BUG-010 — opening an already-open file from sidebar creates duplicate tab; `_remote_bufnr()` dedup check added
- [x] **2026-03-09**: T-016 / T-006 / BUG-008 — treemux bottom bar flicker + editor line-number bleed eliminated; `send-keys` replaced with direct msgpack-RPC
- [x] **2026-03-09**: T-001 — replace `sleep 1.5` with poll loop in `aid.sh`
- [x] **2026-03-09**: T-002 — complete `tdl` → `aid` rename across the backend
- [x] **2026-03-09**: Fix GIT_DIR env leak after lazygit closes (BUG-006)
- [x] **2026-03-09**: Fix lazygit `--git-dir` worktree detection
- [x] **2026-03-09**: `.aidignore` live reload via `vim.uv` fs_event watcher
- [x] **2026-03-09**: Sidebar nvim shares `aidignore.lua` via `package.path`
- [x] **2026-03-09**: Session naming `aid@<dirname>`; treemux sidebar width 26 cols; cheatsheet simplified
- [x] **2026-03-09**: BUG-003 fix — opencode launched via `split-window` direct arg
- [x] **2026-03-09**: POSIX CLI flags — `-a`/`--attach`, `-l`/`--list`, `-h`/`--help`, `-d`/`--debug`
- [x] **2026-03-09**: Stable pane IDs; editor pane restart loop; full environment isolation
- [x] **2026-03-09**: Move nvim config into aid repo; default install path `~/.local/share/aid`
- [x] **2026-03-09**: Fix cheatsheet bugs (VimEnter timing, gmatch crash, restore on last file close, line numbers after dismiss)
- [x] **2026-03-09**: Fix bufferline not rendering on startup; add gitsigns `numhl`; disable spell by default
- [x] **2026-03-09**: Add opencode custom commands (`commit.md`, `udoc.md`); README gif/screenshot; expand nvim config docs
- [x] **2026-03-09**: `/lsp` command — Setup mode wires Mason LSP binaries into `opencode.json`; Diagnose mode runs available CLI tools (lua-language-server, selene, etc.) directly and fixes reported issues; Step 4b bootstraps linter config files; Step D3 tree-walks for `.luarc.json` to eliminate lua-ls false positives; command collapsed from 553 lines to 296 lines by making tool invocation language/tool agnostic
- [x] **2026-03-09**: Fix lua-ls `"Undefined global vim"` false positives — `.luarc.json` tree-walk in `/lsp` D3; removed `selene.toml`/`vim.yml` from repo (personal dev tool configs, gitignored); fixed `vim.loop` → `vim.uv` and `nvim-tree.lib.open` → `nvim-tree.api.tree.open` in `treemux_init.lua`
- [x] **2026-03-09**: Autocompletion popup — `nvim-cmp` auto-show on keypress (`completeopt=menu,menuone,noinsert`), `vim.snippet` engine via `nvim-snippets`, function signature hints via `cmp-nvim-lsp-signature-help`, doc scroll keymaps `<C-d>`/`<C-u>`

