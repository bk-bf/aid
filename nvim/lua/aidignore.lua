-- aidignore.lua — reads the nearest .aidignore from disk (walking up from cwd)
-- and returns pattern tables for nvim-tree and Telescope. Watches the file for
-- changes and re-applies filters to nvim-tree automatically when it is saved.
-- If no .aidignore is found, no patterns are applied and all files are shown.
--
-- Usage:
--   local aidignore = require("aidignore")
--   local pats = aidignore.patterns()
--   -- pats.raw       — plain strings for nvim-tree filters.custom
--   -- pats.telescope — Lua-pattern strings for Telescope file_ignore_patterns
--
--   aidignore.watch()   — start watching the current .aidignore (call after setup)
--   aidignore.reset()   — bust cache + restart watcher for new cwd (DirChanged)

local M = {}

local _cache    = nil
local _watcher  = nil   -- active vim.uv fs_event handle
local _watched  = nil   -- path currently being watched

-- Escape a plain string for use as a Lua pattern.
local function _escape(s)
  return s:gsub("([%(%)%.%%%+%-%*%?%[%^%$])", "%%%1")
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

-- Read patterns from a file path. Returns list of plain strings.
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

-- Build pattern tables from a list of plain strings.
local function _build(raw)
  local telescope = {}
  for _, p in ipairs(raw) do
    local ep = _escape(p)
    table.insert(telescope, "^" .. ep .. "[/\\]")
    table.insert(telescope, "[/\\]" .. ep .. "[/\\]")
    table.insert(telescope, "^" .. ep .. "$")
    table.insert(telescope, "[/\\]" .. ep .. "$")
  end
  return { raw = raw, telescope = telescope }
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
--   See _refresh_treemux_sidebar() in sync.lua for the pane lookup logic needed.
local function _apply_to_nvimtree()
  local ok_core, core = pcall(require, "nvim-tree.core")
  if not ok_core then return end
  local ok_api, api = pcall(require, "nvim-tree.api")
  if not ok_api then return end

  local explorer = core.get_explorer()
  if explorer and explorer.filters and explorer.filters.ignore_list then
    -- Mutate the live Filters instance directly — no setup() re-call needed.
    local pats = M.patterns()
    explorer.filters.ignore_list = {}
    for _, pat in ipairs(pats.raw) do
      explorer.filters.ignore_list[pat] = true
    end
  end
  pcall(api.tree.reload)

  -- Also refresh the treemux sidebar (separate nvim process) via sync.
  local ok_sync, s = pcall(require, "sync")
  if ok_sync then pcall(s.sync) end
end

-- Returns { raw = {...}, telescope = {...} }
function M.patterns()
  if _cache then return _cache end

  -- Read from disk only. If no .aidignore found, no patterns — show everything.
  local path = _find_aidignore(vim.fn.getcwd())
  local raw = path and _read_file(path) or {}

  _cache = _build(raw)
  return _cache
end

-- Start (or restart) watching the .aidignore closest to cwd.
-- Called after nvim-tree setup and on DirChanged.
function M.watch()
  -- Stop any existing watcher.
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
    -- Bust cache and re-apply filters.
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
