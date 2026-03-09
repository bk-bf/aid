---
description: Wire Mason-installed LSP servers into opencode.json so OpenCode uses the same binaries as Neovim
---

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
