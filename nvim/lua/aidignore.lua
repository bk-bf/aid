-- aidignore.lua — reads the TDL_IGNORE env var (set by aid.sh at launch) and
-- returns pattern tables for nvim-tree and Telescope.
--
-- TDL_IGNORE is a comma-separated list of plain name patterns, e.g.:
--   hooks,info,logs,objects,refs,worktrees,packed-refs,config,description,HEAD
--
-- aid.sh parses .aidignore once at session start and exports TDL_IGNORE into
-- the tmux server environment, so every pane (main nvim + sidebar) inherits it
-- without any file I/O or path walking at nvim startup.
--
-- Usage:
--   local aidignore = require("aidignore")
--   local pats = aidignore.patterns()
--   -- pats.raw       — plain strings for nvim-tree filters.custom
--   -- pats.telescope — Lua-pattern strings for Telescope file_ignore_patterns

local M = {}

local _cache = nil

-- Escape a plain string for use as a Lua pattern.
local function _escape(s)
  return s:gsub("([%(%)%.%%%+%-%*%?%[%^%$])", "%%%1")
end

-- Returns { raw = {...}, telescope = {...} }
function M.patterns()
  if _cache then return _cache end

  local raw = {}
  local env = vim.env.TDL_IGNORE or ""
  if env ~= "" then
    for entry in env:gmatch("[^,]+") do
      entry = entry:match("^%s*(.-)%s*$")  -- trim whitespace
      if entry ~= "" then
        table.insert(raw, entry)
      end
    end
  end

  local telescope = {}
  for _, p in ipairs(raw) do
    local ep = _escape(p)
    -- Lua patterns have no | alternation; add four patterns to cover all positions:
    table.insert(telescope, "^" .. ep .. "[/\\]")     -- at root:    "hooks/"
    table.insert(telescope, "[/\\]" .. ep .. "[/\\]") -- mid-path:  "/hooks/"
    table.insert(telescope, "^" .. ep .. "$")          -- exact bare name
    table.insert(telescope, "[/\\]" .. ep .. "$")      -- trailing:  "/hooks"
  end

  _cache = { raw = raw, telescope = telescope }
  return _cache
end

-- Call this to bust the cache (e.g. if TDL_IGNORE changes mid-session).
function M.reset()
  _cache = nil
end

return M
