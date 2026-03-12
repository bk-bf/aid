# Orchestrator mode

## Overview

Orchestrator mode (`aid --mode orchestrator`) is a multi-session layout for running many opencode conversations in parallel, each in its own isolated tmux session, all navigable from a single persistent sidebar.

It replaces the standard aid layout (sidebar + nvim + opencode in one session) with a T3/Codex-style workspace:

```
┌─────────────────────┬────────────────────────────────────────┐
│  aid@aid  sessions  │                                        │
│                     │           opencode TUI                 │
│ ❯ aid          live │                                        │
│  ├─ ● Conv title    │                                        │
│  └─ ○ Other conv    │                                        │
│                     │                                        │
├─────────────────────┴────────────────────────────────────────┤
│  debug log pane  (only with -d / AID_DEBUG=1)                │
└──────────────────────────────────────────────────────────────┘
```

Each `aid@<name>` tmux session contains:
- **Left pane** (~20%): `aid-sessions.ts` — the TypeScript/Bun navigator
- **Centre pane** (~55%): `opencode` — the AI TUI
- **Right pane** (~25%): `aid-diff.ts` — the live diff review pane
- **Bottom pane** (full width, debug mode only): `aid-sessions-debug` — live log viewer

## Entry point

```
aid --mode orchestrator                      launch / attach
aid -d --mode orchestrator                   same, with debug pane + log
aid --branch <b> --mode orchestrator         run from a feature branch install
```

`aid.sh` consumes `--mode` in its pre-pass and dispatches to
`lib/orchestrator.sh` via `exec`. All `AID_*` vars are exported before the
exec so `orchestrator.sh` inherits the same environment.

## Boot sequence

```
aid.sh --mode orchestrator
  └── exec lib/orchestrator.sh
        ├── _ensure_server          — start tmux -L aid server if not running
        ├── check for existing orchestrator sessions (@aid_mode=orchestrator)
        │     none found → _new_session_from_cwd
        │     found      → _attach_or_switch to most recently used
        └── _new_session_from_cwd / spawn_orc_session
              ├── tmux new-session -d -s aid@<name>
              ├── set-environment: AID_ORC_PORT, AID_ORC_NAME, AID_ORC_REPO,
              │                    AID_NVIM_SOCKET, AID_ORC_NAV_PANE,
              │                    AID_ORC_ORC_PANE, AID_ORC_DIFF_PANE
              ├── [debug] split bottom 2 lines → dbg_pane (sleep infinity placeholder)
              ├── split right 80% → orc_pane (sleep infinity placeholder)
              ├── split orc_pane right 25% → diff_pane (sleep infinity placeholder)
              ├── respawn orc_pane  → opencode --port <AID_ORC_PORT> <repo_path>
              ├── respawn nav_pane  → aid-sessions.ts
              ├── respawn diff_pane → aid-diff.ts
              ├── [debug] respawn dbg_pane → aid-sessions-debug
              ├── set-option @aid_mode orchestrator  (for session discovery)
              ├── _meta_write <name> <repo_path>     (persist to sessions.json)
              ├── set-hook pane-focus-in → aid-meta-touch (last_active timestamp)
              └── _attach_or_switch aid@<name>
```

### Session naming

Session name: `aid@<sanitised-basename-of-repo>`. Numeric suffix appended if
the name already exists (`aid@project`, `aid@project2`, …).

### `_attach_or_switch`

Uses `switch-client -c "$AID_CALLER_CLIENT" -t "$target"` when `TMUX` is set
and `AID_CALLER_CLIENT` is available — so the correct terminal is switched even
when called from a pane subprocess (e.g. the `n` key in `aid-sessions`).
Falls back to plain `switch-client -t` when the var is absent, and
`tmux attach` when not inside tmux at all.

`AID_CALLER_CLIENT` is resolved once by `aid-sessions.ts` at startup. See
[Cross-session conversation loading](#cross-session-conversation-loading) for
the full resolution strategy.

### Opencode isolation

Each session's opencode instance is started with:
```
XDG_DATA_HOME=<AID_DATA>           — per-branch conversation store
OPENCODE_CONFIG_DIR=<AID_DIR>/opencode
OPENCODE_TUI_CONFIG=<AID_DIR>/opencode/tui.json
opencode --port <AID_ORC_PORT> <repo_path>
```

`XDG_DATA_HOME` is injected **inline** on the `respawn-pane` command (not just
as a global tmux env var) because `respawn-pane` inline commands do not inherit
the global tmux environment. Without it, opencode falls back to
`~/.local/share/opencode` and serves the user's entire cross-project history.

`AID_ORC_PORT` is a deterministic port derived from the session name:
`4200 + (cksum(name) % 1000)` — stable across restarts.

## Session metadata (`aid-meta`)

Session records are stored in `$AID_DATA/sessions.json` as a JSON array.
Dead sessions (tmux gone, metadata present) are shown in the navigator and
can be resurrected.

### Schema

```json
{
  "tmux_session": "aid@project",
  "repo_path":    "/home/user/project",
  "branch":       "main",
  "created_at":   "2026-03-11T22:00:00Z",
  "last_active":  "2026-03-12T00:01:00Z"
}
```

### API (sourced by `orchestrator.sh`)

| Function | Purpose |
|---|---|
| `_meta_write <name> <repo>` | Upsert entry; preserves `created_at` from existing record |
| `_meta_touch <session>` | Update `last_active` timestamp (called by `pane-focus-in` hook via `aid-meta-touch`) |
| `_meta_remove <session>` | Delete entry by session name |
| `_meta_get <session> <field>` | Read one field; returns `""` when missing or jq absent |
| `_meta_all_sessions` | Print all `tmux_session` values, one per line |

All functions degrade gracefully when `jq` is absent (return 0, print nothing).

### Dead session prune

At `aid-sessions.ts` startup, `pruneDead()` removes entries from
`sessions.json` for sessions that no longer exist in tmux. Runs once in the
background so it does not delay the initial render.

## `aid-sessions.ts` — the navigator

`lib/sessions/aid-sessions.ts` is a self-contained Bun/TypeScript process that
owns the entire left pane. It renders directly to the terminal via ANSI escape
codes (alternate screen buffer, absolute cursor positioning), handles raw key
input, and calls the opencode HTTP API and tmux directly via `Bun.spawn` /
`fetch`.

There is no fzf dependency. The navigator is a persistent process for the
lifetime of the tmux session.

### Rendering

- **Alternate screen buffer** — no scrollback leak; `\x1b[?1049h` on start,
  `\x1b[?1049l` on exit.
- **Absolute cursor positioning** — every render clears the screen and redraws
  all lines via `\x1b[row;1H`. No `\n` is ever written (prevents scrollback
  accumulation).
- **`clampLine(s, cols)`** — hard-clamps every rendered line to the pane width
  by walking rune-by-rune and skipping ANSI escape sequences (zero-width).
  Nothing ever wraps regardless of terminal size.
- **Colors** — loaded at runtime from `nvim/lua/palette.lua` via `loadPalette()`
  (regex parses `M.key = "#rrggbb"` lines). No color values are hardcoded in
  the navigator itself.

### Visual structure

```
 aid@aid          sessions    ← title bar (row 1): blue bg, full-width
❯ aid          live           ← session header: purple caret when current
 ├─ ● Conv title    2m ago    ← active conv: purple ●, bold white title
 └─ ○ Other conv    5m ago    ← inactive conv: dim gray ○
```

- **Selection**: purple `▌` left-edge bar + very subtle bg tint. The bar is the
  primary cursor signal so bold/color on the row text is never obscured.
- **`●`/`○` markers**: purple filled = currently active in opencode; dim gray
  hollow = inactive.
- **Timestamps**: dim gray, right-aligned. Dropped gracefully when the pane is
  too narrow.
- **Tree lines** (`├─`/`└─`): lavender, connecting conv rows to their session.

### Sync strategy

Two-tier approach to keep the UI responsive:

| Tier | Trigger | What it does | Latency |
|---|---|---|---|
| **Optimistic patch** | Immediately on action | Mutates `state.items` in-place and calls `render()` | ~0ms |
| **Fast active sync** (`refreshActiveConvs`) | Every cursor move (↑↓jk, page) | Re-queries `AID_ORC_ACTIVE_CONV` from tmux env per session, patches `active` flags | ~1 tmux RTT per session |
| **Full refresh** (`refresh`) | After actions that change the list; 5s interval safety net | Rebuilds entire item list from tmux + opencode HTTP | ~1–2 full RTTs |

Optimistic patches are applied for:
- **Conv switch** (`Enter`): `active` flags flipped instantly before any tmux/HTTP calls.
- **Delete** (`dy`): item removed from list instantly; stranded `sep` rows cleaned up.
- **Rename** (`r`): title patched in-place instantly; reverts to full refresh (which re-reads from server) on HTTP failure.
- **New conversation** (`n`): `new conversation…` placeholder inserted at top of session group instantly; replaced with real item after HTTP POST returns.

### Keys

| Key | Action |
|---|---|
| `↑` / `k` | Move cursor up |
| `↓` / `j` | Move cursor down |
| `PgUp` / `PgDn` | Move cursor ±10 rows |
| `Enter` | Conv row: load conversation (switches to foreign session if needed). Session header: focus that session's terminal. Dead session: resurrect. |
| `n` | New conversation in current session |
| `r` | Inline rename (conv title or session name) |
| `d` | Inline delete with `y`/`n` confirm |
| `Ctrl-R` | Force full refresh |
| `q` / `Esc` / `Ctrl-C` | Quit |

### Cross-session conversation loading

When the user selects a conversation that belongs to a **different** aid session,
`loadConversation` detects the mismatch (`curSession !== targetSession`) and
delegates to `switchToForeignConv`.

```
switchToForeignConv(foreignSession, convId)
  1. computePort(foreignSession) → POST /tui/select-session {"sessionID":"<convId>"}
     (fires first so opencode is already on the right conv before the terminal appears)
  2. tmux set-environment -t foreignSession AID_ORC_ACTIVE_CONV=<convId>
  3. tmux list-clients -t foreignSession → foreignClients[]

  Case A — terminal already has the session open:
    a. hyprlandWindowForPid(foreignClients[0].pid)
         → walk /proc/<pid>/status PPid until a PID matches hyprctl clients[]
         → returns hyprland window address
    b. hyprctl dispatch focuswindow address:<addr>
         (pulls the window to the front even if it is on another workspace)
    fallback (no hyprctl): switch-client -c <tty> -t foreignSession

  Case B — no terminal has the session open:
    a. resolveClient() → own tty
    b. hyprlandWindowForPid(ourPid) → own window address
    c. hyprctl clients -j → read own workspace name
    d. hyprctl dispatch exec "[workspace <ws>] kitty -- tmux -L aid attach -t foreignSession"
       (or plain kitty spawn if hyprctl unavailable)
       The conv is already selected (step 1) so the user lands on the right conv
       as soon as the terminal renders.
```

The navigator never touches panes inside the foreign session — it only routes
terminal focus.

### `resolveClient`

Resolves the tty of the terminal the user is sitting at, for use with
`switch-client -c`. Resolution order:

1. `AID_CALLER_CLIENT` env var (set at startup — see below). Strings containing
   `"not a tty"` are treated as empty (the `tty(1)` binary prints this when
   stdin is not a terminal, e.g. inside a `respawn-pane` process).
2. Global `tmux list-clients -F "#{client_activity} #{client_name}"` sorted by
   activity descending — most recently active client wins. This handles the case
   where the user's terminal is attached to a *different* session than the nav
   pane's own session.

`AID_CALLER_CLIENT` is resolved once at startup:

1. `tmux display-message -t $TMUX_PANE -p "#{client_tty}"` — works even when
   stdin is not a tty (the common case for a respawned pane).
2. `tty(1)` binary — only stored if it does **not** contain `"not a tty"`.



### Rename

Inline input field replaces the cursor row. `Enter` confirms, `Esc` cancels.

```
Conv rename:
  1. Patch title in state.items → render()  (optimistic)
  2. GET orcPort → PATCH /session/<convId> {"title":"<new>"}
  3. On failure: setStatus("rename failed") + full refresh

Session rename:
  1. tmux has-session check (bail if new name already exists)
  2. tmux rename-session old new
  3. writeMeta (update sessions.json)
  4. full refresh
```

### Delete

```
Conv delete (dy):
  1. Remove item from state.items, clamp cursor → render()  (optimistic)
  2. DELETE /session/<convId>
  3. full refresh

Session delete (dy):
  1. Remove session + all its convs from state.items → render()  (optimistic)
  2. GET /session → DELETE each conv
  3. full refresh

Dead session delete (dy):
  1. Remove item → render()  (optimistic)
  2. writeMeta (remove from sessions.json)
  3. full refresh
```

### Auto-refresh

```
boot()
  └── early-retry loop: polls every 500ms for 3s if 0 convs (opencode not ready yet)
  └── setInterval(refresh, 5000)  — safety-net full refresh every 5s (nav mode only)
```

The 5s interval is skipped while in `rename` or `delete-confirm` mode to avoid
interrupting user input.

## `aid-diff` — the diff pane

`lib/sessions/aid-diff.ts` is a self-contained Bun/TypeScript process that owns
the right pane (~25%). It renders a live `git diff` view, updated on every file
change via `inotifywait`, and supports keyboard-driven scrolling and inline
per-file expansion.

### Layout position

```
┌─────────────────┬─────────────────────────────┬──────────────────┐
│  aid-sessions   │                             │    aid-diff      │
│   nav (~20%)    │       opencode TUI          │ git diff HEAD    │
│                 │        orc (~55%)           │  diff (~25%)     │
├─────────────────┴─────────────────────────────┴──────────────────┤
│  debug log pane  (only with -d / AID_DEBUG=1)                    │
└──────────────────────────────────────────────────────────────────┘
```

### Update model

`inotifywait -m -r -e close_write,create,delete,move` watches the repo root.
Events are debounced 150 ms before triggering a `git diff` run. On startup a
full refresh runs immediately.

When `delta` is on `$PATH` it is used for syntax-highlighted output; otherwise
`git diff --color=always` is used directly.

### Diff modes

Cycled with `t`:

| Mode | Command |
|---|---|
| **HEAD** (default) | `git diff HEAD` |
| **staged** | `git diff --cached` |
| **unstaged** | `git diff` |

The title bar always shows the current mode.

### Visual structure

```
  git diff HEAD  [t]oggle  [r]efresh             ← title bar (row 1)

  src/foo.ts                      +12 -3         ← stat line (cursor)
  lib/bar.ts                       +5 -1
  README.md                        +2 -0
  ─── src/foo.ts ───────────────────────         ← expanded diff block
  @@ -10,7 +10,7 @@
  -  return old;
  +  return new;
```

- Stat lines show file path (left) and `+adds -dels` (right), colour-coded
  green/red.
- The cursor row is highlighted with a left-edge bar `▌` (same pattern as
  `aid-sessions`).
- Expanded diff blocks are inserted inline directly below the selected stat
  line and removed when toggled off.
- When the repo has no changes, a centered "no changes" message is shown.
- When `AID_ORC_REPO` is not a git repo, a "not a git repository" message is
  shown and no watcher is started.

### Keys

| Key | Action |
|---|---|
| `↑` / `k` | Cursor up |
| `↓` / `j` | Cursor down |
| `Enter` / `Space` | Toggle inline diff expand for selected file |
| `t` | Cycle diff mode: HEAD → staged → unstaged → HEAD |
| `r` / `Ctrl-R` | Force refresh |
| `q` / `Esc` / `Ctrl-C` | Quit |

### Env vars consumed

| Variable | Required | Purpose |
|---|---|---|
| `AID_DIR` | yes | Aid install root (for `palette.lua`) |
| `AID_ORC_REPO` | yes | Git repo path to watch and diff |
| `AID_DEBUG_LOG` | no | Enables debug logging when set |

### Design notes

- **No fzf, no pipes**: same fully self-contained render-loop + raw-input
  pattern as `aid-sessions.ts`.
- **`delta` optional**: detected at runtime via `Bun.which("delta")`. Diff
  output is rendered as pre-coloured ANSI text regardless of which renderer is
  used; `aid-diff` does not interpret the diff syntax itself.
- **Palette at runtime**: same `loadPalette()` call as `aid-sessions.ts` —
  palette.lua is the single source of truth for colours.
- **Graceful non-repo handling**: `git rev-parse --git-dir` is run first; if
  it fails the watcher and refresh loop are skipped and a static message is
  shown.

## `aid-sessions-debug` — log viewer

Runs in the bottom pane when `AID_DEBUG=1`. Tails `AID_DEBUG_LOG` and renders
each event with colour-coded category labels and a `+Δms` delta column.

### Debug log format

```
<unix_ms> <CATEGORY> <message>
```

| Category | Meaning |
|---|---|
| `INIT` | Startup events |
| `SPAWN` | Pane lifecycle steps from `orchestrator.sh` |
| `SYNC` | Full refresh start/done |
| `KEY` | Raw key bytes received |
| `ACTN` | Higher-level action (new conv, resurrect, session switch) |
| `CONV` | Conversation load request (includes `curSession`, `foreign` flag) |
| `CLIENT` | Result of `resolveClient()` — resolved tty or `<none>` |
| `SWITCH` | `switchToForeignConv` steps — clients found, window address, spawn decision |
| `RENAME` | Rename operation |
| `DEL` | Delete operation |
| `PRUNE` | Dead session metadata cleanup |
| `ERR` | Any error |

## Environment variables

### Session-local (set per `aid@<name>` session by `orchestrator.sh`)

| Variable | Value | Purpose |
|---|---|---|
| `AID_ORC_PORT` | `4200 + cksum(name) % 1000` | Opencode HTTP API port; stable across restarts |
| `AID_ORC_NAME` | `<name>` | Session short name (without `aid@` prefix) |
| `AID_ORC_REPO` | `<repo_path>` | Absolute path to the session's repo |
| `AID_ORC_NAV_PANE` | `%<id>` | Pane ID of the navigator (left pane) |
| `AID_ORC_ORC_PANE` | `%<id>` | Pane ID of the opencode TUI (centre pane) |
| `AID_ORC_DIFF_PANE` | `%<id>` | Pane ID of the diff review pane (right pane) |
| `AID_ORC_ACTIVE_CONV` | opencode session ID | Currently loaded conversation (best-effort) |
| `AID_NVIM_SOCKET` | `/tmp/aid-nvim-<session>.sock` | Unused in orchestrator mode (no nvim pane) |
| `AID_DEBUG_LOG` | `<repo>/log-<timestamp>.txt` | Debug log path (only when `AID_DEBUG=1`) |

### Per-process

| Variable | Set by | Purpose |
|---|---|---|
| `AID_CALLER_CLIENT` | `aid-sessions.ts` startup | tty of the terminal the user is sitting at; used by `resolveClient()` as the preferred source; filtered if it contains `"not a tty"` |

## Key design decisions

- **TypeScript/Bun rewrite of bash+fzf**: the navigator is a single
  self-contained process with its own render loop, raw key handling, and HTTP
  client. No fzf dependency, no subprocess-per-keypress, no IPC pipes between
  the navigator and a background ticker.

- **Optimistic UI updates**: all mutations (switch, delete, rename, new conv)
  patch `state.items` and call `render()` synchronously before any async I/O.
  The subsequent HTTP/tmux call reconciles with a full `refresh()`. This makes
  every action feel instant regardless of network/tmux latency.

- **`clampLine` instead of terminal width truncation**: every rendered line is
  clamped in-process to `process.stdout.columns` visible characters. Prevents
  wrapping in narrow panes without relying on `stty cols` or terminal
  capabilities.

- **Palette loaded at runtime**: `loadPalette()` reads `nvim/lua/palette.lua`
  once at startup. No color values are duplicated between the navigator and the
  nvim theme — palette.lua is the single source of truth.

- **Deterministic opencode port**: `4200 + cksum(name) % 1000` — no port
  scanning, no dynamic discovery, stable across session restart. The navigator
  knows the port before opencode has started.

- **`XDG_DATA_HOME` inline on `respawn-pane`**: prevents opencode from serving
  the user's global `~/.local/share/opencode` history. Must be inline because
  `respawn-pane` commands do not inherit global tmux env vars.

- **`@aid_mode=orchestrator` session tag**: set on each session at spawn time
  so `orchestrator.sh` can list and attach to orchestrator sessions without
  interfering with plain aid sessions that might share the same tmux server.

- **Hyprland-aware cross-session focus**: `switchToForeignConv` uses
  `hyprctl clients -j` + `/proc/<pid>/status` ancestry walking to map a tmux
  client PID to its Hyprland window address, then calls
  `hyprctl dispatch focuswindow address:<addr>`. This pulls the terminal to the
  front even when it is on a different Hyprland workspace. When no terminal has
  the session open, a new kitty window is spawned on the same workspace as the
  nav pane's terminal via `hyprctl dispatch exec "[workspace N] kitty …"`.
  All hyprctl calls degrade gracefully when hyprctl is unavailable (falls back
  to plain `switch-client`).

- **Conv selection fires before terminal focus**: `orcSelectConversation` (HTTP
  POST) is always the first step in `switchToForeignConv`, before any
  `focuswindow` or kitty spawn. This guarantees opencode is already displaying
  the correct conversation by the time the user's eyes reach the screen.
