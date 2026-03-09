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
Goal: discover Mason-installed LSP binaries, wire them into `opencode.json`, and bootstrap any missing linter config files.

---

## Step 1 — Discover Mason bin contents

Run:

```bash
ls "$HOME/.local/share/aid/nvim/mason/bin/"
```

Collect the full list of binary names.

---

## Step 2 — Classify each binary

For each binary, determine whether it is an **LSP server** (to be wired into `opencode.json`) or a **standalone tool** (linter, formatter, etc. — not wired into `opencode.json`).

Use this mapping to resolve LSP binaries to their OpenCode server keys:

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

Any binary **not** in this table is a standalone tool (linter, formatter, etc.) — note it separately for Step 4b.

If a binary is not in the table and you are unsure whether it is an LSP server or a standalone tool, treat it as an LSP server and include it as-is (binary name = opencode key).

---

## Step 3 — Write opencode.json

If no LSP binaries were found, print:

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

Use the real expanded path (not `~` or `$HOME`): `$HOME/.local/share/aid/nvim/mason/bin/<binary-name>`.

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

## Step 4b — Bootstrap linter config files

For each **standalone tool** identified in Step 2:

1. Determine whether this tool requires a config file to function correctly (e.g. `selene` needs `selene.toml`, `lua-language-server` works better with `.luarc.json`). Use your knowledge of the tool.
2. Check whether that config file already exists in the project.
3. If the config file is missing and the project contains files the tool would apply to:
   - Inform the user what is missing and why it matters
   - Offer to generate a sensible default config, presenting options where meaningful (e.g. minimal vs opinionated preset)
   - Wait for the user's answer before writing anything
   - If the user confirms, generate the config file

Do not generate config files silently. Always ask first.
Do not generate config files for tools where no matching source files exist in the project.
If a config file already exists, print that it was found and leave it unchanged.

---

# Diagnose mode

You are here because either `$ARGUMENTS` is non-empty (specific file), or `$ARGUMENTS` is empty and `opencode.json` already has LSP config (all files).
Goal: run available diagnostic tools against the target files and report real diagnostics.

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

If `$ARGUMENTS` is empty, discover all source files in the project, excluding generated/vendor directories:

```bash
find . -type f \( -name "*.lua" -o -name "*.py" -o -name "*.go" -o -name "*.rs" \
  -o -name "*.ts" -o -name "*.tsx" -o -name "*.js" -o -name "*.jsx" \
  -o -name "*.sh" -o -name "*.bash" \) \
  | grep -v node_modules | grep -v .git | grep -v lazy | grep -v mason \
  | sort
```

---

## Step D2 — Discover available tools

List Mason bin contents:

```bash
ls "$HOME/.local/share/aid/nvim/mason/bin/"
```

From this list and the target file extensions, determine which tools are applicable to run. Use your knowledge of each tool to understand:
- Which file types it checks
- How to invoke it in batch/check mode (not interactive)
- What output format to request (prefer JSON or structured output where available)
- Whether it requires a config file, and if so, where to look for it

If a tool is present but has no applicable files, skip it.
If a tool is present but requires a config file that is missing, skip it and note it as "not checked (missing config)".
If a tool is not present, skip it and note it as "not checked (not in Mason)".

---

## Step D3 — Run tools

Run each applicable tool. Collect all output. Do not stop on non-zero exit — diagnostic tools exit non-zero when they find issues, which is expected.

For each tool:
- Invoke it in the appropriate batch/check mode
- Parse its output to extract: file path, line number, severity, message
- Normalise severity to: `ERROR`, `WARN`, `INFO`, `HINT`

### lua-language-server — config resolution

`lua-language-server --check` operates on a directory. Before running it on a directory `<dir>`, locate the nearest `.luarc.json` by walking up the directory tree from `<dir>` toward the project root:

```
<dir>/.luarc.json
<dir>/../.luarc.json
<dir>/../../.luarc.json
... (stop at project root / cwd)
```

Use the first `.luarc.json` found. If one is found, pass `--configpath <absolute-path-to-.luarc.json>`. If none is found anywhere in the tree, omit `--configpath`.

---

## Step D4 — Collect and print unified diagnostic summary

Merge all tool outputs into a single list. For each diagnostic record:
- File path (relative to cwd)
- Line number (1-indexed)
- Severity: `ERROR`, `WARN`, `INFO`, `HINT`
- Source tool name
- Message

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
  line 129  WARN  [selene]  palette_path is assigned a value, but never used

nvim/init.lua
  line 42   WARN  [lua-ls]  undefined global 'vim'

Total: <N> error(s), <N> warning(s) across <N> file(s).
Tools run: <tool1>, <tool2>
Not checked: <tool3> (not in Mason), <tool4> (missing config: selene.toml)
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
