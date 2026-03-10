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

## Phase 4 — Fleet (multi-agent parallel development)

Fleet is the tmux-native multi-agent orchestration layer for `aid`. It targets users already comfortable in the aid environment — not the VS Code migrant in their first session. The seam it smooths: the friction between tmux window management, git worktree provisioning, and running multiple opencode instances in parallel on decomposed sub-tasks of a single codebase goal.

`aid` stays pure infrastructure glue; all LLM reasoning (decomposition, merge) delegates to opencode.

- [ ] **T-FLEET-1**: `aid --fleet` core — parse `tasks.md`, provision git worktrees at `.aid/worktrees/worker-N`, spawn N tmux windows each running `opencode` with task prompt pre-loaded
- [ ] **T-FLEET-2**: Half/half tmux layout — top pane: active opencode instance; bottom pane: state-driven supervisor showing per-worker status (running/done/failed), live diff of active worker, last tool call
- [ ] **T-FLEET-3**: `window-active` tmux hook — sync bottom supervisor pane to the currently focused worker window
- [ ] **T-FLEET-4**: `/fleet-plan` opencode command — analyzes codebase + user prompt, writes `tasks.md` with `## worker-N: <name>` headings, body prompts, and `Designated files:` scope constraints
- [ ] **T-FLEET-5**: `/fleet-merge` opencode command — reads all worktree diffs, merges into main branch under supervised AI review
- [ ] **T-FLEET-6**: `aid --fleet-clean` — removes `.aid/worktrees/` after merge completes (optional teardown)
- [ ] **T-FLEET-7**: Batch dependency model in `tasks.md` — support batch markers so dependent worker groups spawn only after the prior batch merges
- [ ] **T-FLEET-8**: `:editor` window — nvim + file tree sidebar rooted to the active worker's worktree path, for direct intervention without breaking layout

**Philosophy note:** Fleet passes the seam rule — it eliminates manual worktree setup, tmux layout wiring, and cross-instance coordination overhead. It does not belong in Phases 1–3 because those target the VS Code migrant's first session; fleet targets users already past that barrier.

## Deferred / under consideration

- [ ] **T-011**: Dev branch for bleeding-edge work
- [ ] **T-012**: Consider `main` + feature-branches workflow (currently single `master`)
- [ ] **T-018**: Allow `~/.config/opencode/` passthrough — currently `OPENCODE_CONFIG_DIR` is always set to `$AID_DIR/opencode`, which means users cannot carry their existing opencode config (custom models, API keys stored in opencode's config, etc.) into an aid session. A flag or env var to opt out of the override would remove this friction for users who already have an opencode setup they're happy with. Deferred until the scope of config merging is clearer.
- [ ] **T-019**: User nvim/tmux override layer — a structured insertion point (e.g. `~/.config/aid/nvim/lua/user.lua` required last in `init.lua`) that lets users extend aid's config without forking the repo. Currently deferred because the scope of safely composing arbitrary user configs with aid's own plugin load order, keybinds, and autocmds is undefined. See ADR-012.
- [ ] **T-024 / BUG-015**: Intermittent `E5560: writefile must not be called in a fast event context` after lazygit commit; needs stack trace on next occurrence to identify call site (see [bugs/watching/BUG-015.md](bugs/watching/BUG-015.md))
- [ ] **T-025**: **Component-driven palette** — refactor `nvim/lua/palette.lua` from color-name keys (`purple`, `blue`, `lavender`) to role/component keys (`cursor_bg`, `mode_bg`, `statusline_base`, `statusline_mid`, etc.) so a reader of `palette.lua` immediately knows *what* each value affects without cross-referencing `init.lua`. The current color-name variables are consumed in multiple unrelated roles (e.g. `blue` drives both the nvim statusline devinfo segment and the tmux status bar base); splitting them into per-component keys removes that implicit coupling and makes palette customisation safe without needing to trace all call sites.

## Done

See [features/archive/ROADMAP-2026-03-10.md](../archive/ROADMAP-2026-03-10.md) for all completed items.

