# Known non-actionable bugs (expected fzf behaviour)

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
