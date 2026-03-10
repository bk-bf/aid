# `aid --fleet` — Feature Breakdown \& Analysis Report


---

## Executive Summary

`aid --fleet` is a tmux-native multi-agent orchestration feature for the `aid` CLI that enables cooperative parallel development — multiple opencode instances working simultaneously on decomposed sub-tasks of a single codebase goal, with full terminal visibility, git worktree isolation, and a clean three-command user surface.

***

## The Three-Command Surface

The entire fleet system is intentionally minimal. All LLM reasoning is delegated to opencode; `aid` itself is pure infrastructure glue.


| Command | Type | Responsibility |
| :-- | :-- | :-- |
| `/fleet-plan "task"` | opencode command | Analyzes codebase + prompt, writes `tasks.md` |
| `aid --fleet` | aid CLI | Parses `tasks.md`, provisions worktrees, spawns layout |
| `/fleet-merge` | opencode command | Reads all worktree diffs, merges into main under supervision |

`tasks.md` is the contract between all three — a plain text file the user always controls, can edit by hand, version-control, and reuse without touching either tool.

***

## Workflow Pipeline

The workflow has a natural human checkpoint after `/fleet-plan` — the user reviews and edits `tasks.md` before any agents are spawned. Nothing executes until the user explicitly runs `aid --fleet`, meaning the human stays in the loop at the most critical decision point.

***

## `tasks.md` — The Core Primitive

A simple, human-readable format that doubles as the fleet's configuration:

```markdown
# aid tasks

## worker-1: auth-api
Refactor auth endpoints in src/api/auth.ts to use new JWT middleware.
Token header: x-aid-token.
Designated files: src/api/auth.ts, src/api/middleware.ts

## worker-2: auth-tests
Update tests in src/__tests__/auth.test.ts for new x-aid-token header.
Designated files: src/__tests__/auth.test.ts

## worker-3: auth-docs
Update README.md and docs/api.md to document the new auth flow.
Designated files: README.md, docs/api.md
```

Key properties:

- `##` heading → worker name + tmux window title
- Body → prompt injected into that opencode instance
- `Designated files` → scope constraint that prevents agents from clobbering each other
- Written by `/fleet-plan`, edited by user, consumed by `aid --fleet`

***

## Parallelism Model

`aid --fleet` uses **cooperative parallelism** — each worker has a distinct, non-overlapping task — rather than the fan-out/competitive model (same prompt × N agents, pick best). This is the right model for coordinated codebase work.

**Dependency handling** follows a batch model:

```
Batch 1 (truly independent — run in parallel):
  worker-1: api changes
  worker-2: schema changes
  worker-3: type definitions

Batch 2 (depends on batch 1 — spawned after merge):
  worker-4: tests
  worker-5: docs
```

Batch boundaries are defined in `tasks.md` by the user or `/fleet-plan`. Within a batch, agents run with zero runtime coordination — all shared contracts (interface shapes, naming conventions) are baked into each worker's task description upfront, not communicated at runtime.

***

## tmux Layout Architecture

```
┌─────────────────────────────────────────────────────┐
│ [1:worker-api] [2:worker-tests] [3:worker-docs]     │  ← tmux windows
├─────────────────────────────────────────────────────┤
│                                                     │
│         opencode instance (active worker)           │
│                      ~50%                           │
│                                                     │
├─────────────────────────────────────────────────────┤
│  worker-1  ████████░░  running                      │
│  worker-2  ██████████  ✓ done  src/api/auth.ts +12  │
│  worker-3  ░░░░░░░░░░  queued                       │
│       [status + live diff of active worker]  ~50%   │
└─────────────────────────────────────────────────────┘
```

The bottom pane is state-driven — it syncs to the active tmux window via a `window-active` hook, showing:

- **Running**: live step progress + last tool call
- **Done**: diff preview of that worker's worktree
- **Failed**: last error output highlighted in red

A second tmux window (`:editor`) holds nvim + a file tree sidebar rooted to the active worker's worktree path — only open it when you need to intervene directly.

***

## Agent Isolation Layer

Each worker gets its own **git worktree** at `.aid/worktrees/worker-N`, branched from the current HEAD. This is the same isolation primitive Codex Desktop uses internally. Benefits:

- Workers write to completely separate filesystem paths — no file conflicts possible
- Each worktree is a full working copy on its own branch
- `/fleet-merge` can inspect clean per-worker diffs before merging
- Worktrees survive process crashes — work is never lost

***

## Competitive Analysis

`aid --fleet` scores highest on SSH compatibility (it's tmux-native — runs over any remote connection), visibility (live pane layout vs opaque GUI threads), and editor integration (nvim worktree-rooted sidebar). It trades model agnosticism — being opencode-native means it inherits opencode's model support rather than mixing Claude + Codex per run like uzi supports.


| Dimension | aid --fleet | uzi + Codex CLI | Codex Desktop |
| :-- | :-- | :-- | :-- |
| **Parallelism model** | Cooperative — different tasks | Fan-out — same task × N | Mixed — thread-per-task |
| **Task input** | `tasks.md` (per-worker prompts) | Single prompt fanned out | Manual per-thread |
| **Decomposition** | `/fleet-plan` writes `tasks.md` | Manual | Manual |
| **Merge** | `/fleet-merge` (supervised AI) | Manual per-agent rebase | Manual |
| **Layout** | Opinionated half/half tmux | Raw tmux sessions | GUI thread list |
| **SSH/remote** | ✓ Native | ✓ Native | ✗ macOS GUI only |
| **Multi-model** | opencode's model list | Mix Claude + Codex per run | OpenAI models only |
| **Broadcast** | Not yet | `uzi broadcast` | ✗ |
| **Fan-out mode** | Not yet (addable) | Native | ✗ |


***

## What `aid` Stays Responsible For

The boundary of responsibility is deliberately tight — `aid --fleet` does exactly five things and nothing else:

1. **Parse** `tasks.md` into N task objects
2. **Provision** N git worktrees at `.aid/worktrees/worker-N`
3. **Spawn** N tmux windows, each running `opencode` with the task prompt pre-loaded
4. **Render** the half/half layout with the status/diff supervisor pane
5. **Clean up** worktrees after `/fleet-merge` completes (optional `aid --fleet-clean`)

Everything else — LLM calls, task reasoning, merge logic, model selection — belongs to opencode.

***

## Key Differentiators vs All Existing Tools

- **`tasks.md` as version-controlled intent** — unlike every other tool, the task decomposition is a file you can commit, share, reuse, and audit. Your fleet configuration has a git history.
- **Cooperative not competitive parallelism** — the only terminal-native tool designed for divide-and-conquer rather than fan-out exploration
- **SSH-native Codex Desktop equivalent** — the only multi-agent dashboard that works over remote connections and survives disconnects
- **Zero new mental model** — plan in opencode, fleet in the terminal, merge in opencode. Users never leave familiar tools; `aid --fleet` is the invisible glue between them

