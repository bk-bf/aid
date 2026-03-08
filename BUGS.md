# Bugs

## Open

### BUG-008: treemux bottom bar flickers on aidignore reset; bleed into editor line numbers

**Status**: open
**Repro**: any event that triggers `require('aidignore').reset()` (e.g. `.aidignore` change, `DirChanged`) causes two symptoms: (1) a brief visual flash in the treemux bottom status bar where the `lua require('aidignore') reset` notification appears; (2) the highlighted line numbers in the main nvim editor pane flicker, as if the refresh from the sidebar bleeds into the editor display.
**Notes**: Two sub-goals — suppress the function notification in the treemux bar; prevent the refresh from visually bleeding into the editor pane (isolate redraw to treemux only).

### BUG-010: opening an already-open file creates a duplicate tab

**Status**: open — see [bugs/BUG-010.md](bugs/BUG-010.md)

### BUG-009: opencode file edits not reflected in nvim until user switches pane focus

**Status**: open — see [bugs/BUG-009.md](bugs/BUG-009.md)

### BUG-007: dotfiles git repo deletes ~/.config/nvim-tdl symlink on branch operations

**Status**: open — see [bugs/BUG-007.md](bugs/BUG-007.md)

<!-- template:
### BUG-N: title
**Status**: open | investigating | blocked
**Repro**: steps
**Notes**:
-->

## Closed

### BUG-003: opencode launch command visible in pane before startup completes

**Status**: closed
**Repro**: launch `aid` from any directory; the opencode pane briefly shows the full `OPENCODE_CONFIG_DIR=... opencode ...` command string before opencode takes over the pane.
**Root cause**: `send-keys` typed the command into a live shell prompt — the command was visible during shell startup latency.
**Fix**: pass the command directly to `split-window` as an argument so the pane spawns straight into the process with no intermediate prompt or visible keystrokes.

### BUG-004: line numbers and sign column missing after opening a file from cheatsheet

**Status**: closed
**Repro**: launch `aid`; cheatsheet appears; open any file; line numbers and sign column are absent. `:set nu` restores them but only for that buffer — the setting disappears when the file is closed and a new buffer is opened.
**Root cause**: `_cs_apply_style` sets window-local options via `vim.wo[win]` (`number=false`, `signcolumn=no`, etc.). `setlocal x<` (inherit from global) fell back to Neovim's built-in default (`number=false`), not to our `vim.opt.number = true`, because the OPTIONS block was at the bottom of init.lua after `lazy.setup()` — so `vim.o.number` was still `false` when autocmds fired.
**Fix**: Moved OPTIONS block to the top of init.lua (right after netrw disabling), before all plugin/autocmd code. Replaced `setlocal x<` with explicit `setlocal number signcolumn=yes ...` in the restore autocmds.

### BUG-006: GIT_DIR env leak — gitsigns loses git info / corruption commits

**Status**: closed — see [bugs/BUG-006.md](bugs/BUG-006.md)

*(BUG-005, BUG-001, BUG-002 moved to [archive/BUGS-2026-03.md](archive/BUGS-2026-03.md))*
