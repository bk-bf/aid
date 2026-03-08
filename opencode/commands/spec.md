---
description: Bootstrap or migrate documentation into the standard doc format
---

You are in **agentic planning mode**. Your first task is to determine which track applies, then execute it.

---

## Pre-flight check — run before anything else

Check whether $ARGUMENTS is empty or blank AND whether any files exist in the repo:

```bash
ls -A | head -1
```

If $ARGUMENTS is empty or contains only whitespace, **and** the above command returns nothing (completely empty repo with no files at all): abort immediately.

```
ABORTED: nothing to work with.

/spec requires either a project description or existing files to read.
Running on a blank repo with no input would produce empty or fabricated
documentation — exactly what this command exists to prevent.

To run /spec successfully, provide:

  1. A project description in $ARGUMENTS covering:
       - Project name (a real name, not "my app" or "tool")
       - The specific problem it solves (the pain, not just what it does)
       - Who exactly uses it (specific enough to reject a feature on their behalf)
       - At least one thing it does not do (scope boundary)
       - At least one technical choice with a reason (language, architecture,
         approach, integration strategy)

  2. Or: existing files in the repo for /spec to read and migrate.

  Both together is ideal. Neither is not enough.
```

Stop. Do not read further. Do not run track detection.

If $ARGUMENTS is non-empty, or if the repo contains any files, proceed to track detection.

---

## Track detection — run this first

Check whether a `docs/` directory exists in the repo root and contains at least one `.md` file:

```bash
ls docs/*.md 2>/dev/null | head -1
```

- **If the command returns nothing** (no `docs/` dir or no `.md` files inside it): this is a **fresh repo**. Follow **Track A — Fresh repo**.
- **If the command returns one or more files**: existing documentation is present. Follow **Track B — Migrate existing docs**.

---

# Track A — Fresh repo

The user has provided a project idea, sketch, or description in $ARGUMENTS. Your job is to understand it deeply and scaffold the minimum viable documentation set. Do not generate placeholder content — generate only what you can genuinely derive from what the user has told you.

---

## Step 1a — Input audit (hard gate, runs before anything else)

Check $ARGUMENTS against the five required fields below. Every field must pass. If any field fails, abort immediately — print the abort message, write no files, and stop.

### Required fields and pass/fail criteria

| Field | Fails if... |
|---|---|
| **Project name** | Absent, or a generic placeholder ("my app", "project", "tool", "app") |
| **Problem statement** | Absent, or only describes what it does without stating the specific gap, pain, or friction it solves |
| **Target user** | Absent, or so generic it cannot filter a feature decision ("developers", "users", "anyone", "people") |
| **Scope boundary** | No statement — explicit or clearly implied — of what the project does *not* do, what belongs upstream, or what is out of scope |
| **Architectural decision** | Nothing in $ARGUMENTS implies *how* the project works — no tech stack, no structural approach, no constraint that would produce a non-obvious ADR |

Do not infer a field as present because it could theoretically be derived. The field must be stated or unambiguously implied. The purpose of this gate is to ensure the user has thought through these dimensions before scaffolding begins — if the model fills them in, the gate has no value.

### Abort message

Print only the failing fields. Do not list passing fields.

```
ABORTED: $ARGUMENTS does not provide enough concrete information for a
high-quality documentation scaffold. Writing docs from vague input produces
generic filler that is harder to fix later than to provide upfront.

Missing or insufficient fields:

  [ ] <field name> — <one sentence: specifically why it failed>
  [ ] <field name> — <one sentence: specifically why it failed>

Re-run /spec with a description that addresses the gaps above.
What to include for each failing field:

  Project name:         a real name, not a category label
  Problem statement:    the specific pain — not "it does X" but "currently X
                        requires Y which causes Z"
  Target user:          specific enough to reject a feature on their behalf
                        (e.g. "a backend engineer who has never configured
                        Neovim" not "developers")
  Scope boundary:       one thing it explicitly does not do, or one layer it
                        deliberately leaves to upstream tools
  Architectural decision: one technical choice with a reason — language,
                        runtime, architecture pattern, integration approach

No files have been written.
```

If all five fields pass, proceed to Step 1b.

---

## Step 1b — Extract

Read $ARGUMENTS and extract:

- **What the project does** (one sentence)
- **Who it is for** (target user, verbatim or minimally paraphrased from $ARGUMENTS)
- **What problem it solves** (the stated gap — do not expand beyond what was said)
- **What it is not** (scope boundaries stated or unambiguously implied)
- **Key components or modules** identifiable from the description
- **Key decisions already implied** by the stated approach

Mark anything you are inferring rather than reading directly from $ARGUMENTS. You will label these in the output files using `<!-- inferred: <reason> -->` — see Step 4 rules.

---

## Step 2 — Determine the doc set

Every project gets these files, no exceptions:

```
README.md             (repo root)
docs/ARCHITECTURE.md
docs/BUGS.md
docs/DECISIONS.md
docs/PHILOSOPHY.md
docs/ROADMAP.md
docs/archive/         (empty dir — create a .gitkeep)
docs/bugs/            (empty dir — create a .gitkeep)
```

Then evaluate whether the project warrants any of the following **optional** files based on what you know about the project. Add only what will be non-trivially populated on day one:

| File | Add if... |
|---|---|
| `docs/API.md` | project exposes a public interface (CLI flags, HTTP endpoints, Lua/JS API, etc.) |
| `docs/CONFIGURATION.md` | project has user-facing configuration with more than ~5 keys |
| `docs/CONTRIBUTING.md` | project is or will be open-source and has non-obvious contribution workflow |
| `docs/DEPLOYMENT.md` | project has a deploy step that isn't just `git push` |
| `docs/SECURITY.md` | project handles auth, secrets, or user data |
| `docs/TESTING.md` | project has a test strategy that requires documentation to follow |

Do not add optional files just because they exist as a category. If you cannot write at least 5 non-trivial lines for an optional file right now, skip it.

---

## Step 3 — Write the LOC cap comment

Count source lines once there is source to count. On a fresh repo with no code yet, use a provisional cap based on the expected project scale:

| Expected scale | Provisional cap per doc |
|---|---|
| Small (< 1 KLOC) | 80 lines |
| Medium (1–3 KLOC) | 150 lines |
| Large (> 3 KLOC) | 200 lines |

Add to each doc:

```
<!-- LOC cap: <N> (provisional — recompute with /udoc once source exists) -->
```

---

## Step 4 — Write each file

### Rules for all files

- Write only what you know. Do not invent architecture, decisions, or roadmap items the user has not stated or unambiguously implied.
- Every section must earn its place: if you cannot write it concisely and accurately from what you know, leave the section out entirely — do not add a heading with a TODO placeholder.
- Prefer tables and code blocks over prose paragraphs for structural information.
- Do not pad. The LOC cap is a ceiling, not a target. A 20-line ARCHITECTURE.md is correct if the project is simple.
- Do not use emoji.

#### Inference labelling

Any content not directly stated in $ARGUMENTS but derived from context, implication, or general knowledge must be annotated inline — immediately after the relevant sentence or block — with:

```
<!-- inferred: <one-line reason why this was inferred, not stated> -->
```

Examples of correct usage:

```markdown
The sidebar is a separate nvim process so it never closes on focus loss.
<!-- inferred: $ARGUMENTS described a persistent sidebar but did not specify the implementation -->

**Target user**: a backend engineer moving from VS Code who has not configured Neovim before.
<!-- inferred: $ARGUMENTS said "VS Code users" without specifying experience level -->
```

Rules for inference annotations:

- **Inline, not batched** — place the annotation immediately after the content it applies to, not at the end of the section.
- **Do not self-evaluate** — do not assess whether the inferred content is correct, likely, or reasonable. Write it, label it, stop. Correctness is the user's call.
- **No Category 2 quality checks** — do not rate, score, or judge the semantic quality of any generated content. Your job is structure and labelling; quality judgement is the user's responsibility and cannot be reliably self-assessed.
- **Absence is better than unlabelled inference** — if you cannot label a piece of inferred content because it is too entangled with stated content to separate, omit the section rather than leaving silent inference in place.

### README.md (repo root)

```
# <project name>

<one-sentence description>

## What it does

<2–4 sentences: the problem, the solution, the target user>

## Install

<install command(s) if you know them; otherwise omit this section entirely>

## Usage

<minimal usage example if you can derive it; otherwise omit>

## Development

<how to run/test locally if you know it; otherwise omit>
```

Do not add badges, shields, or "Contributing" / "License" sections unless the user mentioned them.

### docs/PHILOSOPHY.md

Write the project's **origin**, **what it is** (and what it explicitly is not), and the **constraint** that keeps it from bloating. This is not a marketing document. It should be specific enough that a stranger reading it could reject a feature proposal on its basis.

Structure:
```
# Philosophy

## Origin
<why this project exists — the specific gap it fills>

## What <project> is
<what it does, what makes it distinct, what it is not>

## The <core constraint rule>
<one concrete question or rule that defines scope — named specifically for this project>

## The target user
<concrete description — not a persona template>

## What keeps it from bloating
<the actual constraint, not platitudes>
```

### docs/ARCHITECTURE.md

Document only what exists or is clearly decided. For a fresh project, this may be very short.

Required sections (if applicable):
- **Overview** — what the system does, its components, and how they relate
- **Boot / startup sequence** — if there is a startup procedure
- **Key modules / components** — what each one owns
- **Data flow** — how data moves through the system (if non-trivial)
- **Environment / configuration** — env vars, config files, and their purpose

Use diagrams only if the relationship is genuinely hard to express in prose or a table.

### docs/DECISIONS.md

```
# Decisions

Architecture decision records — why things are the way they are.

ADR statuses:
- **Under consideration** — open question, no decision made, may block other work
- **Made** — decided and implemented
- **Superseded** — previously made, overridden by a later ADR (kept for historical record)

---

## Under Consideration

---

## Made

---

## Superseded

```

Write one ADR for each key decision already implied by the project description. Place it under the appropriate section header. ADR format:

```
### ADR-NNN: <short title>

**Date**: <YYYY-MM>
**Status**: Made | Under consideration | Superseded by ADR-NNN
**Decision**: <what was decided, in one sentence> (omit for Under consideration)
**Reason**: <why — the constraint, trade-off, or evidence that drove it> (omit for Under consideration)
**Alternatives rejected**: <what else was considered and why it lost> (omit if none)
**Supersedes**: <ADR-NNN> (omit if none)
```

For **Under consideration** ADRs, replace `**Decision**` and `**Reason**` with:
```
**The question**: <what needs to be decided>
**Options**: <the realistic choices and their trade-offs>
**Blocking**: <T-NNN list of roadmap items that cannot proceed until this is decided>
```

Only write ADRs for real decisions with real reasons. Do not write ADRs for obvious defaults ("we use git for version control").

### docs/ROADMAP.md

```
# Roadmap

## Phase 1 — <label>

- [ ] **T-001**: <task>

## Done

(nothing yet)
```

Derive phases and tasks from the user's description. Label phases by what they accomplish (e.g. "Harden", "Differentiate", "Publicize"), not by version numbers. Open tasks carry a stable `T-NNN` prefix assigned sequentially across all phases; numbers are never reused. Only add tasks you can genuinely derive — do not pad with generic items.

### docs/BUGS.md

```
# Bugs

## Open

*(none yet)*

<!-- template:
### BUG-N: title
**Status**: open | investigating | blocked
**Repro**: steps
**Notes**:
-->

## Closed

*(none yet)*
```

### docs/archive/.gitkeep and docs/bugs/.gitkeep

Empty files. Create them so the directories are tracked by git.

---

## Step 5 — Output summary

After writing all files, print:

```
Track: fresh repo
Created:
  README.md
  docs/PHILOSOPHY.md
  docs/ARCHITECTURE.md
  docs/DECISIONS.md  (<N> ADRs)
  docs/ROADMAP.md    (<N> tasks across <N> phases)
  docs/BUGS.md
  docs/archive/.gitkeep
  docs/bugs/.gitkeep
  [any optional files added]

Skipped optional files: [list with one-line reason each]

Inferred content: <N> annotations across <N> files.
  Search for `<!-- inferred:` to review each one.
  Replace with confirmed content or remove the annotation once verified.
  Unresolved <!-- inferred: --> markers will be flagged as drift by /udoc
  on subsequent runs — do not leave them in place indefinitely.

Next step: resolve inferred annotations, then run /udoc as the codebase grows.
```

---

# Track B — Migrate existing docs

Existing documentation is present. Before doing anything else, measure how large the existing docs are and decide whether a one-shot migration is safe.

---

## Step 0 — LOC gate (run before anything else)

Count the total lines across all existing documentation files:

```bash
find . -name "*.md" | grep -v node_modules | grep -v .git | xargs wc -l 2>/dev/null | tail -1
```

Apply this threshold table:

| Existing docs LOC | Action |
|---|---|
| < 300 | Proceed — one-shot migration is safe. Continue to Step 1. |
| 300 – 600 | Proceed with caution — flag this in the output summary and be extra careful not to lose content. Continue to Step 1. |
| > 600 | **Abort. Do not proceed.** Print the warning below and stop. |

### Abort message (> 600 LOC)

```
ABORTED: doc set is too large for a safe one-shot migration.

Existing docs: <N> lines across <list of files>

A single-pass rewrite of a doc set this size carries a real risk of
information loss, subtle rewording that changes meaning, and structural
decisions that seem locally correct but break cross-references across
files. The quality of a large LLM migration declines significantly as
context grows.

Recommended approach — phased rewrite:

  Phase 1 (one session per file):
    Run /spec on a single file at a time by passing the target filename
    in $ARGUMENTS, e.g.: /spec migrate docs/ARCHITECTURE.md
    Review and commit each file before moving to the next.

  Phase 2:
    Once all files are migrated individually, run /udoc to sync the
    full set against the current codebase and catch any remaining drift.

Files to migrate (suggested order — largest first):
<list files sorted by line count, descending>

No files have been modified.
```

If the abort fires, stop here. Do not read further, do not write any files.

---

## Step 1 — Inventory what exists

Find all documentation files in the repo:

```bash
find . -name "*.md" | grep -v node_modules | grep -v .git | sort
```

Read every file returned. Also read the source files to understand the project — check for `package.json`, `Makefile`, `*.sh`, `*.py`, `*.ts`, `*.go`, `*.lua`, `*.rs`, or whatever the primary source language appears to be.

Produce a mental inventory:

- What files exist and what do they cover?
- What content maps cleanly to a standard file (ARCHITECTURE, DECISIONS, etc.)?
- What content doesn't fit any standard file? (Flag it — do not discard.)
- What standard files are missing entirely?
- What files exist outside `docs/` that should be absorbed (e.g. a root-level `CHANGELOG.md`, `CONTRIBUTING.md`, `TODO.md`, scattered notes)?

---

## Step 2 — Determine the target doc set

Apply the same logic as Track A Step 2: every project gets the 8 core files; optional files are added only if they'd be non-trivially populated. But here, also consider:

- If an existing file maps cleanly to an optional file (e.g. an existing `API.md` → `docs/API.md`), include it even if you would not have created it from scratch.
- If a file exists outside `docs/` and its content belongs in a standard file, absorb it; do not keep the original location unless it serves a purpose there (e.g. `README.md` stays at root).

---

## Step 3 — Compute LOC cap

Count source lines:

```bash
find . -type f \( -name "*.sh" -o -name "*.lua" -o -name "*.py" -o -name "*.ts" -o -name "*.js" -o -name "*.go" -o -name "*.rs" \) \
  | grep -v node_modules | grep -v .git | xargs wc -l 2>/dev/null | tail -1
```

Apply the ratio table:

| Total source LOC | Max doc LOC |
|---|---|
| < 1000 | source × 0.20 |
| 1000 – 3000 | source × 0.14 |
| > 3000 | source × 0.10 |

If there is no source yet, use the provisional caps from Track A Step 3.

Add to each doc:

```
<!-- LOC cap: <N> (source: <total>, ratio: <ratio>, updated: <YYYY-MM>) -->
```

---

## Step 4 — Identify monolithic files and plan splits

Before writing anything, check each existing doc against the LOC cap computed in Step 3. A file is **monolithic** if it contains content that would naturally live in more than one standard file, or if it is over the LOC cap and the excess is substantive rather than just padding.

### Detection rules

For each existing doc, ask:

1. **Over cap?** — is it longer than the computed LOC cap?
2. **Mixed concerns?** — does it contain content that belongs in two or more standard files? (e.g. a single `NOTES.md` that has architecture descriptions, decision rationale, and a bug list all in one place)
3. **Index-worthy section?** — does any single section within the file exceed ~80 lines and cover a discrete, self-contained topic (a specific subsystem, a complex ADR, a detailed bug)?

If none of these are true, the file is fine as-is — migrate it whole in Step 5.

### Naming conventions for split files

When a section is extracted from a parent doc into its own file, follow these conventions exactly:

| Parent doc | Extracted content | Target file |
|---|---|---|
| `docs/DECISIONS.md` | A single ADR that exceeds ~60 lines | `docs/decisions/ADR-NNN.md` |
| `docs/BUGS.md` | A detailed open or closed bug | `docs/bugs/BUG-NNN.md` |
| `docs/ARCHITECTURE.md` | A major subsystem with its own data flow, API, or lifecycle | `docs/architecture/<subsystem>.md` |
| `docs/ROADMAP.md` | A completed phase or large done-block being archived | `docs/archive/ROADMAP-<YYYY-MM>.md` |
| Any doc | Archive-destined content (old ADRs, closed bugs) | `docs/archive/<TYPE>-<YYYY-MM>.md` |

If a directory implied by the target path does not exist, create it with a `.gitkeep`.

### Backlink format

Every split file must contain a backlink in its header:

```markdown
<!-- parent: docs/<PARENT>.md -->
```

And the parent file must contain a forward-link at the point where the extracted content was:

```markdown
**<Title>** — see [decisions/ADR-NNN.md](decisions/ADR-NNN.md)
```

or for bugs:

```markdown
### BUG-NNN: <title>

**Status**: open — see [bugs/BUG-NNN.md](bugs/BUG-NNN.md)
```

Never leave a section in the parent and also in the child — extract fully, leave only the one-line summary + link in the parent.

### Split decision record

Before proceeding to Step 5, list every split you intend to make:

```
Planned splits:
  docs/ARCHITECTURE.md § "<section heading>" → docs/architecture/<subsystem>.md
  docs/DECISIONS.md § "ADR-NNN" → docs/decisions/ADR-NNN.md
  [etc.]

Files migrated whole (no split needed):
  [list]
```

Do not begin writing files until this plan is complete. If no splits are needed, note that explicitly and proceed.

---

## Step 5 — Migrate content into each file

### Rules for migration

- **Preserve all accurate content** — if the existing docs describe something correctly, keep the substance verbatim or tightened; do not rewrite for the sake of rewriting.
- **Reformat, don't reinvent** — restructure into the standard headings and formats, but do not change facts.
- **Fill genuine gaps** — if a standard section is missing and you can derive its content from source files, write it. If you cannot, omit the heading.
- **Do not discard unclassified content** — if existing content doesn't fit a standard file, place it in the most appropriate file with a note, or create a justified optional file. Flag it in the output summary.
- **Resolve duplication** — if the same information appears in multiple existing files, keep the most accurate/complete version in the canonical location and remove the others.
- **Apply standard formats**: ADR format for decisions, `BUG-N` format for bugs, `- [x] YYYY-MM: ...` for done roadmap items.
- Do not use emoji.

### Handling each standard file

**README.md**: If one already exists, reformat to the standard structure. Preserve install/usage content verbatim if accurate. Remove badges unless the user's existing README used them intentionally.

**docs/PHILOSOPHY.md**: If one exists, check it covers origin, what the project is/isn't, scope rule, target user, and anti-bloat constraint. Restructure to the standard headings. If it doesn't exist, derive from the project's existing description and any stated goals.

**docs/ARCHITECTURE.md**: Pull together all technical descriptions scattered across existing docs. Restructure under the standard sections (Overview, Boot sequence, Key modules, Data flow, Environment/config). Add LOC cap comment.

**docs/DECISIONS.md**: Find all decision rationale in existing docs — could be inline comments, a CHANGELOG, a RATIONALE file, scattered notes, or implicit in commit messages. Convert to ADR format. Renumber sequentially (ADR-001, ADR-002, ...). Place each ADR under the correct section header (`## Under Consideration`, `## Made`, or `## Superseded`). The `**Status**` field is required on every ADR. Only record decisions with genuine reasons; skip defaults.

**docs/ROADMAP.md**: Find all TODO items, planned features, and completed items. Organise into labelled phases by theme, not version. Move completed items to `## Done` with `- [x] <YYYY-MM>: ...` format. Open tasks must carry a stable task number: `- [ ] **T-NNN**: <description>`. Numbers are assigned sequentially across all phases and never reused. Assign the next unused number when adding a new task; preserve existing numbers when migrating tasks. If dates are unknown, use the current month.

**docs/BUGS.md**: Find all bug reports, issue lists, known problems. Convert to `BUG-N` format. Issues that are already fixed → `## Closed`. Issues still open → `## Open`. Serious/detailed bugs → create a stub file in `docs/bugs/BUG-N.md` and link from the index.

**docs/archive/** and **docs/bugs/**: Create `.gitkeep` if the dirs don't exist. Move detailed bug files into `docs/bugs/` if found outside it.

---

## Step 6 — Handle files that don't belong

For each existing doc that has been fully absorbed into the standard set:
- If it was at root level (e.g. `TODO.md`, `NOTES.md`): delete it.
- If it was in `docs/` under a non-standard name (e.g. `docs/notes.md`): delete it after confirming its content was captured.
- If it contained content that was partially absorbed and partially irrelevant: delete after confirming no information was lost.

Do not delete files without being certain their content is captured elsewhere. If uncertain, preserve the file and flag it in the output summary.

---

## Step 7 — Output summary

After completing migration, print:

```
Track: existing docs migration

Read:
  [list of existing files read]

Splits performed:
  [parent § section → child file, or "none"]

Produced:
  README.md                         [created | rewritten | unchanged]
  docs/PHILOSOPHY.md                [created | rewritten | unchanged]
  docs/ARCHITECTURE.md              [created | rewritten | unchanged]
  docs/DECISIONS.md  (<N> ADRs)     [created | rewritten | unchanged]
  docs/ROADMAP.md    (<N> tasks)    [created | rewritten | unchanged]
  docs/BUGS.md       (<N> open)     [created | rewritten | unchanged]
  docs/archive/.gitkeep             [created | already existed]
  docs/bugs/.gitkeep                [created | already existed]
  [any split child files]
  [any optional files]

Deleted:
  [files removed because content was fully absorbed]

Flagged (needs human review):
  [content that didn't fit cleanly — describe what it is and where it ended up]

LOC cap: <cap> per doc (source: <total LOC>, ratio: <ratio>)

Next step: run /udoc as the codebase grows to keep docs in sync.
```
