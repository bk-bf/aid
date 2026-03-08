# Roadmap

## Phase 1 — Harden (fix before any promotion)

- [ ] **T-003**: Test on non-Arch machines and environments (Ubuntu, macOS, SSH, tmux version variance)
- [ ] **T-023 / BUG-014**: `<Tab>` in treemux sidebar opens file inside sidebar pane instead of editor pane; fix: unmap `<Tab>` in `treemux_init.lua` after plugin setup (see [bugs/BUG-014.md](bugs/BUG-014.md))
- [ ] **T-022**: **Cross-distro install support** — expand `install.sh` beyond Arch/CachyOS so aid works out-of-the-box on mainstream Linux distros (Ubuntu/Debian, Fedora/RHEL, Alpine, Arch) and macOS. Currently the only managed dependency is `python-pynvim` via `pacman`; every other prerequisite is assumed present, which is false on stock Ubuntu/Fedora images.
- [ ] **T-024 / BUG-015**: Intermittent `E5560: writefile must not be called in a fast event context` after lazygit commit; needs stack trace on next occurrence to identify call site (see [bugs/BUG-015.md](bugs/BUG-015.md))

  **Full dependency audit:**

  | Dependency | Role | Arch | Ubuntu/Debian | Fedora/RHEL | macOS |
  |------------|------|------|--------------|-------------|-------|
  | `tmux ≥ 3.2` | core | `pacman -S tmux` | `apt install tmux` (≥3.2 on 22.04+) | `dnf install tmux` | `brew install tmux` |
  | `nvim ≥ 0.9` | editor | `pacman -S neovim` | **blocker**: 24.04 ships 0.9.5 ✅; 22.04 ships 0.6 ❌ — needs PPA (`ppa:neovim-ppa/unstable`) or AppImage | `dnf install neovim` (0.9+ on F38+) | `brew install neovim` |
  | `python3-pynvim` | treemux cwd tracking (Python scripts call pynvim) | `pacman -S python-pynvim` ✅ done | `apt install python3-neovim` or `pip3 install pynvim` | `pip3 install pynvim` | `pip3 install pynvim` |
  | `lsof` | `watch_and_update.sh` reads cwd via `lsof -a -d cwd -p <pid>` | pre-installed | `apt install lsof` (often missing on minimal images) | pre-installed | pre-installed |
  | `node` + `npm` | opencode runtime; `markdown-preview.nvim` build step | `pacman -S nodejs npm` | `apt install nodejs npm` (or nvm) | `dnf install nodejs npm` | `brew install node` |
  | `git` | repo clone, TPM, lazy.nvim bootstrap | pre-installed | pre-installed | pre-installed | pre-installed (Xcode CLT) |
  | `curl` | `boot.sh` bootstrapper | pre-installed | pre-installed | pre-installed | pre-installed |

  **Known hard cases:**
  - **Ubuntu 22.04 LTS**: nvim 0.6 in the default repo is too old. The fix is either (a) add `ppa:neovim-ppa/unstable` automatically, or (b) download the official AppImage from GitHub releases and install to `~/.local/bin/nvim`. Option (b) is safer (no PPA trust/key ceremony) and works identically across all distros.
  - **Alpine / minimal containers**: `lsof` absent; alternative is `readlink /proc/<pid>/cwd` (Linux-only, already commented out in `watch_and_update.sh`). Should use `/proc/` on Linux and `lsof` only as macOS fallback.
  - **macOS**: `readlink -f` doesn't exist (BSD readlink); `lsof` is present; Homebrew required for tmux/nvim. macOS support is a separate sub-scope.
  - **`/proc/` vs `lsof` in `watch_and_update.sh`**: the upstream script already has the `/proc/` path commented out. On Linux, `/proc/<pid>/cwd` is faster, needs no extra tool, and works on all distros. A one-line OS detection (`[[ "$OSTYPE" == linux* ]]`) would let us use `/proc/` on Linux and fall back to `lsof` on macOS.

  **Proposed install.sh changes:**
  1. Add a `_detect_distro()` function returning `arch | debian | fedora | alpine | macos | unknown`.
  2. Add a `_require <cmd> [install-hint]` helper that checks `command -v` and prints a clear error with distro-specific install instructions if missing — rather than silently failing mid-install.
  3. Replace the bare `pacman`-only `python-pynvim` block with a distro-dispatch block covering all four Linux families + macOS.
  4. Add pre-flight checks (before TPM/lazy bootstrap) for `tmux`, `nvim`, `git`, `node`, `lsof` — abort with actionable message if any are missing or below minimum version.
  5. For nvim < 0.9 on Debian/Ubuntu: offer to install the official AppImage into `~/.local/bin/nvim` automatically.
  6. In `watch_and_update.sh`: switch cwd detection to `readlink /proc/<pid>/cwd` on Linux (no external tool), `lsof` only on macOS.

  **Scope boundary**: aid does not become a full package manager or attempt to install opencode (it has its own installer). The goal is: on a stock Ubuntu 24.04 / Fedora 40 / Arch image with only `git`, `curl`, and the system package manager available, `bash boot.sh` should produce a working aid session without manual intervention. macOS (Homebrew) is a stretch goal for this task; track separately if needed.

## Phase 2 — Differentiate (architectural upgrades)

- [ ] **T-005**: **Language tooling layer** — centralised install and management of LSP servers, linters, formatters, and debuggers via mason.nvim. No per-language binaries shipped with aid; users install what they need via `:Mason` or a declarative `ensure_installed` list. Stack:
  - `mason.nvim` — binary package manager (~700 packages: LSP servers, DAP adapters, linters, formatters); `:Mason` UI; `ensure_installed` for declarative setup; one-liner `require("mason").setup()`
  - `mason-lspconfig.nvim` — bridges mason ↔ `nvim-lspconfig`; `automatic_enable = true` wires installed LSP servers to the correct filetypes with zero per-server boilerplate (Neovim 0.11+ native `vim.lsp.config` API)
  - `conform.nvim` — formatter runner; one line per language in `formatters_by_ft`; applies results as a minimal diff (preserves cursor/folds); `format_on_save` one-liner; mason-installed binaries found automatically via PATH
  - `nvim-lint` — linter runner; one line per language in `linters_by_ft`; reports via `vim.diagnostic`; requires one BufWritePost autocmd (not auto-created by the plugin)
  - `nvim-dap` + `nvim-dap-ui` + `mason-nvim-dap` — debugger layer; `mason-nvim-dap` with `handlers = {}` provides working default adapter + launch configs for common languages (Python/debugpy, Node/vscode-js-debug, etc.); nvim-dap-ui auto-opens on session start; keymaps for continue/step/breakpoint
  - **Scope boundary**: aid wires these plugins together with sensible defaults and pre-configured keymaps. It does not attempt to provide zero-config per-project debugging (virtualenv paths, source maps, attach configs are inherently project-specific and belong in per-project `.nvim.lua` or `launch.json`). The seam aid smooths is "none of these tools are installed or connected" → "they are installed, connected, and have sane keymaps". The remaining per-project tuning is user-land.
  - **Known rough edge**: Python debugging — debugpy installed by mason runs in mason's own venv, not the project venv. Users must point `dap.configurations.python[n].pythonPath` at their project interpreter. Document this prominently rather than attempting a fragile auto-detect.

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

## Done

- [x] **2026-03**: T-007 — self-contained theme system; palette centralized in `nvim/lua/palette.lua`; bufferline, statusline, treemux highlights, and tmux status bar all driven from single source; `tokyonight` dependency removed from treemux; `gen-tmux-palette.sh` renders tmux colors at session start
- [x] **2026-03**: Audit `.aidignore` patterns in Telescope (`file_ignore_patterns` applied consistently?) — audit complete; revealed BUG-011 (Telescope patterns frozen at startup, not live-updated); fix tracked as T-021
- [x] **2026-03**: T-014 / BUG-009 — opencode file edits not visible in nvim until focus switch; `vim.uv.new_fs_event` watcher per open buffer's directory (`sync.watch_buf()`); BUG-013 fixed: `AID_NVIM_SOCKET` scoped per-session; `pane-focus-in` hook upgraded to `sync.sync()`
- [x] **2026-03**: T-021 / BUG-011 — `.aidignore` changes not reflected in Telescope until nvim restart; `_apply_to_telescope()` added to `aidignore.lua`
- [x] **2026-03**: T-013 / BUG-007 — eliminate `~/.config/nvim-tdl` symlink; replace with `XDG_CONFIG_HOME` override at nvim launch time
- [x] **2026-03**: T-020 / ADR-013 — sidebar architecture decided: treemux stays
- [x] **2026-03**: T-015 / BUG-010 — opening an already-open file from sidebar creates duplicate tab; `_remote_bufnr()` dedup check added
- [x] **2026-03**: T-016 / T-006 / BUG-008 — treemux bottom bar flicker + editor line-number bleed eliminated; `send-keys` replaced with direct msgpack-RPC
- [x] **2026-03**: T-001 — replace `sleep 1.5` with poll loop in `aid.sh`
- [x] **2026-03**: T-002 — complete `tdl` → `aid` rename across the backend
- [x] **2026-03**: Fix GIT_DIR env leak after lazygit closes (BUG-006)
- [x] **2026-03**: Fix lazygit `--git-dir` worktree detection
- [x] **2026-03**: `.aidignore` live reload via `vim.uv` fs_event watcher
- [x] **2026-03**: Sidebar nvim shares `aidignore.lua` via `package.path`
- [x] **2026-03**: Session naming `aid@<dirname>`; treemux sidebar width 26 cols; cheatsheet simplified
- [x] **2026-03**: BUG-003 fix — opencode launched via `split-window` direct arg
- [x] **2026-03**: POSIX CLI flags — `-a`/`--attach`, `-l`/`--list`, `-h`/`--help`, `-d`/`--debug`
- [x] **2026-03**: Stable pane IDs; editor pane restart loop; full environment isolation
- [x] **2026-03**: Move nvim config into aid repo; default install path `~/.local/share/aid`
- [x] **2026-03**: Fix cheatsheet bugs (VimEnter timing, gmatch crash, restore on last file close, line numbers after dismiss)
- [x] **2026-03**: Fix bufferline not rendering on startup; add gitsigns `numhl`; disable spell by default
- [x] **2026-03**: Add opencode custom commands (`commit.md`, `udoc.md`); README gif/screenshot; expand nvim config docs

