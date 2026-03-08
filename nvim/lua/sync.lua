-- sync.lua — central git-sync coordinator + full workspace reload
-- See docs/ARCHITECTURE.md § "Git-sync coordinator" for design rationale,
-- trigger points, and the treemux RPC protocol.

local M = {}

-- Active fs_event watcher handles keyed by directory path.
-- vim.uv.new_fs_event on Linux (inotify) watches a single directory only —
-- recursive=true is a no-op on Linux. We therefore watch the parent directory
-- of each open buffer individually and add new watches on BufEnter.
local _watchers = {}

-- Refresh the treemux sidebar nvim-tree via direct msgpack-RPC.
-- treemux_init.lua registers its socket in @-treemux-nvim-socket-<editor_pane_id>.
local function _refresh_treemux_sidebar()
  local tmux_pane = vim.env.TMUX_PANE
  if not tmux_pane or tmux_pane == "" then return end

  local socket = vim.fn.system(
    "tmux -L aid show-option -gqv '@-treemux-nvim-socket-" .. tmux_pane .. "'"
  ):gsub("%s+$", "")
  if socket == "" then return end

  -- Fire-and-forget: open a channel, notify (no wait for response), close.
  -- rpcnotify is non-blocking — does not stall the main nvim event loop.
  -- pcall guards against a dead socket (treemux restarting, etc.).
  pcall(function()
    local chan = vim.fn.sockconnect("pipe", socket, { rpc = true })
    vim.rpcnotify(chan, "nvim_exec_lua", "require('aidignore').reset()", {})
    -- brief yield so the notification is flushed before we close the channel
    vim.defer_fn(function() pcall(vim.fn.chanclose, chan) end, 500)
  end)
end

-- Main sync entry point. Safe to call from any autocmd or keybind.
-- Uses vim.schedule so it never blocks the event loop.
-- Runs all four components: checktime, gitsigns, nvim-tree, treemux sidebar.
-- Only call from events that signal an external state change (FocusGained,
-- TermClose). For high-frequency events (BufEnter, CursorHold) use
-- sync.checktime() instead to avoid constant sign-column redraws.
function M.sync()
  vim.schedule(function()
    -- 1. Reload buffers that changed on disk (silent — no "press ENTER" prompts)
    vim.cmd("silent! checktime")

    -- 2. Refresh gitsigns (re-reads HEAD, recomputes all hunk signs + branch name)
    local ok_gs, gs = pcall(require, "gitsigns")
    if ok_gs then
      pcall(gs.refresh)
    end

    -- 3. Reload nvim-tree (full tree rebuild + git status)
    local ok_nt, nt = pcall(require, "nvim-tree.api")
    if ok_nt then
      pcall(nt.tree.reload)
    end

    -- 4. Refresh treemux sidebar (separate nvim process) via RPC
    _refresh_treemux_sidebar()
  end)
end

-- Lightweight variant: checktime only, no sign-column or tree redraws.
-- Safe to call from BufEnter / CursorHold without causing visual flicker.
function M.checktime()
  vim.schedule(function()
    vim.cmd("silent! checktime")
  end)
end

-- Full workspace reload: tmux config → nvim config → git state sync.
-- Bound to <leader>R in init.lua.
function M.reload()
  vim.schedule(function()
    -- 1. Regenerate tmux/palette.conf from palette.lua, then reload tmux config.
    --    Done in a single jobstart so the source-file sees the fresh palette.
    if vim.env.TMUX and vim.env.TMUX ~= "" then
      local aid_dir = vim.env.AID_DIR or ""
      if aid_dir ~= "" then
        vim.fn.jobstart(
          aid_dir .. "/gen-tmux-palette.sh && tmux -L aid source-file " ..
          vim.fn.shellescape(aid_dir .. "/tmux.conf"),
          { detach = true }
        )
      end
    end

    -- 2. Reload nvim config
    vim.cmd("silent! source $MYVIMRC")

    -- 3. Re-apply aidignore: re-read from disk, re-setup nvim-tree filters,
    --    restart file watcher. Needed because lazy only runs nvim-tree's config
    --    function once — source $MYVIMRC alone won't re-run it.
    local ok_ai, ai = pcall(require, "aidignore")
    if ok_ai then ai.reset() end

    -- 4. Refresh git state + buffers + sidebar (reuse existing sync logic)
    M.sync()

    vim.notify("workspace reloaded", vim.log.levels.INFO)
  end)
end

-- Watch palette.lua for changes and hot-reload all colors when it is saved.
-- Called once on VimEnter from init.lua.
--
-- On change:
--   1. apply_palette() — busts Lua module cache, re-requires palette, re-applies
--      every nvim highlight group (statusline, bufferline, gitsigns, cursor).
--   2. gen-tmux-palette.sh — re-reads palette.lua via Lua and rewrites
--      tmux/palette.conf, then tmux source-file picks it up.
--   3. vim-tpipeline re-renders the statusline on the next cursor move
--      (no explicit trigger needed — highlight group changes are picked up
--       automatically by the next statusline evaluation).
--
-- The watcher is file-level (watches the directory containing palette.lua and
-- filters to only act on that filename), because vim.uv.fs_event on Linux
-- (inotify) does not support watching a single file directly.
function M.watch_palette()
  local aid_dir = vim.env.AID_DIR or ""
  if aid_dir == "" then return end

  local palette_path = aid_dir .. "/nvim/lua/palette.lua"
  local palette_dir  = aid_dir .. "/nvim/lua"

  -- Avoid double-registering if reload() calls watch_palette() again
  if _watchers["__palette__"] then
    pcall(function() _watchers["__palette__"]:stop() end)
    _watchers["__palette__"] = nil
  end

  local handle = vim.uv.new_fs_event()
  if not handle then return end

  local ok = pcall(function()
    handle:start(palette_dir, {}, vim.schedule_wrap(function(err, filename, _)
      if err then return end
      -- filename may be nil on some platforms; guard and filter to palette.lua only
      if filename and filename ~= "palette.lua" then return end

      -- 1. Re-apply nvim highlights from updated palette
      if type(_G.apply_palette) == "function" then
        _G.apply_palette()
      end

      -- 2. Regenerate tmux palette and source it — run as shell pipeline so
      --    source-file sees the newly written file.
      if vim.env.TMUX and vim.env.TMUX ~= "" then
        vim.fn.jobstart(
          vim.fn.shellescape(aid_dir .. "/gen-tmux-palette.sh") ..
          " && tmux -L aid source-file " ..
          vim.fn.shellescape(aid_dir .. "/tmux/palette.conf"),
          { detach = true }
        )
      end

      vim.notify("palette reloaded", vim.log.levels.INFO)
    end))
  end)

  if ok then
    _watchers["__palette__"] = handle
  end
end

-- Watch the parent directory of a buffer file.
-- Called on BufEnter. Skips special buffers (no file, non-existent paths).
-- Idempotent: if the directory is already watched, does nothing.
-- On any change in that directory, fires sync() so external edits (e.g.
-- from opencode) appear in nvim immediately without requiring a pane switch.
function M.watch_buf(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" then return end
  local dir = vim.fn.fnamemodify(path, ":h")
  if dir == "" or dir == "." then dir = vim.fn.getcwd() end
  if _watchers[dir] then return end  -- already watching

  local handle = vim.uv.new_fs_event()
  if not handle then return end

  local ok = pcall(function()
    handle:start(dir, {}, vim.schedule_wrap(function(err, _, _)
      if err then return end
      M.sync()
    end))
  end)

  if ok then
    _watchers[dir] = handle
  end
end

-- Stop all active directory watchers. Called on VimLeave to clean up handles.
function M.stop_watchers()
  for dir, handle in pairs(_watchers) do
    pcall(function() handle:stop() end)
    _watchers[dir] = nil
  end
end

return M
