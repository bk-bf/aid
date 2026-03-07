# Bugs

## Open

<!-- template:
### BUG-N: title
**Status**: open | investigating | blocked
**Repro**: steps
**Notes**:
-->

## Closed

### BUG-005: aidignore `setup()` re-call destroyed sidebar

**Status**: closed
**Repro**: editing `.aidignore` while sidebar is open; sidebar goes completely blank with no tree visible and no error message.
**Root cause**: the first live-reload attempt called `nvim-tree.setup()` again from the file watcher callback. `setup()` internally calls `purge_all_state()` which tears down the window/explorer — visible as a blank pane.
**Fix**: mutate `require("nvim-tree.core").get_explorer().filters.ignore_list` (a `table<string, boolean>`) directly in-place, then call `api.tree.reload()`. No `setup()` re-call. The `ignore_list` field is read on every `should_filter()` call in nvim-tree's render loop, so the mutation takes effect on the next reload with zero visual disruption.

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

### BUG-001: lazygit shows phantom deleted files / wrong context from nvim keybind

**Status**: closed (final fix 2026-03)
**Root cause (original)**: `lazygit.nvim` passes `-p <worktree-root>` which expands to `--git-dir=<path>/.git/`. In a git worktree `.git` is a file, not a directory — so lazygit can't find the repo.
**Root cause (deeper)**: The initial fix used `git rev-parse --git-common-dir` to resolve `GIT_DIR`. This returns the bare repo root (`aid/`). When set as `GIT_DIR` with `GIT_WORK_TREE=aid/main/`, git uses the bare root as the work-tree and treats `aid/main/` as a subdirectory — showing all committed files as deleted and all files in `main/` as untracked.
**Root cause (recurrence)**: The second fix only set `GIT_DIR`/`GIT_WORK_TREE` when `.git` was a *file* (worktree case). If `.git` was a *directory* (normal repo) or the walk-up found nothing, the vars were left `nil` — lazygit fell back to its internal `-p` flag, which again broke bare-repo + worktree setups. Additionally, this meant opening lazygit from `main/` always gave the `master` worktree context, making it impossible to push or operate on `dev-docs` without a `docs/` buffer open.
**Final fix**: `find_git_root()` helper handles both `.git` file (worktree) and `.git` directory (normal repo). Falls back to `cwd` if `buf_dir` walk-up finds nothing. Always sets both `GIT_DIR` + `GIT_WORK_TREE` — lazygit context now tracks the open buffer's worktree automatically. Opening a file from `docs/` → lazygit operates on `dev-docs` (push works, correct branch shown).
**Affects**: any bare-repo + worktree setup where nvim is opened from inside a worktree.

### BUG-002: Broken symlinks after bare repo restructure

**Status**: closed
**Root cause**: Symlinks in `~/.config/nvim-treemux/` were created when the repo was a regular clone at `aid/`. After restructuring to a bare repo + worktrees, files moved to `aid/main/` but the old symlinks still pointed to `aid/nvim-treemux/` (bare root, no working tree).
**Fix**: Re-ran `install.sh` from `aid/main/` — `$TDL` resolves to the correct path so `ln -sf` recreates all symlinks pointing at `aid/main/`.
