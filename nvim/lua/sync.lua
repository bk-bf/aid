-- sync.lua — central git-sync coordinator + full workspace reload
--
-- Four entry points:
--
--   require("sync").sync()
--     Full git-state refresh. Call only on events that signal external change.
--     Refreshes buffers (checktime), gitsigns, nvim-tree, and treemux sidebar.
--
--   require("sync").checktime()
--     Lightweight: checktime only, no sign-column or tree redraws.
--     Safe for high-frequency events (BufEnter, CursorHold) — no flicker.
--
--   require("sync").reload()
--     Full workspace reload triggered manually via <leader>R.
--     Reloads tmux config, nvim config, then calls sync() for state refresh.
--
--   require("sync").watch_buf([bufnr])
--     Watch the parent directory of the given buffer (default: current buffer)
--     for file changes using vim.uv.fs_event. On any change, fires sync()
--     automatically — opencode edits appear in nvim immediately, no pane switch
--     required. Idempotent: already-watched directories are skipped. Call on
--     BufEnter. vim.uv on Linux (inotify) only supports non-recursive watches,
--     so we watch per-buffer-directory rather than cwd recursively.
--
--   require("sync").stop_watchers()
--     Stop all active directory watchers. Call on VimLeave.
--
-- sync() is triggered by:
--   • FocusGained         — nvim regains focus after any external tool
--   • TermClose           — lazygit float closes
--   • explicit call       — post vim.cmd("LazyGit") in the <leader>gg keybind
--   • fs_event watcher    — watch_buf() fires sync() on any change in open buffer's directory
--
-- checktime() is triggered by:
--   • BufEnter/CursorHold — belt-and-suspenders for buffer reload only;
--                           does NOT run gitsigns/nvim-tree to avoid flicker
--
-- sync() is also triggered by:
--   • pane-focus-in hook  — tmux.conf fires `nvim --remote-send lua sync.sync()` into
--                           AID_NVIM_SOCKET on every pane switch; ensures buffers AND
--                           gitsigns line-change highlights update without requiring the
--                           user to physically focus the nvim pane (T-014/BUG-009)
--
-- Components refreshed by sync():
--   1. nvim buffers    — checktime (reloads files changed on disk)
--   2. gitsigns        — refresh() (re-reads HEAD, recomputes hunk signs)
--   3. nvim-tree       — tree.reload() (full tree + git status)
--   4. treemux sidebar — aidignore.reset() via direct msgpack-RPC (T-016/BUG-008)
--                        mutates explorer.filters.ignore_list in-place then
--                        reloads; no setup() re-call, no visual disruption.
--                        See aidignore.lua for private API notes and S2 fallback.
--
-- Treemux RPC (T-016):
--   treemux_init.lua writes its vim.v.servername into the tmux option
--   @-treemux-nvim-socket-<editor_pane_id> on VimEnter and removes it on
--   VimLeave. sync.lua reads that option, opens a sockconnect channel, and
--   calls nvim_exec_lua("require('aidignore').reset()").
--   This is silent and invisible in the treemux pane — no cmdline flash,
--   no send-keys keystrokes injected, no cross-pane redraw bleed (BUG-008).

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
    -- 1. Reload tmux config (runs in background, non-blocking)
    if vim.env.TMUX and vim.env.TMUX ~= "" then
      local aid_dir = vim.env.AID_DIR or ""
      if aid_dir ~= "" then
        vim.fn.jobstart({ "tmux", "-L", "aid", "source-file", aid_dir .. "/tmux.conf" })
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
