# Orchestrator mode

## Overview

Orchestrator mode (`aid --mode orchestrator`) is a multi-session layout for running many opencode conversations in parallel, each in its own isolated tmux session, all navigable from a single persistent sidebar.

It replaces the standard aid layout (sidebar + nvim + opencode in one session) with a T3/Codex-style workspace:

```
┌─────────────────────┬────────────────────────────────────────┐
│  aid-sessions (fzf) │                                        │
│                     │           opencode TUI                 │
│  aid@project-a ●    │                                        │
│    > Conv title      │                                        │
│      Other conv      │                                        │
│                     │                                        │
│  aid@project-b      │                                        │
│    Conv title        │                                        │
├─────────────────────┴────────────────────────────────────────┤
│  debug log pane  (only with -d / AID_DEBUG=1)                │
└──────────────────────────────────────────────────────────────┘
```

Each `aid@<name>` tmux session contains:
- **Left pane** (~25%): `aid-sessions` — the fzf navigator
- **Right pane** (~75%): `opencode` — the AI TUI
- **Bottom pane** (full width, debug mode only): `aid-sessions-debug` — live log viewer

## Entry point

```
aid --mode orchestrator          launch / attach
aid -d --mode orchestrator       same, with debug pane + log
aid --branch <b> --mode orchestrator   run from a feature branch install
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
              │                    AID_NVIM_SOCKET, AID_ORC_NAV_PANE, AID_ORC_ORC_PANE
              ├── [debug] split bottom 25% → dbg_pane (sleep infinity placeholder)
              ├── split right 75% → orc_pane (sleep infinity placeholder)
              ├── respawn orc_pane  → opencode --port <AID_ORC_PORT> <repo_path>
              ├── respawn nav_pane  → aid-sessions
              ├── [debug] respawn dbg_pane → aid-sessions-debug
              ├── set-option @aid_mode orchestrator  (for session discovery)
              ├── _meta_write <name> <repo_path>     (persist to sessions.json)
              ├── set-hook pane-focus-in → aid-meta-touch (last_active timestamp)
              └── _attach_or_switch aid@<name>
```

### Session naming

Session name: `aid@<sanitised-basename-of-repo>`.  Numeric suffix appended if
the name already exists (`aid@project`, `aid@project2`, …).

### `_attach_or_switch`

Uses `switch-client -c "$AID_CALLER_CLIENT" -t "$target"` when `TMUX` is set
and `AID_CALLER_CLIENT` is available — so the correct terminal is switched even
when called from a pane subprocess (e.g. the `n` key in `aid-sessions`).
Falls back to plain `switch-client -t` when the var is absent, and
`tmux attach` when not inside tmux at all.

`AID_CALLER_CLIENT` is resolved once by `aid-sessions` at startup (from
`#{client_tty}` of the nav pane, or `tty(1)` as fallback) and exported so all
subprocesses inherit it.

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

### API (sourced by `orchestrator.sh` and `aid-sessions`)

| Function | Purpose |
|---|---|
| `_meta_write <name> <repo>` | Upsert entry; preserves `created_at` from existing record |
| `_meta_touch <session>` | Update `last_active` timestamp (called by `pane-focus-in` hook via `aid-meta-touch`) |
| `_meta_remove <session>` | Delete entry by session name |
| `_meta_get <session> <field>` | Read one field; returns `""` when missing or jq absent |
| `_meta_all_sessions` | Print all `tmux_session` values, one per line |

All functions degrade gracefully when `jq` is absent (return 0, print nothing).

### Dead session prune

At `aid-sessions` startup, `_prune_dead_sessions` removes entries from
`sessions.json` for sessions that no longer exist in tmux. Runs once in the
background so it does not delay the initial fzf render.

## `aid-sessions` — the navigator

`lib/sessions/aid-sessions` is the persistent left-pane process. It runs a
`while true` fzf loop — fzf is restarted in-place after every action rather
than `exec`-ing a new process, so the background ticker keeps running against
the same `--listen` port for the lifetime of the session.

### Keys

| Key | Action |
|---|---|
| `Enter` | Session header: switch tmux client to that session. Conv row: load conversation via HTTP API. Dead session: resurrect. |
| `n` | New session from `$PWD` (calls `orchestrator.sh --new`) |
| `r` | Rename focused session (tmux `display-popup` prompt) |
| `d` | Delete focused item (confirm via `aid-popup` menu) |
| `ctrl-r` | Manual refresh |
| `q` / `esc` | Quit (collapse nav pane) |

### fzf configuration

| Option | Value | Reason |
|---|---|---|
| `--listen=<port>` | random 49200–49999 | Background ticker POSTs reload commands here |
| `--no-input` | — | Disable text search; all keys are bound actions |
| `--sync` | — | fzf waits for full stdin before firing `start:`, so `pos(N)` works correctly |
| `--accept-nth=2` | — | Tag field (field 2, tab-delimited) is the fzf output; display field (field 1) is shown |
| `--with-nth=1` | — | Only display field 1 |

### Startup sequence (per fzf loop iteration)

```
1. eval "$_lst" in shell → _initial_list (pre-populates fzf stdin, no blank flash)
2. printf list | fzf --listen --sync ...
     start: unbind(enter,n,r,d) + pos(_start_pos)
            ↑ unbind prevents stale tty newline (from the Enter that launched aid)
              from firing accept before the list loads
     load:  rebind(enter,n,r,d)
            ↑ fires after list is fully loaded; any buffered input has been consumed
3. fzf exits → read _key from _FZF_KEY_FILE, _tag from _output
4. dispatch on _key / _tag
5. continue (restart fzf) or break (q/esc)
```

### Key dispatch mechanism

`enter`, `n`, `r`, `d` all use `execute-silent(...)+accept`:
- `execute-silent` runs first, writes `FZF_POS` to `_FZF_POS_FILE` and the
  key name to `_FZF_KEY_FILE` — this is the only way to capture `FZF_POS`
  reliably (it is **not** available in the parent shell after fzf exits, and
  is **not** set in `execute-silent` for `--expect` keys).
- `+accept` causes fzf to exit and emit the focused item's tag (field 2 via
  `--accept-nth=2`) as `_output`.
- After fzf exits, the shell reads `_key` from `_FZF_KEY_FILE` and `_tag`
  from `_output`.

`esc`/`q` use `+abort` — fzf exits with rc=1, `|| true` suppresses the error,
`_output` and `_key` are both empty, the loop breaks.

### Cursor position preservation

`_start_pos` is set from `_FZF_POS_FILE` after each fzf exit and passed to
`pos(N)` in the next iteration's `start:` bind. Defaults to 1. Reset to 1
after `n` (new session) so the new entry is visible at the top.

### Auto-refresh ticker

A single background subshell fires every 5 seconds (with an immediate tick
at +2s after startup):

```bash
curl -sf -X POST http://127.0.0.1:<fzf_port> -d "transform:<reload_cmd> tick=N"
```

`transform:` causes fzf to run the command and interpret its stdout as a fzf
action string. The reload helper (`aid-sessions-reload`) generates
`reload-sync(cat <tmpfile>; rm -f <tmpfile>)+pos(<FZF_POS>)`.

The ticker is spawned once before the loop. Port is constant. `EXIT` trap
kills it on true exit.

### Conversation loading (`_load_conversation`)

```
_load_conversation <conv_id> <tmux_session>
  1. read AID_ORC_PORT from tmux session environment
  2. set-environment AID_ORC_ACTIVE_CONV=<conv_id>  (best-effort; failure logged, not fatal)
  3. curl POST /tui/select-session {"sessionID":"<conv_id>"}  → opencode switches TUI
  4. if current tmux session ≠ target: _switch_to_session target
```

### Rename (`_do_rename`)

```
_do_rename <tag>
  1. extract session name from tag (strips conv:/session:/dead: prefixes)
  2. display-popup -b double -c $AID_CALLER_CLIENT  → bash read -e -i <old_name>
  3. sanitise input (tr -cs '[:alnum:]-_.' '-')
  4. tmux rename-session old new
  5. _meta_write new_name; _meta_remove old_session
```

The popup uses `-b double` (border-lines) and `-c "$AID_CALLER_CLIENT"` (target
the correct terminal). The `-E` flag causes the popup to close when the shell
exits.

### Delete (`_do_delete`)

```
_do_delete <tag>
  conv:*     → aid-popup confirm → curl DELETE /session/<conv_id>
  session:*  → aid-popup confirm → curl GET /session → DELETE each id → (session stays)
  dead:*     → same as session:* but session is already gone
```

Sessions are never killed by delete — only their opencode conversation records
are removed via the HTTP API.

## `aid-sessions-list` — list generator

Generates the tab-delimited fzf input on stdout. Called twice per reload:
once inline before fzf opens (initial render), once inside `aid-sessions-reload`
(subsequent reloads).

### Output format

Each line: `DISPLAY_TEXT\tTAG`

| TAG | Meaning |
|---|---|
| `[session:aid@<name>]` | Live session header; Enter switches to it |
| `[dead:aid@<name>]` | Dead session (metadata present, tmux gone); Enter resurrects |
| `[conv:<session_id>:<tmux_session>]` | Opencode conversation row |
| `[noconv:<tmux_session>]` | Placeholder when opencode port not yet ready |
| `[sep]` | Blank separator between sessions (not selectable) |

Conversations are fetched from each session's opencode HTTP API
(`GET /session` on `AID_ORC_PORT`), filtered to `directory == repo_path`, and
sorted by `time.updated` descending.

## `aid-sessions-reload` — reload helper

Called via fzf `transform:` (from the ticker and `ctrl-r`). Reads `FZF_POS`
and `FZF_MATCH_COUNT` from its environment (fzf sets these for `transform:`
shells), generates the new list into a tempfile, and prints a fzf action string:

```
reload-sync(cat <tmpfile>; rm -f <tmpfile>)+pos(<FZF_POS>)
```

If the list is empty, emits `pos(<FZF_POS>)` only (suppresses reload to avoid
wiping a good list on a transient curl failure).

## `aid-sessions-action` — preview dispatcher

Called by fzf `--preview` for each focused item. Renders a rich info panel:

| TAG type | Preview content |
|---|---|
| `session:*` | Session name, live/dead status, pane count, repo, branch, git ahead/behind, `git status --short` |
| `dead:*` | Dead marker, repo, branch, last-active timestamp |
| `conv:*` | Conversation ID, session name, repo path |
| `noconv:*` | "No conversations yet" message |

## `aid-popup` — confirmation menu

Wraps `tmux display-menu` with a clean API:

```bash
answer=$(aid-popup -t "Delete?" -- "Yes:y" "No:n")
[[ "$answer" == "Yes" ]] && ...
```

Implementation detail: each menu item's command is a native
`tmux set-environment -g <unique_var> <label>` call. This runs synchronously
inside the tmux server when the item is selected, so the value is available
immediately after `display-menu` returns — no FIFO, no `run-shell`, no timing
race. A brief `sleep 0.15` after the menu closes lets tmux repaint the pane
before the caller restarts fzf on top of it.

## `aid-sessions-debug` — log viewer

Runs in the bottom pane when `AID_DEBUG=1`. Tails `AID_DEBUG_LOG` and renders
each event with colour-coded category labels and a `+Δms` delta column. Uses
`tail -F` piped into a `while read` loop (not `less +F`) so the pane scrolls
automatically without user interaction.

### Debug log format

```
<unix_ms> <CATEGORY> <message>
```

Categories and colours:

| Category | Colour | Meaning |
|---|---|---|
| `INIT` | bold blue | Startup events |
| `SPAWN` | bold yellow | Pane lifecycle steps from `orchestrator.sh` |
| `STDIN` | dim green | Pre-fzf list generation |
| `SYNC` | bold green | `reload-sync` dispatched (with label and `FZF_POS`) |
| `LOAD` | green | fzf list fully loaded |
| `POS` | yellow | Cursor position snapshot (`focus:` event) |
| `KEY` | bold magenta | Raw key event |
| `ACTN` | magenta | Higher-level action (new, rename, delete, conv load) |
| `CONV` | bold cyan | Conversation load request |
| `HTTP` | cyan | Ticker curl result |
| `TICK` | dim cyan | Background ticker heartbeat |
| `PRUNE` | yellow | Dead session cleanup |
| `RENAME` | magenta | Rename operation |
| `DEL` | bold red | Delete operation |
| `ERR` | bold red | Any error |

### Debug logger architecture

`aid-sessions` uses an independent drain subshell as its logger:

```
_dbg_init
  mkfifo /tmp/aid-dbg-XXXXXX  → _DBG_PIPE
  ( trap '' HUP; while read line; do >> AID_DEBUG_LOG; done ) < _DBG_PIPE &
  exec 9> _DBG_PIPE            ← write end held open by fd 9

_dbg CAT msg  → printf to fd 9  (non-blocking, daemon drains to file)
_dbg_close    → exec 9>&-        (EOF → daemon exits, removes pipe)
```

`trap '' HUP` makes the drain subshell survive `respawn-pane -k` (which sends
SIGHUP to the pane process group). The drain subshell is still a child of the
`aid-sessions` process, so it dies when the tmux session is killed
(SIGTERM/SIGKILL from `kill-session`).

## Environment variables

### Global (set by `orchestrator.sh` `_ensure_server`)

Same as standard aid mode — `AID_DIR`, `AID_DATA`, `XDG_*`, `OPENCODE_CONFIG_DIR`, etc.

### Session-local (set per `aid@<name>` session)

| Variable | Value | Purpose |
|---|---|---|
| `AID_ORC_PORT` | `4200 + cksum(name) % 1000` | Opencode HTTP API port; stable across restarts |
| `AID_ORC_NAME` | `<name>` | Session short name (without `aid@` prefix) |
| `AID_ORC_REPO` | `<repo_path>` | Absolute path to the session's repo |
| `AID_ORC_NAV_PANE` | `%<id>` | Pane ID of the navigator (left pane) |
| `AID_ORC_ORC_PANE` | `%<id>` | Pane ID of the opencode TUI (right pane) |
| `AID_ORC_ACTIVE_CONV` | opencode session ID | Currently loaded conversation (best-effort) |
| `AID_NVIM_SOCKET` | `/tmp/aid-nvim-<session>.sock` | Unused in orchestrator mode (no nvim pane) |
| `AID_DEBUG_LOG` | `<repo>/log-<timestamp>.txt` | Debug log path (only when `AID_DEBUG=1`) |

### Per-process

| Variable | Set by | Purpose |
|---|---|---|
| `AID_CALLER_CLIENT` | `aid-sessions` startup | tty of the terminal that launched aid; passed to `switch-client -c` and `display-popup -c` so popups and switches target the right screen |

## Key design decisions

- **`while true` loop instead of `exec` restart**: fzf is restarted inside the
  same process after every action. The background ticker is spawned once and
  keeps running. `EXIT` trap fires correctly on true quit. (Bug 2 fix — see
  `docs/BUGS.md`.)

- **Pre-populate fzf stdin before open**: `eval "$_lst"` in the shell before
  `fzf` starts; pipe output directly to fzf. No blank-flash on open; no
  `start:reload-sync` required. (Bug 5 fix — see `docs/BUGS.md`.)

- **`--sync` flag**: makes fzf wait for all stdin before firing `start:`, so
  `pos(N)` in the `start:` bind fires after the list is populated and lands on
  the correct row.

- **`unbind`/`rebind` on `start:`/`load:`**: guards against a stale `\n` from
  the Enter keypress that launched aid being delivered to fzf before the list
  is ready. Keys are unbound at `start:` and rebound at `load:` — the window
  is sub-millisecond.

- **`+accept` for `n`/`r`/`d` (not `--expect`)**: `FZF_POS` is available in
  `execute-silent` when fzf exits via `+accept`, but is **not** available in
  `execute-silent` for `--expect` keys (confirmed from debug logs). `+accept`
  also captures the focused item's tag as `_output`, which is needed for `r`
  and `d`.

- **Deterministic opencode port**: `4200 + cksum(name) % 1000` — no port
  scanning, no dynamic discovery, stable across session restart. The navigator
  knows the port before opencode has started.

- **`XDG_DATA_HOME` inline on `respawn-pane`**: prevents opencode from serving
  the user's global `~/.local/share/opencode` history. Must be inline because
  `respawn-pane` commands do not inherit global tmux env vars.

- **`@aid_mode=orchestrator` session tag**: set on each session at spawn time
  so `orchestrator.sh` can list and attach to orchestrator sessions without
  interfering with plain `aid@*` sessions that might share the same tmux server.

- **`aid-popup` via `set-environment` (not FIFO)**: the earlier implementation
  used `run-shell` + a named FIFO to pass the chosen menu item back to the
  caller. This caused a ~9-second stall. The fix: each menu item's command is
  a native `set-environment -g <var> <label>` call which runs synchronously
  inside the tmux server, so the value is readable immediately after
  `display-menu` returns.
