-- aidignore.lua — reads the nearest .aidignore from disk (walking up from cwd)
-- and returns pattern tables for nvim-tree and Telescope. Watches the file for
-- changes and re-applies filters to nvim-tree automatically when it is saved.
-- If no .aidignore is found, no patterns are applied and all files are shown.
--
-- Usage:
--   local aidignore = require("aidignore")
--   local pats = aidignore.patterns()
--   -- pats.raw       — plain (non-glob) strings, safe for nvim-tree filters.custom
--   -- pats.telescope — Lua-pattern strings for Telescope file_ignore_patterns
--
--   aidignore.watch()   — start watching the current .aidignore (call after setup)
--   aidignore.reset()   — bust cache + restart watcher for new cwd (DirChanged)

local M = {}

local _cache   = nil
local _watcher = nil  -- active vim.uv fs_event handle
local _watched = nil  -- path currently being watched

-- Convert a plain/glob .aidignore line to a Lua pattern for Telescope.
local function _glob_to_lua(s)
  local escaped = s:gsub("([%(%)%.%%%+%-%[%^%$])", "%%%1")
  escaped = escaped:gsub("%*", ".*")
  escaped = escaped:gsub("%?", ".")
  return escaped
end

-- Build pattern tables from a list of raw .aidignore lines.
--
-- nvim-tree passes every ignore_list key through vim.fn.match() as a vimscript
-- regex. Patterns starting with * (e.g. *.pyc, *~) are invalid vimscript and
-- trigger E33 "no previous atom". Only plain names (no wildcards) are safe.
--
-- pats.raw       — plain names only, safe for vim.fn.match / filters.custom
-- pats.telescope — Lua patterns for all entries (plain + globs), for Telescope
local function _build(raw)
  local plain = {}
  local telescope = {}
  for _, p in ipairs(raw) do
    if p ~= "" then
      -- Only plain names (no * or ?) go to nvim-tree
      if not p:find("[*?]") then
        table.insert(plain, p)
      end
      -- All entries go to Telescope as Lua patterns
      local lp = _glob_to_lua(p)
      if lp ~= "" then
        table.insert(telescope, "^" .. lp .. "[/\\]")
        table.insert(telescope, "[/\\]" .. lp .. "[/\\]")
        table.insert(telescope, "^" .. lp .. "$")
        table.insert(telescope, "[/\\]" .. lp .. "$")
      end
    end
  end
  return { raw = plain, telescope = telescope }
end

-- Walk up from dir, return first .aidignore path found (or nil).
local function _find_aidignore(dir)
  local d = dir
  for _ = 1, 20 do
    local p = d .. "/.aidignore"
    if vim.fn.filereadable(p) == 1 then return p end
    local parent = vim.fn.fnamemodify(d, ":h")
    if parent == d then break end
    d = parent
  end
end

-- Read patterns from a file path. Returns list of raw strings.
local function _read_file(path)
  local raw = {}
  local f = io.open(path, "r")
  if not f then return raw end
  for line in f:lines() do
    line = line:match("^%s*(.-)%s*$")
    if line ~= "" and line:sub(1, 1) ~= "#" then
      table.insert(raw, line)
    end
  end
  f:close()
  return raw
end

-- Update Telescope's live file_ignore_patterns without re-calling telescope.setup().
--
-- IMPLEMENTATION NOTE:
--   require("telescope.config").values is a module-level singleton table that every
--   Telescope picker reads at invocation time. Assigning to it is the same mechanism
--   Telescope uses internally (config.set_defaults() writes into this exact table).
--   The assignment takes effect on the very next Telescope call — no restart required.
--
--   Stability: config.values has been the authoritative config store since
--   telescope.nvim's initial architecture. Safe to treat as stable private API.
local function _apply_to_telescope()
  local ok, cfg = pcall(require, "telescope.config")
  if not ok then return end
  local base = { "^%.git[/\\]" }
  for _, tp in ipairs(M.patterns().telescope) do
    table.insert(base, tp)
  end
  cfg.values.file_ignore_patterns = base
end

-- Update live nvim-tree filter state and redraw without calling setup() again.
--
-- PRIVATE API DEPENDENCY:
--   require("nvim-tree.core").get_explorer().filters.ignore_list
--   Type: table<string, boolean>  (keys are pattern strings, values always true)
--   This field is read on every should_filter() call inside nvim-tree's render
--   loop. Mutating it in-place + calling api.tree.reload() updates the visible
--   tree with zero visual disruption (no window close/reopen, cursor preserved).
--
--   Stability: field has existed under this exact name since the multi-instance
--   refactor (nvim-tree PR #2841). 33 commits to filters.lua, name unchanged.
--   Monitor: https://github.com/nvim-tree/nvim-tree.lua/blob/master/lua/nvim-tree/explorer/filters.lua
--
-- FALLBACK (S2) — if ignore_list is ever renamed/removed, the silent fallback is:
--   1. tmux kill-pane <sidebar_pane_id>
--   2. run ensure_treemux.sh to reopen the sidebar fresh (picks up new filters
--      from disk via aidignore.lua at startup). ~0.5s blank pane visual glitch.
--
-- NOTE: _apply_to_nvimtree() deliberately does NOT call sync.sync().
--   sync() runs checktime which can cause nvim to open .aidignore as a buffer
--   when this function executes inside the sidebar nvim (destroying the tree
--   window). The sidebar's tree is refreshed by _refresh_treemux_sidebar() in
--   sync.lua, which sends only api.tree.reload() via RPC — no checktime.
local function _apply_to_nvimtree()
  local ok_core, core = pcall(require, "nvim-tree.core")
  if not ok_core then return end
  local ok_api, api = pcall(require, "nvim-tree.api")
  if not ok_api then return end

  local explorer = core.get_explorer()
  if explorer and explorer.filters and explorer.filters.ignore_list then
    local pats = M.patterns()
    explorer.filters.ignore_list = {}
    for _, pat in ipairs(pats.raw) do
      explorer.filters.ignore_list[pat] = true
    end
  end
  pcall(api.tree.reload)
  -- Also update Telescope so live_grep / find_files pick up the new patterns
  -- immediately without an nvim restart (BUG-011).
  _apply_to_telescope()
end

-- Returns { raw = {...}, telescope = {...} }
function M.patterns()
  if _cache then return _cache end

  local path = _find_aidignore(vim.fn.getcwd())
  local raw = path and _read_file(path) or {}

  _cache = _build(raw)
  return _cache
end

-- Start (or restart) watching the .aidignore closest to cwd.
-- Called after nvim-tree setup and on DirChanged.
function M.watch()
  if _watcher then
    pcall(function() _watcher:stop() end)
    _watcher = nil
    _watched = nil
  end

  local path = _find_aidignore(vim.fn.getcwd())
  if not path then return end

  local handle = vim.uv.new_fs_event()
  if not handle then return end

  handle:start(path, {}, vim.schedule_wrap(function(err, _, _)
    if err then return end
    _cache = nil
    _apply_to_nvimtree()
  end))

  _watcher = handle
  _watched = path
end

-- Bust cache, re-apply filters to nvim-tree, and restart watcher for current cwd.
-- Call from DirChanged autocmd and after workspace reload.
function M.reset()
  _cache = nil
  _apply_to_nvimtree()
  M.watch()
end

return M
