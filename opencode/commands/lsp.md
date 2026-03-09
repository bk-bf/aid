---
description: Wire Mason LSP binaries into opencode.json (no args), or check and fix LSP diagnostics for a file or all files
---

## Usage

```
/lsp                      — setup: wire Mason LSP binaries into opencode.json (first run)
/lsp                      — diagnose: check all source files (once opencode.json is configured)
/lsp nvim/init.lua        — diagnose: check a specific file
/lsp src/main.go          — diagnose: check a specific file
```

`$ARGUMENTS` is everything typed after `/lsp`. Examples:

| You type | `$ARGUMENTS` | Behaviour |
|---|---|---|
| `/lsp` | _(empty)_ | Setup mode if opencode.json is bare; diagnose all files if already configured |
| `/lsp nvim/init.lua` | `nvim/init.lua` | Diagnose that specific file |
| `/lsp src/main.go` | `src/main.go` | Diagnose that specific file |

---

## Mode detection — run this first, then jump immediately to the correct section

**Do not read further until you have evaluated these conditions in order.**

**If `$ARGUMENTS` is non-empty:**
→ Go directly to [Diagnose mode](#diagnose-mode). Do not read Setup mode. Do not check opencode.json.

**If `$ARGUMENTS` is empty:**
→ Read `opencode.json` in the current working directory.
  - If it contains an `"lsp"` key with at least one entry that is not `{}`:
    → Go directly to [Diagnose mode](#diagnose-mode). Do not read Setup mode.
  - Otherwise (no `"lsp"` key, or `"lsp"` is `{}`):
    → Go directly to [Setup mode](#setup-mode). Do not read Diagnose mode.

**Stop reading here. Jump to the correct section now.**

---

# Setup mode

You are here because `$ARGUMENTS` is empty and `opencode.json` has no populated `lsp` key.
Goal: discover Mason-installed LSP binaries and write them into `opencode.json`.

---

## Step 1 — Discover Mason-installed LSP servers

Run:

```bash
ls "$HOME/.local/share/aid/nvim/mason/bin/"
```

Collect the list of binary names.

Ignore pure formatter/non-diagnostic tools: `stylua`, `prettier`, `black`, `shfmt`, `ruff`, `gofmt`, `rustfmt`. Everything else that is not an LSP binary and not a diagnostic tool falls through.

Treat these separately as **diagnostic tools** (not wired into `opencode.json`, but noted for Step 4b):
- `selene` — Lua linter
- `shellcheck` — shell linter

Everything else is an LSP binary — map it using the table below.

For each LSP binary found, resolve the opencode server key using this mapping table:

| Mason binary name             | OpenCode server key |
|-------------------------------|---------------------|
| `lua-language-server`         | `lua-ls`            |
| `gopls`                       | `gopls`             |
| `pyright`                     | `pyright`           |
| `rust-analyzer`               | `rust`              |
| `typescript-language-server`  | `typescript`        |
| `bash-language-server`        | `bash`              |
| `yaml-language-server`        | `yaml-ls`           |
| `clangd`                      | `clangd`            |
| `zls`                         | `zls`               |
| `nixd`                        | `nixd`              |
| `kotlin-language-server`      | `kotlin-ls`         |
| `jdtls`                       | `jdtls`             |
| `dartls`                      | `dart`              |
| `ocamllsp`                    | `ocaml-lsp`         |
| `gleam`                       | `gleam`             |

If a binary name is not in the table above and is not in the ignore list, include it as-is (binary name = opencode key).

---

## Step 2 — Build the resolved binary paths

For each matched LSP, the full path is:

```
$HOME/.local/share/aid/nvim/mason/bin/<binary-name>
```

Verify the path exists before including it:

```bash
ls "$HOME/.local/share/aid/nvim/mason/bin/<binary-name>"
```

Only include entries where the binary is confirmed present.

---

## Step 3 — Write opencode.json

If no LSP binaries were found after filtering, print:

```
No LSP servers found in Mason ($HOME/.local/share/aid/nvim/mason/bin/).
Install LSP servers via :Mason in Neovim, then re-run /lsp.
opencode.json left unchanged.
```

Then stop.

Otherwise, read the current contents of `opencode.json` and merge in an `"lsp"` section. Preserve the existing `"$schema"` key and any other keys already present. Write the result back to `opencode.json`.

The `"lsp"` section format for each server:

```json
"<opencode-key>": {
  "command": ["<full-path-to-binary>"]
}
```

Example output for a machine with `lua-language-server` and `gopls` installed:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "lsp": {
    "lua-ls": {
      "command": ["/home/username/.local/share/aid/nvim/mason/bin/lua-language-server"]
    },
    "gopls": {
      "command": ["/home/username/.local/share/aid/nvim/mason/bin/gopls"]
    }
  }
}
```

Use the real expanded path (not `~` or `$HOME`) so the value is unambiguous.

---

## Step 4 — Print summary

```
Configured <N> LSP server(s) in opencode.json:
  <opencode-key>  →  <full binary path>
  ...

OpenCode will now use your Mason-installed binaries instead of auto-downloading its own copies.
To add initialization options or disable a server, edit opencode.json directly.
Docs: https://opencode.ai/docs/lsp/
```

---

## Step 4b — Bootstrap selene.toml (Lua projects only)

Run this step only if **all three** conditions hold:
- `selene` was found in Mason bin during Step 1
- At least one `.lua` file exists anywhere in the project (check with `find . -name "*.lua" -not -path "*/mason/*" -not -path "*/lazy/*" -not -path "*/.git/*" | head -1`)
- No `selene.toml` exists in the project root (`ls selene.toml` → not found)

If `selene.toml` already exists, print:
```
selene.toml already present — left unchanged.
```
Then skip the rest of this step.

If all conditions hold, print:

```
selene is installed and this project contains Lua files.
Generate a selene.toml in the project root?

  [1] Minimal — std = "luajit+vim", global_usage = "allow"
  [2] Full Neovim preset — adds suppressions for mixed_table,
      bad_string_escape, undefined_variable (common false positives
      in Neovim Lua)
  [n] Skip
```

Wait for the user's answer.

If the user answers `n` or `N` or `skip`: print `selene.toml not generated.` and skip.

If the user answers `1` or `minimal`: write the following to `selene.toml` in the project root:

```toml
std = "luajit+vim"

[lints]
# _G writes used for cross-module callbacks
global_usage = "allow"
```

If the user answers `2` or `full`: write the following to `selene.toml` in the project root:

```toml
std = "luajit+vim"

[lints]
# _G writes used for cross-module callbacks
global_usage = "allow"
# lazy.nvim plugin specs mix list and keyed fields — intentional pattern
mixed_table = "allow"
# \xNN hex escapes are valid in LuaJIT but flagged by selene
bad_string_escape = "allow"
# forward-declared functions defined after first use in the same file
undefined_variable = "allow"
```

After writing, print:
```
Generated selene.toml in project root (<choice> preset).
```

---

# Diagnose mode

You are here because either `$ARGUMENTS` is non-empty (specific file), or `$ARGUMENTS` is empty and `opencode.json` already has LSP config (all files).
Goal: run CLI linters directly against the target files and report real diagnostics — no LSP attachment required.

---

## Step D1 — Determine target files

If `$ARGUMENTS` is non-empty, the target is the single file path given in `$ARGUMENTS`. Verify it exists:

```bash
ls "$ARGUMENTS"
```

If the file does not exist, print:

```
File not found: <$ARGUMENTS>
Usage: /lsp <file>  — check diagnostics for a specific file
       /lsp         — check diagnostics for all source files (requires opencode.json to be configured)
```

Then stop.

If `$ARGUMENTS` is empty, discover all source files in the project:

```bash
find . -type f \( -name "*.lua" -o -name "*.py" -o -name "*.go" -o -name "*.rs" \
  -o -name "*.ts" -o -name "*.tsx" -o -name "*.js" -o -name "*.jsx" \
  -o -name "*.sh" -o -name "*.bash" \) \
  | grep -v node_modules | grep -v .git | grep -v lazy | grep -v mason \
  | sort
```

---

## Step D2 — Detect languages and available CLI tools

From the target file list, determine which languages are present by extension.

For each language present, check whether the corresponding CLI tool exists in the Mason bin directory:

```bash
ls "$HOME/.local/share/aid/nvim/mason/bin/"
```

Use this table to match language → tool → invocation:

| Extension(s) | Mason binary | Notes |
|---|---|---|
| `*.lua` | `lua-language-server` | Runs per directory; writes JSON to `--logpath` |
| `*.lua` | `selene` | Runs per file; requires `selene.toml` in project root |
| `*.go` | `gopls` | `gopls check <files>` |
| `*.py` | `pyright` | `pyright --outputjson <dir>` |
| `*.rs` | `rust-analyzer` | `rust-analyzer diagnostics` in project root |
| `*.sh`, `*.bash` | `shellcheck` | `shellcheck -f json <files>` |
| `*.ts`, `*.tsx`, `*.js`, `*.jsx` | `typescript-language-server` | No batch mode — note to user (see below) |

If a tool is not present in the Mason bin directory, skip that language silently and record it as "not checked" for the summary.

---

## Step D3 — Run CLI linters

Run each applicable tool. Collect all output. Do not stop on non-zero exit — linters exit non-zero when they find issues, which is expected.

### Lua — lua-language-server

`lua-language-server --check` operates on a **directory**, not individual files. For each unique directory that contains `.lua` files in the target list, run:

Before constructing the command, check for `.luarc.json` in the project root:

```bash
ls .luarc.json
```

- If found: always include `--configpath $(pwd)/.luarc.json` in the invocation.
- If not found: omit `--configpath` entirely.

Then run:

```bash
LUALS_LOGDIR=$(mktemp -d /tmp/luals-check-XXXXXX)
# with --configpath if .luarc.json exists:
~/.local/share/aid/nvim/mason/bin/lua-language-server \
  --check <lua_dir> \
  --checklevel=Warning \
  --check_format=json \
  --logpath "$LUALS_LOGDIR" \
  --configpath "$(pwd)/.luarc.json"

# without --configpath if .luarc.json is absent:
~/.local/share/aid/nvim/mason/bin/lua-language-server \
  --check <lua_dir> \
  --checklevel=Warning \
  --check_format=json \
  --logpath "$LUALS_LOGDIR"
```

Then read `$LUALS_LOGDIR/check.json`. It is a JSON array. Each entry has the shape:

```json
{
  "file": "file:///absolute/path/to/file.lua",
  "diagnostics": [
    {
      "range": { "start": { "line": 12, "character": 0 }, "end": { ... } },
      "severity": 1,
      "message": "Undefined global `foo`"
    }
  ]
}
```

Severity mapping: `1` = Error, `2` = Warning, `3` = Information, `4` = Hint.
Line numbers in the JSON are **0-indexed** — add 1 for display.

Clean up: `rm -rf "$LUALS_LOGDIR"` after reading.

### Lua — selene

Only run selene if `selene.toml` exists in the project root. Run against all `.lua` target files at once:

```bash
~/.local/share/aid/nvim/mason/bin/selene \
  --config <path/to/selene.toml> \
  --display-style=Json \
  <lua_file1> <lua_file2> ...
```

Each line of stdout is a JSON object:

```json
{
  "severity": "Warning",
  "code": "unused_variable",
  "message": "palette_path is assigned a value, but never used",
  "primary_label": {
    "filename": "nvim/lua/sync.lua",
    "span": { "start_line": 129, "start_column": 8, ... }
  }
}
```

Note: `start_line` is **0-indexed** — add 1 for display.

### Go — gopls

```bash
~/.local/share/aid/nvim/mason/bin/gopls check <go_file1> <go_file2> ...
```

Output is plain text, one diagnostic per line: `file:line:col: message`. Parse accordingly.

### Python — pyright

```bash
~/.local/share/aid/nvim/mason/bin/pyright --outputjson .
```

The JSON output has shape `{ "generalDiagnostics": [ { "file": "...", "range": {...}, "severity": "error"|"warning"|"information", "message": "..." } ] }`.

### Rust — rust-analyzer

Run from the project root (where `Cargo.toml` is):

```bash
~/.local/share/aid/nvim/mason/bin/rust-analyzer diagnostics
```

Output is JSON lines, each with `{ "severity": "error"|"warning", "message": "...", "location": { "file": "...", "line": N } }`.

### Shell — shellcheck

```bash
~/.local/share/aid/nvim/mason/bin/shellcheck -f json <sh_file1> <sh_file2> ...
```

Output is a JSON array: `[ { "file": "...", "line": N, "severity": "error"|"warning"|"info"|"style", "message": "..." } ]`.

### TypeScript / JavaScript — no batch mode

If `.ts`, `.tsx`, `.js`, or `.jsx` files are present but `typescript-language-server` has no batch mode. Print a note:

```
TypeScript/JavaScript: no batch diagnostic mode available.
Run 'npx tsc --noEmit' in your project root for type checking.
```

---

## Step D4 — Collect and print unified diagnostic summary

Merge all tool outputs into a single list. For each diagnostic record:
- File path (relative to cwd)
- Line number (1-indexed)
- Severity: `ERROR`, `WARN`, `INFO`, `HINT`
- Source tool: `lua-ls`, `selene`, `gopls`, `pyright`, `rust-analyzer`, `shellcheck`
- Message

Deduplicate: if `lua-language-server` and `selene` both report the same line in the same file, keep both (they catch different things).

If no diagnostics were found across all tools, print:

```
No diagnostics found.
Tools run: <tool1>, <tool2>, ...
```

Then stop.

Otherwise print grouped by file, sorted by line number within each file, errors before warnings:

```
Diagnostics:

nvim/lua/sync.lua
  line 129  WARN  [selene/unused_variable]  palette_path is assigned a value, but never used

nvim/init.lua
  line 306  WARN  [lua-ls]  undefined field 'get' on type 'Option<boolean>'

Total: <N> error(s), <N> warning(s) across <N> file(s).
Tools run: lua-language-server, selene
Not checked (tool not in Mason): gopls, pyright, rust-analyzer, shellcheck
```

Then ask:

```
Fix all errors and warnings? [Y/n]
```

If the user answers `n` or `N`, print `No changes made.` and stop.

---

## Step D5 — Fix diagnostics

For each file with ERROR or WARN diagnostics, apply fixes:

- Read the file carefully
- Fix each reported diagnostic at the correct line
- Do not change any code that was not flagged
- Prefer minimal, targeted fixes — do not refactor surrounding code
- After editing, re-read the file to confirm the fix did not introduce new issues

Do not auto-fix INFO or HINT unless the user explicitly asks.

---

## Step D6 — Print fix summary

```
Fixed:
  nvim/lua/sync.lua  — 1 issue resolved
  nvim/init.lua      — 1 issue resolved

Done. Re-run /lsp to verify no new diagnostics were introduced.
```
