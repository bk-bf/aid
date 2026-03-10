# `aid --mode orchestrator` — Feature Breakdown & Analysis Report

---

## Executive Summary

`aid --mode orchestrator` is a tmux-native solo orchestration layout for the `aid` CLI that replicates the T3/Codex parallel workflow in a terminal-native environment. Unlike `aid --fleet` (which fans out decomposed sub-tasks to parallel agents in isolated worktrees), the orchestrator mode is designed around a **human operator** who runs multiple live opencode sessions simultaneously — one per task or project context — and switches between them with full spatial continuity. All sessions stay alive and active in the background; the operator moves focus, not the agents.

---

## The Core Premise: Sessions as First-Class Objects

In `aid --fleet`, opencode instances are ephemeral workers — spawned for a task, merged, discarded. In `aid --mode orchestrator`, each opencode session is a **persistent, named, project-scoped environment** that maps 1:1 to a tmux session. The operator accumulates sessions over time (one per feature branch, one per project, one per experiment) and the layout makes all of them navigable from a single entry point.

This is the T3/Codex workflow: parallel context windows, each fully live, with a dashboard to move between them.

---

## The Three-Pane Layout

```
┌──────────────┬───────────────────────────────┬──────────────────────┐
│ SESSIONS     │                               │                      │
│              │      opencode                 │     lazygit          │
│ > my-project │      (active session)         │     (diff review)    │
│   feature-a  │                               │                      │
│   feature-b  │      ~center ~50% width       │      ~25% width      │
│              │                               │                      │
│ other-proj   │                               │                      │
│   main       │                               │                      │
│              │                               │                      │
│  ~25% width  │                               │                      │
└──────────────┴───────────────────────────────┴──────────────────────┘
  [tmux tab: nvim]  ← separate tmux window, switch with prefix+n
```

### Pane Responsibilities

| Pane | Content | Width |
| :-- | :-- | :-- |
| **Left** | Live session navigator — all opencode tmux sessions grouped by project | ~25% |
| **Center** | Active opencode session (the selected session's tmux session brought to focus) | ~50% |
| **Right** | lazygit, rooted to the active session's repo | ~25% |
| **Tab: nvim** | Neovim, rooted to the active session's worktree — switch with `prefix+n` | full |

---

## Session Model: One tmux Session Per opencode Session

Each opencode session launched under `aid --mode orchestrator` gets its own **tmux session**, named with a project-scoped convention:

```
tmux session name: aid/<project-slug>/<session-slug>
```

Examples:
```
aid/my-project/feature-auth
aid/my-project/refactor-db
aid/other-proj/main
```

The full 3-pane layout is not replicated per session — only the center pane (opencode) and right pane (lazygit) are per-session. The left pane is a **shared supervisor pane** that lives in a dedicated `aid/dashboard` tmux session and uses tmux's `switch-client` to bring any session's layout into the terminal's foreground.

When the user selects a session in the left pane:
1. The left pane supervisor calls `tmux switch-client -t aid/<project>/<session>`
2. The terminal switches to that session's 3-pane layout (center + right)
3. The left pane reappears via a tmux `remain-on-exit` pane or a persistent sidebar window that persists across session switches

---

## The Left Pane: Session Navigator

The session navigator is a small script (`aid-sessions`) running inside the `aid/dashboard` tmux session. It:

1. Reads all tmux sessions matching `aid/*/*`
2. Groups them by `<project-slug>`
3. Renders a folder-like tree (project as collapsible group, sessions as children)
4. Highlights the currently active session
5. Shows per-session status indicators (running, idle, last activity timestamp)

### Navigation

| Key | Action |
| :-- | :-- |
| `j` / `k` | Move cursor up/down |
| `Enter` | Switch to selected session (tmux switch-client) |
| `n` | New session — prompts for project + session name, spawns layout |
| `d` | Delete session (with confirmation) |
| `r` | Rename session |
| `z` | Toggle collapse/expand project group |
| `q` | Quit navigator (returns to last active session) |

### Display Format

```
my-project/
  > feature-auth         running    2m ago
    refactor-db          idle       14m ago

other-proj/
    main                 idle       1h ago
```

`>` marks the session currently in focus. Status is derived from whether the opencode process in that session's center pane is actively producing output.

### Implementation Path

The navigator can be implemented in two stages:

**Stage 1 (shell script + fzf):** A shell script that runs `tmux list-sessions -F '#{session_name}'`, filters for `aid/` prefix, formats the tree with fzf's `--header` grouping, and calls `tmux switch-client` on selection. Fast to build, immediately functional.

**Stage 2 (dedicated TUI):** A small Go or Python curses program (`aid-sessions`) with the full keybind surface, collapse/expand, and live status polling. This is the polish layer — the fzf stage is fully usable.

The hard part of the left pane is not the rendering but the **persistent sidebar problem**: after `switch-client`, the user is now looking at the target session's panes, not the dashboard. The solution is to attach the navigator as a tmux `popup` bound to a global key (e.g. `prefix+s`), or to use a dedicated narrow tmux window that appears in every session via a linked window or a `tmux new-window` with `remain-on-exit`.

---

## Spawning the Layout

```bash
aid --mode orchestrator
```

This command:

1. Checks for an existing `aid/dashboard` tmux session — creates it if absent
2. Creates the dashboard session with the left pane (session navigator) and attaches to it
3. If no existing `aid/*/*` sessions exist, immediately prompts to create the first one
4. The first session creates the 3-pane layout: opencode (center) + lazygit (right) + nvim tab

### Creating a New Session Within the Layout

From the navigator, pressing `n`:
1. Prompts: `Project name:` (default: basename of current git repo)
2. Prompts: `Session name:` (default: current branch name)
3. `aid` creates a new tmux session named `aid/<project>/<session>`
4. Spawns the 3-pane layout inside it
5. Starts `opencode` in the center pane (new session, no pre-loaded prompt)
6. Starts `lazygit` in the right pane, rooted to the repo
7. Creates a tmux window `nvim` in that session
8. Switches focus to the new session

---

## Comparison to `aid --fleet`

| Dimension | `aid --mode orchestrator` | `aid --fleet` |
| :-- | :-- | :-- |
| **Operator model** | Human operator switching between live sessions | Automated agents running in parallel |
| **Session lifecycle** | Persistent — sessions accumulate, survive reboots | Ephemeral — spawned for a task, merged, discarded |
| **Parallelism** | All sessions alive simultaneously; human moves focus | Workers execute concurrently on decomposed sub-tasks |
| **Task decomposition** | Human decides (manual per-session context) | `/fleet-plan` writes `tasks.md` automatically |
| **Git isolation** | Optional — each session can be on its own branch | Required — each worker in a dedicated git worktree |
| **Merge workflow** | Standard git / lazygit | `/fleet-merge` supervised AI merge |
| **Layout** | 3-pane (navigator + opencode + lazygit) + nvim tab | Half/half (opencode + status/diff supervisor) |
| **Entry point** | `aid --mode orchestrator` | `aid --fleet` |
| **Best for** | Multi-project juggling, long-running sessions, T3/Codex-style context switching | Single-project parallel task execution with LLM decomposition |

These two modes are **complementary, not competing**. The orchestrator mode is the daily driver for any developer running multiple opencode contexts; fleet mode is a power tool for a single large task that benefits from parallel sub-agents.

---

## Comparison to T3/Codex Workflow

The T3 Chat workflow (as described publicly) has three elements: a session list panel, a coding agent panel, and a diff review panel. `aid --mode orchestrator` maps these directly:

| T3/Codex element | `aid --mode orchestrator` equivalent |
| :-- | :-- |
| Session/context list | Left pane session navigator |
| Coding agent | opencode in center pane |
| Diff review | lazygit in right pane |
| Switch to editor | `prefix+n` → nvim tab |

The key advantage over GUI-based equivalents (Codex Desktop, Cursor multi-session) is that this layout runs entirely in the terminal — over SSH, in tmux, survives disconnects, and requires no GUI.

---

## The Hard Parts

### 1. The Persistent Left Pane

The fundamental challenge: after `tmux switch-client`, the user is inside the target session, not the dashboard. The navigator is in a different session and is no longer visible.

**Recommended solution:** Bind the navigator to a **global tmux popup** (`prefix+s` → `tmux popup -d '#{pane_current_path}' -w 25% -h 90% -E 'aid-sessions'`). This opens the session navigator as an overlay on top of any session, and closes after selection/switch. This is the simplest, most reliable approach and requires no linked windows or session replication tricks.

**Alternative:** Use `tmux set-hook` to run a script on every `client-session-changed` event that re-attaches a dedicated left pane. This is fragile and complex.

The popup approach makes the left pane technically a **popup overlay** rather than a persistent pane — but the UX is identical: a single keybind brings up the session tree, navigation is instant, and it closes automatically after switching.

### 2. Session Metadata Persistence

tmux session names encode the project and session slug, but not other metadata (last prompt, git branch, creation time). `aid` should maintain a lightweight metadata file at `~/.local/share/aid/sessions.json`:

```json
[
  {
    "tmux_session": "aid/my-project/feature-auth",
    "repo_path": "/home/user/my-project",
    "branch": "feature/auth-refactor",
    "created_at": "2026-03-10T09:00:00Z",
    "last_active": "2026-03-10T11:23:00Z"
  }
]
```

This enables the navigator to show branch names, repo paths, and activity timestamps even for sessions that were detached or whose tmux metadata is minimal. It also enables session resurrection — recreating the layout for a session after a tmux server restart.

### 3. lazygit Synchronization

The right pane lazygit should track the repo of the active session. When spawning a new session, `aid` starts lazygit with `-p <repo_path>`. Since each tmux session has its own lazygit instance, there is no cross-session synchronization problem — each right pane is scoped to its session's repo automatically.

---

## What `aid` Is Responsible For

In orchestrator mode, `aid` does exactly these things:

1. **Bootstrap** the `aid/dashboard` tmux session and session navigator
2. **Spawn** new sessions on demand (3-pane layout: opencode + lazygit + nvim tab)
3. **Name** tmux sessions using the `aid/<project>/<session>` convention
4. **Maintain** `~/.local/share/aid/sessions.json` for metadata persistence
5. **Provide** the `aid-sessions` navigator script (fzf or TUI)
6. **Register** the global `prefix+s` popup binding on session creation

Everything else — what opencode does in the center pane, what lazygit shows, what nvim edits — is outside `aid`'s responsibility.

---

## Key Differentiators

- **T3/Codex in the terminal** — the only terminal-native layout that directly replicates the session-list + agent + diff-review spatial workflow, with full SSH compatibility
- **True parallel sessions** — unlike sequential session-switching tools, all sessions remain alive; background opencode instances continue running while you work in another session
- **Project-grouped navigation** — sessions are organized by project, not a flat list, enabling multi-project juggling without losing context
- **Zero GUI dependency** — runs over any SSH connection, survives disconnects, works in any terminal
- **Composable with `--fleet`** — orchestrator mode is the daily driver; fleet mode is invocable from within any orchestrator session when a task warrants parallel sub-agents
