---
description: Update documentation to reflect current codebase state, archive finished tasks, and prune stale info
---

Update the documentation file(s) specified in $ARGUMENTS (or all docs under `aid/docs/` if none given) to accurately reflect the current codebase. Follow the procedure below exactly.

---

## Step 1 — Analyse the codebase and set the LOC cap

Count the lines of every source file that the target doc covers:

```bash
wc -l aid/main/aid.sh aid/main/nvim/init.lua aid/main/nvim/lua/*.lua \
       aid/main/nvim-treemux/treemux_init.lua aid/main/ensure_treemux.sh \
       aid/main/install.sh aid/main/tmux.conf
```

Compute the LOC cap for the document as follows:

| Total source LOC | Max doc LOC |
|---|---|
| < 1000 | source × 0.20 |
| 1000 – 3000 | source × 0.14 |
| > 3000 | source × 0.10 |

If the current document is already under cap, keep it that way. If it is over cap, prune it (see Step 4). Record the computed cap in a comment at the top of the document:

```
<!-- LOC cap: <N> (source: <total source LOC>, ratio: <ratio>, updated: <YYYY-MM> -->
```

---

## Step 2 — Read everything, identify drift

Read the target documentation file. Then read each source file it references or describes. Produce a mental diff of:

- **Stale**: descriptions of behaviour that has changed, old file paths, wrong line numbers, removed features still documented
- **Missing**: new features, new modules, new env vars, new commands not yet documented
- **Inaccurate**: diagrams, call sequences, tables that no longer match the code

Do not begin editing until you have read all relevant source files.

---

## Step 3 — Update the documentation

Rewrite only what has drifted. Do not change structure or tone unless it is genuinely wrong. Preserve all correct content verbatim.

Rules:
- Keep every section **concise but not oversimplified**: a reader should be able to understand *why* as well as *what* without opening the source file. Trim prose that restates the obvious; keep prose that explains non-obvious design constraints.
- Do not pad to fill the LOC cap — the cap is a ceiling, not a target.
- Prefer tables and code blocks over prose paragraphs for structural information (sequences, env vars, keymaps).
- If a section has grown past its natural size, tighten it rather than splitting it into new sections.
- **ROADMAP.md task numbers**: open tasks carry a stable `T-NNN` prefix — `- [ ] **T-NNN**: <description>`. Numbers are assigned sequentially across all phases and never reused. Preserve existing `T-NNN` when updating a task. Assign the next unused number when adding a new task. Completed items moved to `## Done` drop the number and use `- [x] **YYYY-MM**: <description>` instead.

---

## Step 4 — Extract finished tasks → archive

### ROADMAP.md

Move every item in the `## Done` section whose date is **more than 3 months ago** from `ROADMAP.md` into the archive:

1. Create the archive file if it does not exist: `aid/docs/archive/ROADMAP-<YYYY-MM>.md`
   - Header: `# Roadmap archive — items completed before <YYYY-MM>`
2. Append the extracted items verbatim to the archive file.
3. Remove them from the `## Done` section of `ROADMAP.md`.
4. Leave items completed within the last 3 months in `## Done` — they are still relevant context for current work.

### BUGS.md

Move every item in the `## Closed` section that is **referenced nowhere in any currently open roadmap item, ADR, or open bug** into `aid/docs/archive/BUGS-<YYYY-MM>.md` following the same pattern. Closed bugs still cross-referenced by open work stay in `BUGS.md`.

---

## Step 5 — Prune outdated info and verify cross-links

After archiving, scan the documentation for:

- References to archived items (now gone from main docs) — remove or replace with a note: `(see archive)`
- ADRs in `DECISIONS.md` that are marked `**Status**: Superseded` and are also referenced nowhere else — move them to `aid/docs/archive/DECISIONS-<YYYY-MM>.md` and leave a one-line stub under `## Superseded` linking to the archive file.
- Any ADR whose status has changed (e.g. an **Under consideration** ADR that has since been decided) — update the `**Status**` field, move it to the correct section (`## Made` or `## Superseded`), and add the `**Decision**` and `**Reason**` fields if they were absent.
- Any wording that describes a plan, intention, or TODO that has since been implemented — replace with the factual description of the implemented behaviour.

### Bug ↔ Roadmap cross-link audit

Check that every open bug which has a roadmap entry is correctly cross-linked in both directions:

1. **BUGS.md / bugs/*.md → ROADMAP.md**: each open bug that is tracked as a roadmap item must reference its `T-NNN` number. Add a `**Roadmap**: [T-NNN](../ROADMAP.md)` line to the bug entry in `BUGS.md` (inline, next to the status line) if one is missing.

2. **ROADMAP.md → bugs/*.md**: each roadmap task that was derived from a bug must link to the bug detail file. The format is already established: `(see [bugs/BUG-NNN.md](bugs/BUG-NNN.md))` at the end of the task description. Add this link if it is absent.

3. **New open bugs without a roadmap entry**: for each open bug in `BUGS.md` that has no corresponding `T-NNN` in `ROADMAP.md`, decide whether it warrants tracking. Bugs that affect all users or have a clear proposed fix generally do. Add a roadmap task in the appropriate phase and apply the cross-links above. Assign the next unused `T-NNN`.

Do not create roadmap entries for closed bugs unless their "final solution" section describes an architectural change that is still unimplemented.

---

## Step 6 — Resolve inferred annotations

Scan all target docs for `<!-- inferred:` comments left by `/spec`:

```bash
grep -rn "<!-- inferred:" docs/
```

For each one found:

1. Read the annotated content and the source file(s) that now exist to verify or refute it.
2. **If the source confirms it**: remove the `<!-- inferred: ... -->` annotation, leaving the content as plain text.
3. **If the source contradicts it**: correct the content to match the source, then remove the annotation.
4. **If no source exists yet to verify it**: leave the annotation in place — do not guess. Report it in the output summary as unresolved.

Do not remove an annotation without either confirming or correcting the content it marks. Removing the annotation without checking is worse than leaving it.

---

## Output

After completing all steps, print a short summary:

```
Updated: <list of files changed>
Archived: <list of archive files written or appended to, or "none">
LOC cap: <cap> (was: <old doc LOC> → now: <new doc LOC>)
Pruned: <count> stale items removed
Inferred resolved: <count> annotations confirmed and removed
Inferred corrected: <count> annotations where content was wrong and fixed
Inferred unresolved: <count> annotations with no source to verify against
  [list each unresolved annotation: file:line — reason]
```
