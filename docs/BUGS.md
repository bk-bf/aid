# Bugs — investigation notes

This file documents both **fixed bugs** (with root cause and fix summary) and
**non-actionable issues** (confirmed expected behaviour, deliberately left
unfixed).

---

## Bug 5 — Stale session list on launch (opencode HTTP port not ready)

**Status:** Fixed in commit `18e9c41`.

**Symptom:** On launch, `aid-sessions` shows each live session with
`(no conversations yet)` instead of real conversation titles.  The correct
list appears a few seconds later without user interaction.  Observed with a
delay of ~7 s in early builds, reduced to ~2 s after the fix.

**Root cause confirmed from logs `log-20260311-182924.txt` and
`log-20260311-183327.txt`:**

`aid-sessions-list` queries each live session's opencode HTTP API
(`GET /session` on `AID_ORC_PORT`) to fetch conversation titles.  When
`aid-sessions` starts, opencode has not yet bound its HTTP port — the curl
call times out or fails, `_opencode_conversations()` returns nothing, and
the list emits a `noconv:` placeholder instead.

Timeline (from log `log-20260311-183327.txt`, pre-fix):
```
+0ms    STDIN  running list command            ← list eval starts
+129ms  STDIN  list ready: 6 lines             ← curl timed out, noconv: emitted
+159ms  LOAD   FZF_MATCH_COUNT=7               ← 7 lines (headers + noconv placeholders)
+7013ms HTTP   ticker POST ok (tick=1)         ← first ticker fires at +2s+5s=7s
+7017ms SYNC   match_count=7 lines=49          ← real list has 49 lines
+7283ms LOAD   FZF_MATCH_COUNT=49              ← conversations finally visible
```

The user saw the stale list for the entire 7-second window.

**Why the initial blank-flash attempt (`start:reload-sync`) didn't help:**

An earlier fix attempt changed `start:reload(...)` to `start:reload-sync(...)`,
but fzf always fires `start:` events asynchronously after rendering stdin.
Since stdin was `printf ''` (empty), the user still saw an empty list for
~168ms regardless.  See log `log-20260311-182924.txt`:
```
+4ms   LOAD   FZF_MATCH_COUNT=0   ← fzf rendered empty stdin immediately
+168ms LOAD   FZF_MATCH_COUNT=7   ← reload-sync finished, real(ish) list appeared
```
This was a separate blank-flash bug, also fixed (see below).

**Fix (two parts):**

1. **Eliminate blank-flash on open** (`commit 14dac07`): Run `eval "$_lst"`
   in the shell *before* opening fzf and pipe the output directly to fzf
   stdin.  fzf opens with real data on the first frame.  The `start:` bind
   was replaced with `start:pos(N)` (cursor positioning only, no reload).

2. **Reduce stale-list window from 7s to ~2s** (`commit 18e9c41`):
   Restructure the ticker loop to fire an immediate `tick=0` right after the
   2-second fzf warmup sleep, before entering the regular 5-second cycle.

   Before:  `sleep 2` → `while true; do sleep 5; tick; done`  → first tick at +7s
   After:   `sleep 2` → `tick=0; while true; do tick; sleep 5; done` → first tick at +2s

   The 2-second warmup is kept so fzf has time to bind to its `--listen` port
   before the first curl arrives.

**Confirmed fixed in log `log-20260311-183528.txt`:**
```
+0ms    STDIN  running list command
+129ms  STDIN  list ready: 6 lines             ← noconv: present (opencode not ready)
+159ms  LOAD   FZF_MATCH_COUNT=7               ← single LOAD, no blank-flash
+2013ms HTTP   ticker POST ok (tick=0)         ← immediate reload at +2s
+2018ms SYNC   match_count=7 lines=49
+2284ms LOAD   FZF_MATCH_COUNT=49              ← conversations visible at +2s
```

**Residual limitation:** The first ~2 seconds after launch still show
`(no conversations yet)` if opencode's HTTP port hasn't bound yet.  This is
acceptable — 2s is the minimum safe warmup for the fzf `--listen` port.  A
`STDIN` log entry `list has noconv: entries — opencode port(s) not ready yet`
is emitted when this condition is detected, making it visible in debug logs.

A future improvement could poll the opencode port directly and reload as soon
as it responds, rather than relying on a fixed 2-second delay.

---

## Bug 2 — Zombie ticker processes accumulating after each action

**Status:** Fixed in commit `f3c7063`.

**Symptom:** After each rename/delete/enter action, a new background `curl`
ticker process was spawned and the old one was never killed.  After 4 actions:
4 independent ticker loops all hammering dead ports every 5s.

**Root cause:** Every action used `exec "$AID_DIR/lib/sessions/aid-sessions"`
as a tail-call to restart the navigator.  `exec` replaces the shell process
without triggering the `EXIT` trap, so `$_ticker_pid` was never killed.  Each
invocation spawned a fresh ticker against a new `--listen` port while all
previous tickers kept running, sending curl requests to ports that no longer
existed.  Confirmed from log `log-20260311-181746.txt`.

**Fix:** Replace all `exec` tail-calls with a `while true` main loop.  The
ticker is spawned once before the loop, the port is constant for the lifetime
of the process, and the `EXIT` trap fires correctly on true exit.

---

# Known non-actionable issues (expected fzf behaviour)

These are items that were investigated, confirmed to be correct fzf behaviour,
and deliberately left unfixed.

---

## Bug 1 — Duplicate POS events when holding an arrow key

**Symptom:** The debug log shows two entries for each held-key move — a `KEY`
entry followed immediately by a `POS` entry with the same position, then the
pattern repeats.

**Root cause:** The `up` / `down` binds are written as:

```
up:execute-silent(...)+up
```

`execute-silent` fires *before* the cursor moves, so `FZF_POS` in that shell
reflects the pre-move row.  The cursor then moves, which triggers the `focus:`
event, logging the post-move row.  When a key is held down, fzf batches the
KEY events but fires a `focus:` event for every individual move, producing
`KEY`/`POS` pairs at high frequency.

**Why not fixed:** The log pairs are not a bug — they faithfully record the
pre- and post-move state.  Removing the `execute-silent` wrapper would lose the
KEY logging entirely.  The pattern is cosmetically noisy but operationally
correct.

---

## Bug 3 — No POS event at list boundaries

**Symptom:** Pressing `up` when the cursor is on row 1, or `down` when it is on
the last row, logs a `KEY` entry but no subsequent `POS` entry.

**Root cause:** fzf does not move the cursor when it is already at the boundary,
so no `focus:` event fires.  The `KEY` log is accurate (the key was pressed);
there is simply no position change to report.

**Why not fixed:** This is correct fzf behaviour.  The absence of a `POS` entry
at a boundary is expected and harmless.
