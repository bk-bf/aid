<!-- LOC cap: 427 (source: 3052, ratio: 0.14, updated: 2026-03-09) -->
# Bugs

## Open

### BUG-023: treemux sidebar nvim fails to sync plugins — `E492: Not an editor command: Lazy! sync`

**Status**: open — investigating
**Repro**: run `aid -i` (or `install.sh` directly); the treemux plugin bootstrap step (`Bootstrapping treemux sidebar plugins`) fails with `E492: Not an editor command: Lazy! sync`.
**Notes**: the main nvim bootstrap (`Lazy! sync` via `NVIM_APPNAME=nvim`) succeeds. Only the treemux sidebar nvim (`NVIM_APPNAME=treemux`) is affected. Likely cause: the treemux sidebar nvim config (`nvim-treemux/`) does not load the `lazy.nvim` plugin manager at all (treemux uses a minimal config), so `Lazy` is not a recognised command there. `install.sh` probably needs to skip the Lazy sync step for the treemux appname, or use a different bootstrap mechanism (e.g. `packpath` / direct git clone rather than Lazy).

### BUG-018: bufferline tab bar does not show opened files

**Status**: closed — needs monitoring for confimation
**Repro**: open a file from the treemux sidebar or cold-start with a file argument; the tab bar sometimes shows no tab for the opened buffer even though the buffer is loaded.
**Notes**: buffer is confirmed loaded (`:buffers` shows it); tab bar simply does not render a tab for it. Intermittent. Root cause: treemux sidebar sends `:tabnew <file>` via msgpack-RPC (`nvim_command`); `BufAdd`/`TabNew` fire but `redrawtabline` is never called after the RPC dispatch, so bufferline's rendered tabline is stale. Fix: add `BufAdd`/`TabNew` autocmd calling `redrawtabline`. See [watching/BUG-018.md](watching/BUG-018.md).

### BUG-012: bufferline truncation count `[+N]` cannot be hidden via config

**Status**: open — upstream — do not fix in aid
**Repro**: open enough tabs that bufferline overflows the available width; a `[+N]` count appears at the right edge of the tab bar indicating how many tabs are off-screen.
**Notes**: `left_trunc_marker`/`right_trunc_marker` options control the arrow icon only — the count is hardcoded in `get_trunc_marker()` in `bufferline/ui.lua` and always renders when `count > 0`. No public option suppresses it. Per PHILOSOPHY.md §"Fixing seams that aid didn't create" — this exists regardless of aid being installed; the fix belongs upstream. Report to [akinsho/bufferline.nvim](https://github.com/akinsho/bufferline.nvim) requesting a `show_trunc_marker` / `show_trunc_count` option.

<!-- template:
### BUG-N: title
**Status**: open | investigating | blocked
**Repro**: steps
**Notes**:
-->

## Watching
*Bugs that have been observed once but not reproduced. Kept separate from Open to avoid action pressure. Promote to Open if reproduced; close if never seen again.*

### BUG-015: E5560 "writefile must not be called in a fast event context" after lazygit commit

**Status**: watching — needs reproduction
**Repro**: open lazygit (`<leader>gg`), stage files, press `c` to commit; check `:messages` after closing lazygit — E5560 present intermittently.
**Notes**: full stack trace never captured; error did not reproduce in follow-up session. All `writefile` call sites audited — none are obviously in a fast-event context. Leading suspect: `watch_buf()` fs_event watcher firing during `.git/` writes, but `vim.schedule_wrap` is used throughout so the chain should be safe. Next step: capture `:messages` stack trace on next occurrence. See [watching/BUG-015.md](watching/BUG-015.md).

## Closed

### BUG-022: tmux status bar goes blank when switching away from nvim pane

**Status**: closed — fixed 2026-03-10

**Repro**: launch `aid`; switch to the opencode or treemux pane — the tmux status bar collapses to the palette.conf fallback (session name, clock, hostname). All nvim statusline content (mode, file, git, LSP) disappears.

**Root cause**: two interacting problems. (1) `tpipeline_restore=0` (the default): tpipeline intentionally writes empty strings to the vimbridge files on `FocusLost`, so `#(cat vimbridge)` returns nothing and the bar goes blank. (2) `tpipeline_restore=1` alone is not enough: `fork_job()` snapshots `status-left`/`status-right` at nvim startup as the restore target — but `source-file palette.conf` in `aid.sh` had set those to the palette.conf strings (session name, clock) before nvim started. So every `FocusLost` restored the palette fallback instead of the vimbridge cats.

**Fix** (`aid.sh`): after sourcing `palette.conf`, immediately set `status-left`/`status-right` session-locally to the vimbridge cat strings (`#(cat #{socket_path}-\#{session_id}-vimbridge[,-R])`). This ensures `fork_job()` snapshots the correct restore target. The vimbridge files are also pre-seeded with a space placeholder so `#(cat ...)` never returns empty during the nvim startup window. `tpipeline_restore=1` is set in `nvim/init.lua` so `FocusLost` restores the cat strings (showing the last nvim statusline content frozen) rather than blanking the bar. Session-local `set-option` means `prefix+r` (`set -g` in palette.conf) never clobbers these values.

### BUG-021: LSP/treesitter semantic tokens bleed fg color over bufferline buffer name

**Status**: closed — fixed 2026-03-09 — see [archive/BUG-021.md](archive/BUG-021.md)

### BUG-020: markdown-preview opens Firefox instead of default browser; writes mozilla/ into repo

**Status**: closed — fixed 2026-03-09 — see [archive/BUG-020.md](archive/BUG-020.md)

### BUG-019: .aidignore plain names hide files whose names contain the pattern as a substring

**Status**: closed — fixed 2026-03-09 — see [archive/BUG-019.md](archive/BUG-019.md)

### BUG-014: pressing Tab in treemux sidebar opens file inside sidebar pane

**Status**: closed — fixed 2026-03-09 — see [archive/BUG-014.md](archive/BUG-014.md)

### BUG-017: prefix+Tab does not reopen the sidebar after it is closed

**Status**: closed — fixed 2026-03-09 — see [archive/BUG-017.md](archive/BUG-017.md)

### BUG-016: saving .aidignore freezes/crashes the sidebar nvim

**Status**: closed — fixed 2026-03-09 — see [archive/BUG-016.md](archive/BUG-016.md)

### BUG-009: opencode file edits not reflected in nvim until user switches pane focus

**Status**: closed — T-014 — see [archive/BUG-009.md](archive/BUG-009.md)
**Note**: `pane-focus-in` hook fires `sync.sync()` (checktime + gitsigns + nvim-tree) on every pane switch. Confirmed working: buffer reloads and gitsigns signs update within ~1s of the switch. The gitsigns update is async (manager.update is throttled); signs appear shortly after checktime completes, not instantaneously. An earlier investigation session nuked the socket by sending `--remote-send` commands directly, which caused a false "complete failure" report — the mechanism was not broken.

**BUG-013 (follow-on)**: `AID_NVIM_SOCKET` was set globally (`set-environment -g`) — launching a second aid session overwrites it for all sessions; older sessions' `pane-focus-in` hooks then fire into the wrong socket. Fixed in same pass: changed to `set-environment -t "$session"` (session-local).

### BUG-008: treemux bottom bar flickers on aidignore reset; bleed into editor line numbers

**Status**: closed — T-016

### BUG-007: dotfiles git repo deletes ~/.config/nvim symlink on branch operations

**Status**: closed — T-013 — see [archive/BUG-007.md](archive/BUG-007.md)

### BUG-006: GIT_DIR env leak — gitsigns loses git info / corruption commits

**Status**: closed — final solution tracked as T-017 — see [archive/BUG-006.md](archive/BUG-006.md)

### BUG-011: `.aidignore` changes not reflected in Telescope until nvim restart

**Status**: closed — T-021 — see [archive/BUG-011.md](archive/BUG-011.md)

### BUG-004: line numbers and sign column missing after opening a file from cheatsheet

**Status**: closed
**Repro**: launch `aid`; cheatsheet appears; open any file; line numbers and sign column are absent. `:set nu` restores them but only for that buffer — the setting disappears when the file is closed and a new buffer is opened.
**Root cause**: `_cs_apply_style` sets window-local options via `vim.wo[win]` (`number=false`, `signcolumn=no`, etc.). `setlocal x<` (inherit from global) fell back to Neovim's built-in default (`number=false`), not to our `vim.opt.number = true`, because the OPTIONS block was at the bottom of init.lua after `lazy.setup()` — so `vim.o.number` was still `false` when autocmds fired.
**Fix**: Moved OPTIONS block to the top of init.lua (right after netrw disabling), before all plugin/autocmd code. Replaced `setlocal x<` with explicit `setlocal number signcolumn=yes ...` in the restore autocmds.

### BUG-003: opencode launch command visible in pane before startup completes

**Status**: closed
**Repro**: launch `aid` from any directory; the opencode pane briefly shows the full `OPENCODE_CONFIG_DIR=... opencode ...` command string before opencode takes over the pane.
**Root cause**: `send-keys` typed the command into a live shell prompt — the command was visible during shell startup latency.
**Fix**: pass the command directly to `split-window` as an argument so the pane spawns straight into the process with no intermediate prompt or visible keystrokes.

*(BUG-005, BUG-001, BUG-002 moved to [archive/BUGS-2026-03-09.md](archive/BUGS-2026-03-09.md))*
