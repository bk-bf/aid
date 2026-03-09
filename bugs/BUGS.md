# Bugs

## Open

### BUG-018: bufferline tab bar does not show opened files

**Status**: open — needs reliable repro
**Repro**: open a file from the treemux sidebar or cold-start with a file argument; the tab bar sometimes shows no tab for the opened buffer even though the buffer is loaded.
**Notes**: buffer is confirmed loaded (`:buffers` shows it); tab bar simply does not render a tab for it. Intermittent. Root cause: treemux sidebar sends `:tabnew <file>` via msgpack-RPC (`nvim_command`); `BufAdd`/`TabNew` fire but `redrawtabline` is never called after the RPC dispatch, so bufferline's rendered tabline is stale. Fix: add `BufAdd`/`TabNew` autocmd calling `redrawtabline`. See [open/BUG-018.md](open/BUG-018.md).

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
