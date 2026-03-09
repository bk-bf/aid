# Decisions archive — superseded ADRs archived 2026-03

---

## ADR-003: Sourced vs symlinked integration *(superseded by ADR-006)*

**Date**: 2026-03
**Decision**: `aliases.sh` and `tmux.conf` are sourced from user config files. nvim config and treemux scripts are symlinked.
**Reason**: Source lines in user config are visible, annotated, and easy to remove. Symlinks for nvim and nvim-treemux allow `install.sh` re-runs to transparently update files without modifying any user-owned config.
**Superseded**: ADR-006 eliminates the `tmux.conf` source injection entirely and changes the nvim symlink target from `~/.config/nvim` to `~/.config/nvim-tdl`.

---

## ADR-004: nvim config lives in aid repo *(superseded by ADR-006)*

**Date**: 2026-03
**Decision**: Move `~/.config/nvim/` into `aid/nvim/` and symlink `~/.config/nvim → aid/nvim/`. Remove from dotfiles repo (bk-bf/.config).
**Reason**: aid is an IDE distribution — the nvim config is tightly coupled to the workspace (lazygit worktree fix, treemux keybinds, opencode integration). Co-locating it in aid makes the full IDE reproducible from a single `boot.sh` curl — no separate dotfiles clone required on a fresh machine.
**Superseded**: ADR-006 changes the symlink target from `~/.config/nvim` to `~/.config/nvim-tdl` (via `NVIM_APPNAME=nvim-tdl`) so the user's existing `~/.config/nvim` is not overwritten.
