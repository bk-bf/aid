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

## Mode detection

Check `$ARGUMENTS`:

- **`$ARGUMENTS` is non-empty** → **Diagnose mode** for the specific file given. Skip to [Diagnose mode](#diagnose-mode).
- **`$ARGUMENTS` is empty** → read `opencode.json` and check whether an `"lsp"` key exists with at least one entry:
  - **No `lsp` key / bare schema** → **Setup mode**. Continue to [Setup mode](#setup-mode).
  - **`lsp` key present and populated** → **Diagnose mode** for all source files. Skip to [Diagnose mode](#diagnose-mode).

---

# Setup mode

Sync the `lsp` section of `opencode.json` with the LSP servers currently installed in Mason.

---

## Step 1 — Check if opencode.json already has LSP config

Read `opencode.json` in the current working directory (it was bootstrapped there by aid on first launch).

If the file contains an `"lsp"` key with at least one entry that is not `{}`, print:

```
opencode.json already has LSP config — not overwriting.
Edit opencode.json directly to change LSP settings.
Docs: https://opencode.ai/docs/lsp/
```

Then stop. Do not modify the file.

If the `"lsp"` key is absent, is `{}`, or the file is just `{ "$schema": "..." }`, proceed to Step 2.

---

## Step 2 — Discover Mason-installed LSP servers

Run:

```bash
ls "$HOME/.local/share/aid/nvim/mason/bin/"
```

Collect the list of binary names. Ignore non-LSP tools: `stylua`, `selene`, `prettier`, `black`, `shfmt`, `shellcheck`, `ruff`, `gofmt`, `rustfmt`. Everything else is an LSP binary.

For each LSP binary found, resolve the opencode server key using this mapping table:

| Mason binary name        | OpenCode server key  |
|--------------------------|----------------------|
| `lua-language-server`    | `lua-ls`             |
| `gopls`                  | `gopls`              |
| `pyright`                | `pyright`            |
| `rust-analyzer`          | `rust`               |
| `typescript-language-server` | `typescript`     |
| `bash-language-server`   | `bash`               |
| `yaml-language-server`   | `yaml-ls`            |
| `clangd`                 | `clangd`             |
| `zls`                    | `zls`                |
| `nixd`                   | `nixd`               |
| `kotlin-language-server` | `kotlin-ls`          |
| `jdtls`                  | `jdtls`              |
| `dartls`                 | `dart`               |
| `ocamllsp`               | `ocaml-lsp`          |
| `gleam`                  | `gleam`              |

If a binary name is not in the table above and is not in the ignore list, include it as-is (binary name = opencode key) — it may be a custom or less common LSP.

---

## Step 3 — Build the resolved binary paths

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

## Step 4 — Write opencode.json

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

## Step 5 — Print summary

```
Configured <N> LSP server(s) in opencode.json:
  <opencode-key>  →  <full binary path>
  ...

OpenCode will now use your Mason-installed binaries instead of auto-downloading its own copies.
To add initialization options or disable a server, edit opencode.json directly.
Docs: https://opencode.ai/docs/lsp/
```

---

# Diagnose mode

Check LSP diagnostics for a specific file (if `$ARGUMENTS` is set) or all source files in the project (if `$ARGUMENTS` is empty and `opencode.json` already has LSP config). Show all diagnostics, then offer to fix them.

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
  -o -name "*.sh" -o -name "*.bash" -o -name "*.cs" -o -name "*.java" \
  -o -name "*.zig" -o -name "*.nix" \) \
  | grep -v node_modules | grep -v .git | grep -v lazy | grep -v mason \
  | sort
```

---

## Step D2 — Read files and collect diagnostics

Read each target file. OpenCode's LSP client will attach to each file and collect diagnostics automatically.

For each diagnostic reported, record:
- File path (relative to cwd)
- Line number
- Severity (`ERROR`, `WARN`, `INFO`, `HINT`)
- Message

---

## Step D3 — Print diagnostic summary

If no diagnostics were found across all target files, print:

```
No LSP diagnostics found.
```

Then stop.

Otherwise print a summary grouped by file, sorted by severity (ERROR first, then WARN, INFO, HINT):

```
LSP diagnostics:

<relative/path/to/file.lua>
  line 12  ERROR  undefined global 'foo'
  line 34  WARN   unused variable 'bar'

<relative/path/to/other.lua>
  line 5   ERROR  expected ')', got 'end'

Total: <N> error(s), <N> warning(s), <N> info, <N> hint(s) across <N> file(s).
```

Then ask:

```
Fix all diagnostics? [Y/n]
```

If the user answers `n` or `N`, print:

```
No changes made.
```

Then stop.

---

## Step D4 — Fix diagnostics

For each file that has diagnostics (ERROR and WARN only — do not auto-fix INFO or HINT unless the user explicitly asks), apply fixes:

- Read the file carefully
- Fix each reported diagnostic at the correct line
- Do not change any code that was not flagged
- Prefer minimal, targeted fixes — do not refactor surrounding code
- After editing, re-read the file to confirm the fix did not introduce new issues

---

## Step D5 — Print fix summary

```
Fixed:
  <relative/path/to/file.lua>  — <N> issue(s) resolved
  ...

Skipped (INFO/HINT — fix manually if needed):
  <relative/path/to/file.lua>
    line 8  HINT  <message>
  ...

Done. Re-run /lsp <file> to verify no new diagnostics were introduced.
```
