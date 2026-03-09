-- .nvim.lua — per-project formatter and linter config (loaded automatically by nvim)
-- Install tools via :Mason, then uncomment the lines for your stack.
-- LSP servers need no config here — installing them in :Mason is enough.

-- require("conform").setup({ formatters_by_ft = {
--   lua        = { "stylua" },
--   python     = { "black" },
--   go         = { "gofmt" },
--   rust       = { "rustfmt" },
--   javascript = { "prettier" },
--   typescript = { "prettier" },
--   sh         = { "shfmt" },
-- }})

-- require("lint").linters_by_ft = {
--   lua    = { "selene" },   -- also needs selene.toml: echo 'std = "vim"' > selene.toml
--   python = { "ruff" },
--   sh     = { "shellcheck" },
-- }
