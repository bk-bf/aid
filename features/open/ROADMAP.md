<!-- LOC cap: 427 (source: 3052, ratio: 0.14, updated: 2026-03-09) -->
# Roadmap

## Phase 1 — Harden (fix before any promotion)

- [>] **T-003**: Test on non-Arch machines and environments (Ubuntu, macOS, SSH, tmux version variance)
- [>] **T-022**: **Cross-distro install support** — expand `install.sh` beyond Arch/CachyOS so aid works out-of-the-box on mainstream Linux distros (Ubuntu/Debian, Fedora/RHEL, Alpine, Arch) and macOS. Currently the only managed dependency is `python-pynvim` via `pacman`; every other prerequisite is assumed present, which is false on stock Ubuntu/Fedora images.
- [ ] **T-029**: **Pane resilience — tmux-level restart loops** — closing any pane (nvim editor, treemux sidebar, opencode) via `Ctrl-d` or `exit` destroys it permanently and leaves the session in a broken state; the nvim restart loop in `aid.sh` only guards against nvim exiting cleanly but is bypassed entirely by closing the tmux pane. Each managed pane (nvim editor, treemux sidebar, opencode) should have a `while true; do ... done` wrapper or `remain-on-exit` + `respawn-pane` hook so the session self-heals without requiring `aid -i` or a full restart. Related: T-028.
- [ ] **T-028**: **Auto-close empty nvim tab on restart** — the nvim restart loop (`while true; do nvim ...; done`) opens a fresh nvim with an empty `[No Name]` buffer each time nvim exits; if the user had a file open when nvim crashed/quit, the new instance starts with an extra blank tab. Nvim should auto-close that tab (via `BufEnter` autocmd checking `bufname() == ""` and `len(getbufinfo({buflisted:1})) > 1`) once any real file is opened. Depends on T-029 for the broader restart-loop architecture.

## Phase 2 — Differentiate (architectural upgrades)

- [ ] **T-027**: **Session name in tmux status bar** — display the active aid session name (`aid@<dirname>` or `<branch>@<dirname>`) on the right side of the tmux status bar, next to the filetype indicator. Useful when multiple sessions are running concurrently. Implementation: set a session-local tmux variable in `aid.sh` and reference it in `palette.conf` status-right.

## Phase 3 — Publicize

- [ ] **T-010**: Terminal theme sync hook — optional integration point for syncing aid's palette with the host terminal emulator theme
- [ ] **T-030**: **Desktop notifications from opencode** — fire a `notify-send` (Linux) / `osascript` (macOS) notification when opencode finishes a task or requires user input. Opencode has no native hook for this; implementation options: (a) a wrapper script that tails the opencode pane output for idle/prompt patterns and fires on match, (b) a tmux `pane-focus-out` + output monitoring approach, or (c) an opencode custom command that sends the notification as its last step. The "requires input" case is harder — needs reliable detection of opencode's input-waiting state (e.g. prompt cursor visible, no tool calls in flight).

## Phase 4 — Orchestrator (T3/Codex-style parallel workflow)

Orchestrator mode is the tmux-native solo orchestration layout for `aid` that replicates the T3/Codex parallel workflow in the terminal. A human operator runs multiple live opencode sessions simultaneously — one per task or project context — and switches between them with full spatial continuity. All sessions stay alive in the background; the operator moves focus, not the agents.

Three-pane layout: session navigator (left, `~25%`) + active opencode (center, `~50%`) + lazygit diff review (right, `~25%`) + nvim tab (`prefix+n`). Each opencode session maps 1:1 to a tmux session named `aid/<project>/<session>`. The session navigator surfaces as a global `prefix+s` popup overlay, grouping sessions by project in a folder-like tree.

- [ ] **T-ORC-1**: `aid --mode orchestrator` bootstrap — create `aid/dashboard` tmux session, spawn initial 3-pane layout (opencode center, lazygit right, nvim tab), register global `prefix+s` popup binding
- [ ] **T-ORC-2**: Session navigator (`aid-sessions`) — shell script + fzf that reads all `aid/*/*` tmux sessions, groups by project slug, renders tree with status indicators (running/idle + last activity), calls `tmux switch-client` on selection
- [ ] **T-ORC-3**: New session flow — `n` in navigator prompts for project + session name (defaults: repo basename + branch), creates `aid/<project>/<session>` tmux session with full 3-pane layout
- [ ] **T-ORC-4**: Session metadata persistence — maintain `~/.local/share/aid/sessions.json` with repo path, branch, created/last-active timestamps; enables navigator to show branch names and enables session resurrection after tmux server restart
- [ ] **T-ORC-5**: Navigator TUI upgrade — replace fzf stage with dedicated curses/Go TUI supporting collapse/expand project groups, `d` delete, `r` rename, live status polling

## Deferred / under consideration

- [ ] **T-FLEET**: `aid --fleet` multi-agent orchestration — parse `tasks.md`, provision git worktrees per worker, spawn N tmux windows each running `opencode` with task prompt, half/half supervisor layout (active agent top, status/diff bottom), `/fleet-plan` decomposition command, `/fleet-merge` supervised AI merge, batch dependency model. See `AID-FLEET-FEATURE-REPORT.md` for full spec.
- [ ] **T-018**: Allow `~/.config/opencode/` passthrough — currently `OPENCODE_CONFIG_DIR` is always set to `$AID_DIR/opencode`, which means users cannot carry their existing opencode config (custom models, API keys stored in opencode's config, etc.) into an aid session. A flag or env var to opt out of the override would remove this friction for users who already have an opencode setup they're happy with. Deferred until the scope of config merging is clearer.
- [ ] **T-019**: User nvim/tmux override layer — a structured insertion point (e.g. `~/.config/aid/nvim/lua/user.lua` required last in `init.lua`) that lets users extend aid's config without forking the repo. Currently deferred because the scope of safely composing arbitrary user configs with aid's own plugin load order, keybinds, and autocmds is undefined. See ADR-012.
- [ ] **T-024 / BUG-015**: Intermittent `E5560: writefile must not be called in a fast event context` after lazygit commit; needs stack trace on next occurrence to identify call site (see [bugs/watching/BUG-015.md](bugs/watching/BUG-015.md))
- [ ] **T-025**: **Component-driven palette** — refactor `nvim/lua/palette.lua` from color-name keys (`purple`, `blue`, `lavender`) to role/component keys (`cursor_bg`, `mode_bg`, `statusline_base`, `statusline_mid`, etc.) so a reader of `palette.lua` immediately knows *what* each value affects without cross-referencing `init.lua`. The current color-name variables are consumed in multiple unrelated roles (e.g. `blue` drives both the nvim statusline devinfo segment and the tmux status bar base); splitting them into per-component keys removes that implicit coupling and makes palette customisation safe without needing to trace all call sites.
- [ ] **T-026**: **`--branch` install path layout** — currently `aid --branch feature/T-009` clones into `~/.local/share/aid/feature/T-009` (slash preserved from remote branch name), creating an unintended subdirectory hierarchy. Should be deliberate: either flatten slashes (`feature/T-009` → `feature-T-009`) or use a dedicated namespace (`~/.local/share/aid/branch/T-009`). Chosen layout should be consistent with `AID_CONFIG` path and documented.
- [ ] **T-031**: **Unit tests** — the pure logic in `aidignore.lua` (`_glob_to_lua`, `_build`, `_read_file`) and the output of `gen-tmux-palette.sh` are the only realistic test targets; everything else is tmux/nvim orchestration that is already validated by manual workflow testing. Deferred — overkill given current test surface; reconsider if `aidignore` logic grows more complex or regressions occur.
