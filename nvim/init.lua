-- ============================================================
-- LEADER KEY
-- ============================================================
vim.g.mapleader = " "

-- Disable netrw before any plugin loads — nvim-tree handles all file/dir
-- browsing; netrw must not hijack directory opens or VimEnter.
vim.g.loaded_netrw = 1
vim.g.loaded_netrwPlugin = 1

-- ============================================================
-- OPTIONS
-- ============================================================
-- Set early — before plugins, autocmds, and cheatsheet code — so that
-- vim.o.* reflects the intended globals when any autocmd reads them.
-- Line numbers
vim.opt.number = true
vim.opt.relativenumber = false

-- Editing feel
vim.opt.tabstop = 2
vim.opt.shiftwidth = 2
vim.opt.expandtab = true
vim.opt.smartindent = true
vim.opt.wrap = false
vim.opt.scrolloff = 8
vim.opt.signcolumn = "yes"
vim.opt.cursorline = false

-- Search
vim.opt.ignorecase = true
vim.opt.smartcase = true
vim.opt.hlsearch = false
vim.opt.incsearch = true

-- Per-project config: auto-load .nvim.lua from project root (trust prompt on first open)
vim.opt.exrc = true
vim.opt.secure = true

-- System clipboard
vim.opt.clipboard = "unnamedplus"

-- Splits
vim.opt.splitright = true
vim.opt.splitbelow = true

-- Diff options
vim.opt.diffopt = {
  "internal",
  "filler",
  "closeoff",
  "linematch:60",
  "algorithm:histogram",
}

-- Auto-reload files when changed on disk
vim.opt.updatetime = 500
vim.opt.autoread = true

-- Status line: hidden (tmux bar handles global status across panes)
vim.opt.laststatus = 0

-- Tab bar: always visible (bufferline renders even with a single buffer)
vim.opt.showtabline = 2

-- ============================================================
-- PALETTE (single source of truth for all aid colors)
-- ============================================================
local p = require("palette")

-- ============================================================
-- GIT-SYNC COORDINATOR
-- ============================================================
-- Central module that refreshes all git-aware components after an external
-- git operation (branch switch, pull, stash pop). See nvim/sync.lua.
local sync = require("sync")

-- ============================================================
-- CHEATSHEET
-- ============================================================
-- Opens nvim/cheatsheet.md as a normal file buffer on startup. Re-open: <leader>?
-- Use AID_DIR (real path) rather than stdpath("config") (symlink) so nvim tracks
-- the canonical inode — avoids W13 "file created after editing started" on writes.
local _cs_path = (vim.env.AID_DIR or vim.fn.stdpath("config")) .. "/nvim/cheatsheet.md"

local function _cs_open()
  vim.cmd("edit " .. vim.fn.fnameescape(_cs_path))
end

-- <leader>? — reopen cheatsheet any time
vim.keymap.set("n", "<leader>?", _cs_open, { desc = "Open cheatsheet" })

-- ============================================================
-- BOOTSTRAP LAZY.NVIM
-- ============================================================
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.uv.fs_stat(lazypath) then
  vim.fn.system({ "git", "clone", "https://github.com/folke/lazy.nvim.git", lazypath })
end
vim.opt.rtp:prepend(lazypath)

-- ============================================================
-- KEYMAPS
-- ============================================================

-- LazyGit (<leader>gg to open):
--   a       stage all files      A       stage current file
--   c       commit               C       commit with pre-populated message
--   p       push                 P       pull
--   space   stage/unstage hunk   d       view file diff
--   z       stash                Z       pop stash
--   ]       next tab             [       prev tab
--   q       quit

-- Gitsigns (defined in plugin config):
--   <leader>j  — next git hunk
--   <leader>k  — prev git hunk
--   <leader>hp — preview git hunk
--   <leader>hl — toggle git line highlight

-- LSP (defined in LspAttach autocmd in plugin config):
--   gd         — go to definition
--   K          — hover docs
--   <leader>rn — rename symbol
--   <leader>ca — code action
--   gr         — references

-- Bufferline (defined in plugin config):
--   <Tab>      — next tab
--   <S-Tab>    — prev tab
--   <leader>q  — close tab
--   <leader>tb — toggle tab bar

-- nvim-tree (defined in plugin config):
--   <leader>t  — toggle file tree
--   <leader>tf — reveal file in tree

-- Telescope
-- Global bookmarks (stored in stdpath("data")/global_bookmarks — not per-project)
-- Supports both files and directories. Directories cd+open in nvim-tree; files open in buffer.
-- <leader>ba — bookmark current file or cwd (if no file buffer / in nvim-tree)
-- <leader>bd — remove current file or cwd from bookmarks
-- <leader>bb — open bookmarks in Telescope
local _bm_file = vim.fn.stdpath("data") .. "/global_bookmarks"
local function _bm_read()
  local f = io.open(_bm_file, "r")
  if not f then
    return {}
  end
  local t = {}
  for l in f:lines() do
    if l ~= "" then
      table.insert(t, l)
    end
  end
  f:close()
  return t
end
local function _bm_write(t)
  local f = io.open(_bm_file, "w")
  if not f then
    return
  end
  for _, entry in ipairs(t) do
    f:write(entry .. "\n")
  end
  f:close()
end
-- Returns the most meaningful path: real file buffer → its path; otherwise → cwd
local function _bm_current()
  local path = vim.fn.expand("%:p")
  if path ~= "" and vim.fn.filereadable(path) == 1 then
    return path
  end
  return vim.fn.getcwd()
end
local function _bm_open_picker()
  local t = _bm_read()
  if #t == 0 then
    vim.notify("No bookmarks")
    return
  end
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  require("telescope.pickers")
    .new({}, {
      prompt_title = "Bookmarks",
      finder = require("telescope.finders").new_table({
        results = t,
        entry_maker = function(path)
          local is_dir = vim.fn.isdirectory(path) == 1
          local icon = is_dir and " " or " "
          return { value = path, display = icon .. vim.fn.fnamemodify(path, ":~"), ordinal = path, path = path }
        end,
      }),
      previewer = conf.file_previewer({}),
      sorter = conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr)
        actions.select_default:replace(function()
          actions.close(prompt_bufnr)
          local entry = action_state.get_selected_entry()
          if not entry then
            return
          end
          if vim.fn.isdirectory(entry.value) == 1 then
            vim.cmd("cd " .. vim.fn.fnameescape(entry.value))
            require("nvim-tree.api").tree.change_root(entry.value)
            require("nvim-tree.api").tree.open({ focus = true })
          else
            vim.cmd("edit " .. vim.fn.fnameescape(entry.value))
          end
        end)
        return true
      end,
    })
    :find()
end
vim.keymap.set("n", "<leader>ba", function()
  local path = _bm_current()
  local t = _bm_read()
  for _, v in ipairs(t) do
    if v == path then
      vim.notify("Already bookmarked")
      return
    end
  end
  table.insert(t, path)
  _bm_write(t)
  local label = vim.fn.isdirectory(path) == 1 and "Dir" or "File"
  vim.notify(label .. " bookmarked: " .. vim.fn.fnamemodify(path, ":~"))
end, { desc = "Bookmark: add file or dir" })
vim.keymap.set("n", "<leader>bd", function()
  local path = _bm_current()
  local t = _bm_read()
  local new = {}
  local removed = false
  for _, v in ipairs(t) do
    if v ~= path then
      table.insert(new, v)
    else
      removed = true
    end
  end
  if removed then
    _bm_write(new)
    vim.notify("Bookmark removed")
  else
    vim.notify("Not bookmarked")
  end
end, { desc = "Bookmark: remove file or dir" })
vim.keymap.set("n", "<leader>bb", _bm_open_picker, { desc = "Bookmark: open file or dir" })

-- <leader>f — fuzzy find files with Telescope
vim.keymap.set("n", "<leader>f", "<cmd>Telescope find_files<cr>", { desc = "Find files" })
-- <leader>1 — search text across all files | <leader>2 — switch open buffers
vim.keymap.set("n", "<leader>1", "<cmd>Telescope live_grep<cr>", { desc = "Search in files" })
vim.keymap.set("n", "<leader>2", "<cmd>Telescope buffers<cr>", { desc = "Open buffers" })

-- Visual mode line movement
-- J/K in visual mode — move the selected lines down/up, keeping them auto-indented
vim.keymap.set("v", "J", ":m '>+1<CR>gv=gv", { desc = "Move line down" })
vim.keymap.set("v", "K", ":m '<-2<CR>gv=gv", { desc = "Move line up" })

-- Scrolling
-- Ctrl-d/u — half-page scroll, but re-centers the cursor so you don't lose your place
vim.keymap.set("n", "<C-d>", "<C-d>zz", { desc = "Scroll down centered" })
vim.keymap.set("n", "<C-u>", "<C-u>zz", { desc = "Scroll up centered" })

-- Diff
-- <leader>do — diff the current file against the last git commit in a vertical split
vim.keymap.set("n", "<leader>do", function()
  require("gitsigns").diffthis()
end, { desc = "Diff vs last commit" })
-- <leader>dx — close the diff view and go back to a single window
vim.keymap.set("n", "<leader>dx", function()
  vim.cmd("windo diffoff | wincmd o")
end, { desc = "Close diff" })

-- Undo tree
-- <leader>u — open undo history tree (every save/edit in this session, even after reopen)
vim.keymap.set("n", "<leader>u", "<cmd>UndotreeToggle<cr>", { desc = "Undo tree" })

-- File reload
-- <leader>r  — force reload the current file from disk immediately
-- <leader>R  — reload everything: tmux config, nvim config, git state, sidebar
vim.keymap.set("n", "<leader>r", function()
  vim.cmd("e!")
end, { desc = "Reload file" })
vim.keymap.set("n", "<leader>R", function()
  require("sync").reload()
end, { desc = "Reload workspace (tmux + nvim + sidebar)" })

-- Diagnostics
-- <leader>7/8/9 — diagnostics navigation
-- <leader>gt — all diagnostics (Telescope) | <leader>gf — current buffer diagnostics (Telescope)
vim.keymap.set("n", "<leader>7", vim.diagnostic.goto_next, { desc = "Next diagnostic" })
vim.keymap.set("n", "<leader>8", vim.diagnostic.goto_prev, { desc = "Prev diagnostic" })
vim.keymap.set("n", "<leader>9", vim.diagnostic.open_float, { desc = "Show diagnostic" })
vim.keymap.set("n", "<leader>gt", "<cmd>Telescope diagnostics<cr>", { desc = "All diagnostics (Telescope)" })
vim.keymap.set("n", "<leader>gf", "<cmd>Telescope diagnostics bufnr=0<cr>", { desc = "Buffer diagnostics (Telescope)" })

-- Spell
-- <leader>sS — toggle spell (en) | <leader>se — English | <leader>sd — German | <leader>sn — off
vim.keymap.set("n", "<leader>sS", function()
  local on = not vim.wo.spell
  vim.opt_local.spell = on
  vim.opt_local.spelllang = "en"
  vim.notify("Spell: " .. (on and "on (en)" or "off"))
end, { desc = "Toggle spell (en)" })
vim.keymap.set("n", "<leader>se", function()
  vim.opt_local.spell = true
  vim.opt_local.spelllang = "en"
  vim.notify("Spell: en")
end, { desc = "Spell: English" })
vim.keymap.set("n", "<leader>sd", function()
  vim.opt_local.spell = true
  vim.opt_local.spelllang = "de"
  vim.notify("Spell: de")
end, { desc = "Spell: German" })
vim.keymap.set("n", "<leader>sn", function()
  vim.opt_local.spell = false
  vim.notify("Spell: off")
end, { desc = "Spell: off" })

-- ============================================================
-- STATUSLINE FUNCTION (hidden in nvim, piped to tmux via tpipeline)
-- ============================================================
function _G.setup_statusline()
  local sl = require("mini.statusline")
  sl.setup({
    content = {
      active = function()
        local mode, mode_hl = sl.section_mode({ trunc_width = 0 }) -- 0 = always verbose
        local git = sl.section_git({ trunc_width = 75 })
        local diag = sl.section_diagnostics({ trunc_width = 75 })
        local filename = sl.section_filename({ trunc_width = 140 })
        local fileinfo = sl.section_fileinfo({ trunc_width = 120 })
        local location = sl.section_location({ trunc_width = 75 })

        -- Dynamic separator colors based on current mode highlight
        local ok, minfo = pcall(vim.api.nvim_get_hl, 0, { name = mode_hl, link = false })
        local mode_bg = (ok and minfo.bg) and string.format("#%06x", minfo.bg) or p.purple
        vim.api.nvim_set_hl(0, "StatusSepModeToDevinfo", { fg = mode_bg, bg = p.blue })
        vim.api.nvim_set_hl(0, "StatusSepFileinfoToMode", { fg = p.blue, bg = mode_bg })

        local arrow = "\xee\x82\xb0" -- U+E0B0 Powerline right arrow
        local sep = function(hl)
          return string.format("%%#%s#%s", hl, arrow)
        end

        return sl.combine_groups({
          { hl = mode_hl, strings = { mode } },
          sep("StatusSepModeToDevinfo"),
          { hl = "MiniStatuslineDevinfo", strings = { git, diag } },
          sep("StatusSepDevinfoToFilename"),
          "%<",
          { hl = "MiniStatuslineFilename", strings = { filename } },
          "%=",
          { hl = "MiniStatuslineFileinfo", strings = { fileinfo } },
          sep("StatusSepFileinfoToMode"),
          { hl = mode_hl, strings = { location } },
        })
      end,
    },
  })
end

-- ============================================================
-- PLUGINS
-- ============================================================
require("lazy").setup({
  -- File tree (VS Code-style sidebar)
  {
    "nvim-tree/nvim-tree.lua",
    event = "VimEnter",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    opts = {
      view = { width = 30 },
      renderer = { group_empty = true },
      filters = { dotfiles = false, git_ignored = false }, -- show hidden and git-ignored files
    },
    keys = {
      { "<leader>t", "<cmd>NvimTreeToggle<cr>", desc = "Toggle file tree" },
      { "<leader>tf", "<cmd>NvimTreeFindFile<cr>", desc = "Reveal file in tree" },
    },
    config = function(_, opts)
      -- Populate filters.custom from .aidignore before setup
      local aidignore = require("aidignore")
      local ignore_pats = aidignore.patterns()
      opts.filters = opts.filters or {}
      opts.filters.custom = ignore_pats.raw

      opts.on_attach = function(bufnr)
        local api = require("nvim-tree.api")
        -- load all default nvim-tree mappings first
        api.config.mappings.default_on_attach(bufnr)
        -- re-expose bookmark keys inside nvim-tree (they are shadowed by the buffer-local keymap layer)
        local function map(key, desc, fn)
          vim.keymap.set("n", key, fn, { buffer = bufnr, desc = desc, noremap = true, silent = true })
        end
        map("<leader>ba", "Bookmark: add cwd", function()
          local path = _bm_current()
          local t = _bm_read()
          for _, v in ipairs(t) do
            if v == path then
              vim.notify("Already bookmarked")
              return
            end
          end
          table.insert(t, path)
          _bm_write(t)
          local label = vim.fn.isdirectory(path) == 1 and "Dir" or "File"
          vim.notify(label .. " bookmarked: " .. vim.fn.fnamemodify(path, ":~"))
        end)
        map("<leader>bd", "Bookmark: remove cwd", function()
          local path = _bm_current()
          local t = _bm_read()
          local new = {}
          local removed = false
          for _, v in ipairs(t) do
            if v ~= path then
              table.insert(new, v)
            else
              removed = true
            end
          end
          if removed then
            _bm_write(new)
            vim.notify("Bookmark removed")
          else
            vim.notify("Not bookmarked")
          end
        end)
        map("<leader>bb", "Bookmark: open", _bm_open_picker)
      end
      require("nvim-tree").setup(opts)
      -- Start watching .aidignore for live filter updates
      require("aidignore").watch()
    end,
  },

  -- Git change highlights
  {
    "lewis6991/gitsigns.nvim",
    opts = {
      signs = {
        add = { text = "▎" },
        change = { text = "▎" },
        delete = { text = "▎" },
      },
      sign_priority = 6,
      numhl = true,
      linehl = false, -- responsible for line highlighting --
      on_attach = function(bufnr)
        local gs = package.loaded.gitsigns
        local map = function(keys, fn, desc)
          vim.keymap.set("n", keys, fn, { buffer = bufnr, desc = desc })
        end
        map("<leader>j", gs.next_hunk, "Next git change")
        map("<leader>k", gs.prev_hunk, "Prev git change")
        map("<leader>hp", gs.preview_hunk, "Preview git change")
        map("<leader>hl", gs.toggle_linehl, "Toggle git line highlight")
      end,
    },
  },

  -- Undo history visualizer
  { "mbbill/undotree" },

  -- File tabs (like VS Code)
  {
    "akinsho/bufferline.nvim",
    event = "VimEnter",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    opts = {
      options = {
        separator_style = "thin",
        diagnostics = "nvim_lsp",
        -- Keep the bar visible even when only one buffer is open.  Without this
        -- bufferline fights showtabline = 2 and can blank the bar on single-buffer
        -- sessions (e.g. right after a cold start or after closing all but one tab).
        always_show_bufferline = true,
        -- BUG-018: use bwipe instead of the default bdelete so closed buffers leave
        -- no ghost entry.  bdelete marks the buffer unlisted+unloaded but keeps it
        -- in nvim's buffer table; _remote_bufnr() then finds it via bufnr() and
        -- routes `buffer N` into the invisible ghost, hiding it from bufferline.
        -- bwipe removes the entry entirely, so the dedup check correctly falls
        -- through to tabnew on the next open.
        close_command = "bwipe! %d",
        right_mouse_command = "bwipe! %d",
      },
      highlights = {
        fill = { bg = p.tab_bg },
        background = { fg = p.tab_fg, bg = p.tab_bg },
        tab = { fg = p.tab_fg, bg = p.tab_bg },
        tab_selected = { fg = p.tab_fg, bg = p.tab_sel, bold = true },
        tab_separator = { fg = p.tab_bg, bg = p.tab_bg },
        tab_separator_selected = { fg = p.tab_sel, bg = p.tab_sel },
        tab_close = { fg = p.tab_fg, bg = p.tab_bg },
        separator = { fg = p.tab_bg, bg = p.tab_bg },
        separator_selected = { fg = p.tab_sel, bg = p.tab_sel },
        separator_visible = { fg = p.tab_bg, bg = p.tab_bg },
        -- nocombine: prevents LSP/treesitter semantic tokens from bleeding their
        -- fg color over the buffer name text in the tab bar (BUG-021).
        buffer_selected = { fg = p.tab_fg, bg = p.tab_sel, bold = true, nocombine = true },
        buffer_visible = { fg = p.tab_fg, bg = p.tab_bg, nocombine = true },
        close_button = { fg = p.tab_fg, bg = p.tab_bg },
        close_button_selected = { fg = p.tab_fg, bg = p.tab_sel },
        close_button_visible = { fg = p.tab_fg, bg = p.tab_bg },
        modified = { fg = p.tab_fg, bg = p.tab_bg },
        modified_selected = { fg = p.tab_fg, bg = p.tab_sel },
        modified_visible = { fg = p.tab_fg, bg = p.tab_bg },
        duplicate = { fg = p.tab_fg, bg = p.tab_bg },
        duplicate_selected = { fg = p.tab_fg, bg = p.tab_sel },
        duplicate_visible = { fg = p.tab_fg, bg = p.tab_bg },
        indicator_selected = { fg = p.tab_sel, bg = p.tab_sel },
        indicator_visible = { fg = p.tab_bg, bg = p.tab_bg },
        numbers = { fg = p.tab_fg, bg = p.tab_bg },
        numbers_selected = { fg = p.tab_fg, bg = p.tab_sel },
        numbers_visible = { fg = p.tab_fg, bg = p.tab_bg },
        diagnostic = { fg = p.tab_fg, bg = p.tab_bg },
        diagnostic_selected = { fg = p.tab_fg, bg = p.tab_sel },
        diagnostic_visible = { fg = p.tab_fg, bg = p.tab_bg },
        -- Per-severity groups: without these bufferline inherits DiagnosticError/Warn
        -- fg colors and tints the buffer name when LSP reports diagnostics (BUG-021).
        error = { fg = p.tab_fg, bg = p.tab_bg },
        error_selected = { fg = p.tab_fg, bg = p.tab_sel, bold = true, nocombine = true },
        error_visible = { fg = p.tab_fg, bg = p.tab_bg },
        error_diagnostic = { fg = p.tab_fg, bg = p.tab_bg },
        error_diagnostic_selected = { fg = p.tab_fg, bg = p.tab_sel },
        error_diagnostic_visible = { fg = p.tab_fg, bg = p.tab_bg },
        warning = { fg = p.tab_fg, bg = p.tab_bg },
        warning_selected = { fg = p.tab_fg, bg = p.tab_sel, bold = true, nocombine = true },
        warning_visible = { fg = p.tab_fg, bg = p.tab_bg },
        warning_diagnostic = { fg = p.tab_fg, bg = p.tab_bg },
        warning_diagnostic_selected = { fg = p.tab_fg, bg = p.tab_sel },
        warning_diagnostic_visible = { fg = p.tab_fg, bg = p.tab_bg },
        info = { fg = p.tab_fg, bg = p.tab_bg },
        info_selected = { fg = p.tab_fg, bg = p.tab_sel, bold = true, nocombine = true },
        info_visible = { fg = p.tab_fg, bg = p.tab_bg },
        info_diagnostic = { fg = p.tab_fg, bg = p.tab_bg },
        info_diagnostic_selected = { fg = p.tab_fg, bg = p.tab_sel },
        info_diagnostic_visible = { fg = p.tab_fg, bg = p.tab_bg },
        hint = { fg = p.tab_fg, bg = p.tab_bg },
        hint_selected = { fg = p.tab_fg, bg = p.tab_sel, bold = true, nocombine = true },
        hint_visible = { fg = p.tab_fg, bg = p.tab_bg },
        hint_diagnostic = { fg = p.tab_fg, bg = p.tab_bg },
        hint_diagnostic_selected = { fg = p.tab_fg, bg = p.tab_sel },
        hint_diagnostic_visible = { fg = p.tab_fg, bg = p.tab_bg },
        trunc_marker = { fg = p.tab_fg, bg = p.tab_bg },
        offset_separator = { fg = p.tab_bg, bg = p.tab_bg },
      },
    },
    keys = {
      { "<Tab>", "<cmd>BufferLineCycleNext<cr>", desc = "Next tab" },
      { "<S-Tab>", "<cmd>BufferLineCyclePrev<cr>", desc = "Prev tab" },
      -- BUG-018: bwipe instead of bdelete — removes the buffer entry entirely so
      -- _remote_bufnr() cannot find a ghost unlisted buffer on the next open.
      { "<leader>q", "<cmd>bwipe<cr>", desc = "Close tab" },
      {
        "<leader>tb",
        function()
          vim.o.showtabline = vim.o.showtabline == 2 and 1 or 2
          vim.cmd("redrawtabline")
        end,
        desc = "Toggle tab bar",
      },
    },
    config = function(_, opts)
      require("bufferline").setup(opts)
      -- Force a tabline redraw so bufferline renders immediately on startup
      -- without requiring a keypress (Tab) to trigger the first render.
      -- defer_fn gives the UI time to fully initialise before redrawing.
      vim.defer_fn(function()
        vim.cmd("redrawtabline")
      end, 50)
      -- BUG-018: when files are opened from the treemux sidebar, nvim receives
      -- a raw RPC command (tabnew / edit / buffer N).  BufAdd/TabNew fire for
      -- genuinely new buffers/tabs, but the dedup path sends `buffer N` which
      -- only fires BufEnter, and `edit` on an already-loaded buffer also only
      -- fires BufEnter.  Including BufEnter covers all three code paths without
      -- meaningful overhead — redrawtabline is cheap and idempotent.
      vim.api.nvim_create_autocmd({ "BufAdd", "BufEnter", "TabNew" }, {
        desc = "BUG-018: force bufferline redraw after RPC-triggered buffer/tab open",
        callback = function()
          vim.cmd("redrawtabline")
        end,
      })
    end,
  },

  -- Fuzzy finder
  {
    "nvim-telescope/telescope.nvim",
    dependencies = { "nvim-lua/plenary.nvim" },
    opts = {
      pickers = {
        find_files = { hidden = true, no_ignore_vcs = true, follow = true },
        live_grep = { additional_args = { "--hidden", "--no-ignore-vcs", "--glob", "!**/.git/*" } },
      },
    },
    config = function(_, opts)
      require("telescope").setup(opts)
      -- Apply .aidignore patterns to Telescope immediately after setup (BUG-011).
      -- aidignore.reset() sets file_ignore_patterns via _apply_to_telescope(), which
      -- is the same path used by the live fs_event watcher — startup and live-update
      -- are now identical. No manual pattern merge needed here.
      require("aidignore").reset()
    end,
  },

  -- Keymap help popup
  {
    "folke/which-key.nvim",
    event = "VeryLazy",
    opts = {},
  },

  -- Lazygit inside nvim
  {
    "kdheepak/lazygit.nvim",
    dependencies = { "nvim-lua/plenary.nvim" },
    keys = {
      {
        "<leader>gg",
        function()
          -- Detect the git context for the current buffer so lazygit always
          -- receives explicit -w/-g flags. This avoids lazygit's -p fallback,
          -- which appends /.git/ and breaks bare-repo + worktree setups.
          --
          -- Strategy:
          --   1. Start from the current buffer's directory (or cwd if no file).
          --   2. Walk up looking for .git (file = worktree, dir = normal repo).
          --   3. If nothing found from buf_dir, retry from cwd.
          --   4. Always set GIT_DIR + GIT_WORK_TREE; never leave them nil.
          --      Lazygit only uses -w/-g (correct) when both env vars are set.

          local function find_git_root(start_dir)
            local dir = start_dir
            for _ = 1, 30 do
              local stat = vim.uv.fs_stat(dir .. "/.git")
              if stat then
                return dir, stat.type -- "file" = worktree, "directory" = normal repo
              end
              local parent = vim.fn.fnamemodify(dir, ":h")
              if parent == dir then
                break
              end
              dir = parent
            end
            return nil, nil
          end

          local buf_dir = vim.fn.expand("%:p:h")
          if buf_dir == "" then
            buf_dir = vim.fn.getcwd()
          end

          local work_tree, git_type = find_git_root(buf_dir)

          -- Second chance: retry from cwd if buf_dir search failed
          if not work_tree then
            local cwd = vim.fn.getcwd()
            if cwd ~= buf_dir then
              work_tree, git_type = find_git_root(cwd)
            end
          end

          if work_tree then
            local git_dir
            if git_type == "file" then
              -- Worktree: .git file contains "gitdir: <path>" — ask git for the real dir
              git_dir =
                vim.fn.system("git -C " .. vim.fn.shellescape(work_tree) .. " rev-parse --git-dir"):gsub("%s+$", "")
              if vim.v.shell_error ~= 0 then
                git_dir = nil
              end
            else
              -- Normal repo: .git is a directory directly inside work_tree
              git_dir = work_tree .. "/.git"
            end

            if git_dir then
              -- Resolve relative paths to absolute
              if git_dir:sub(1, 1) ~= "/" then
                git_dir = vim.fn.fnamemodify(work_tree .. "/" .. git_dir, ":p"):gsub("/$", "")
              end
              vim.env.GIT_DIR = git_dir
              vim.env.GIT_WORK_TREE = work_tree
            else
              vim.env.GIT_DIR = nil
              vim.env.GIT_WORK_TREE = nil
            end
          else
            vim.env.GIT_DIR = nil
            vim.env.GIT_WORK_TREE = nil
          end

          vim.cmd("LazyGit")
          -- Clear env vars immediately after lazygit launches.
          -- lazygit.nvim reads them once to build the -w/-g flags; they must
          -- not persist into the nvim process after lazygit closes or gitsigns
          -- will inherit them on gs.refresh() and treat every buffer as
          -- "outside worktree", breaking the statusline git info permanently.
          vim.env.GIT_DIR = nil
          vim.env.GIT_WORK_TREE = nil
          -- Explicit post-lazygit refresh (belt-and-suspenders alongside
          -- the TermClose autocmd, in case TermClose fires before the
          -- terminal buffer is fully torn down).
          sync.sync()
        end,
        desc = "Open LazyGit",
      },
    },
  },

  -- Auto-close brackets, quotes, etc.
  { "echasnovski/mini.pairs", opts = {} },
  { "echasnovski/mini.cursorword", opts = {} },

  -- Session save/restore (per working directory, auto-saves on exit)
  {
    "folke/persistence.nvim",
    event = "BufReadPre",
    opts = {},
    keys = {
      {
        "<leader>sl",
        function()
          require("persistence").load({ last = true })
        end,
        desc = "Restore last session",
      },
      {
        "<leader>ss",
        function()
          require("persistence").load()
        end,
        desc = "Restore session for cwd",
      },
      {
        "<leader>sd",
        function()
          require("persistence").stop()
        end,
        desc = "Don't save session on exit",
      },
    },
  },

  -- Statusline content provider (hidden via laststatus=0, piped to tmux by tpipeline)
  {
    "echasnovski/mini.statusline",
    config = function()
      _G.setup_statusline()
    end,
  },

  -- Embed nvim statusline into the tmux bar (mode, filename, LSP info across all panes)
  {
    "vimpostor/vim-tpipeline",
    lazy = false,
    config = function()
      vim.g.tpipeline_autoembed = 1
    end,
  },

  -- Global file bookmarks via Telescope (<leader>ba add, <leader>bb open, <leader>bd remove)
  -- Harpoon removed: scopes bookmarks per-project (CWD), useless from other directories.
  -- This stores absolute paths in a fixed file — works from anywhere.

  -- Markdown browser preview (<leader>mp to open, <leader>ms to stop)
  {
    "iamcco/markdown-preview.nvim",
    build = "cd app && npm install && git restore .",
    ft = { "markdown" },
    init = function()
      -- aid sets XDG_CONFIG_HOME=$AID_DIR so nvim finds its config. The node
      -- server inherits that env, and any browser it spawns (directly or via
      -- xdg-open) also inherits it — causing Firefox/Zen to write profiles to
      -- $XDG_CONFIG_HOME/mozilla/ (i.e. inside the repo) instead of ~/.mozilla.
      -- Fix: use a browserfunc that strips the aid XDG overrides before opening,
      -- so the browser sees the real user XDG dirs.
      vim.g.mkdp_browserfunc = "MkdpOpenBrowser"
      vim.cmd([[
        function! MkdpOpenBrowser(url) abort
          call jobstart([
            \ 'env',
            \ '-u', 'XDG_CONFIG_HOME',
            \ '-u', 'XDG_DATA_HOME',
            \ '-u', 'XDG_STATE_HOME',
            \ '-u', 'XDG_CACHE_HOME',
            \ 'xdg-open', a:url
            \ ])
        endfunction
      ]])
    end,
    keys = {
      {
        "<leader>mp",
        function()
          vim.cmd("MarkdownPreview")
          vim.fn.jobstart({ "notify-send", "Markdown Preview", "Preview opened" })
        end,
        desc = "Markdown preview open",
      },
      {
        "<leader>ms",
        function()
          vim.cmd("MarkdownPreviewStop")
          vim.fn.jobstart({ "notify-send", "Markdown Preview", "Preview stopped" })
        end,
        desc = "Markdown preview stop",
      },
    },
  },

  -- Syntax highlighting
  {
    "nvim-treesitter/nvim-treesitter",
    build = ":TSUpdate",
    config = function()
      require("nvim-treesitter.config").setup({
        ensure_installed = {
          "lua",
          "python",
          "bash",
          "json",
          "jsonc",
          "toml",
          "yaml",
          "ini",
          "css",
          "markdown",
          "markdown_inline",
          "go",
        },
        auto_install = true,
        highlight = { enable = true },
        indent = { enable = true },
      })
    end,
  },

  -- ── Mason: binary package manager for LSP servers, linters, formatters, DAP adapters
  -- Open :Mason to browse ~700 packages and install what you need.
  -- Nothing is pre-installed; aid only wires the infrastructure.
  {
    "williamboman/mason.nvim",
    build = ":MasonUpdate",
    opts = {},
  },

  -- ── mason-lspconfig: bridges mason ↔ nvim-lspconfig
  -- automatic_enable = true (Neovim 0.11+): any Mason-installed LSP server that has
  -- a matching lspconfig entry is automatically enabled for the correct filetypes —
  -- zero per-server boilerplate required.
  {
    "williamboman/mason-lspconfig.nvim",
    dependencies = { "williamboman/mason.nvim", "neovim/nvim-lspconfig" },
    config = function()
      require("mason-lspconfig").setup({
        automatic_enable = true,
      })
    end,
  },

  -- LSP
  {
    "neovim/nvim-lspconfig",
    dependencies = { "hrsh7th/cmp-nvim-lsp" },
    config = function()
      local capabilities = require("cmp_nvim_lsp").default_capabilities()

      -- Pass capabilities to all servers that mason-lspconfig auto-enables.
      -- This runs before mason-lspconfig wires the servers, so the capabilities
      -- table is available for every server it enables.
      vim.lsp.config("*", { capabilities = capabilities })

      -- Keymaps available when LSP attaches to a buffer
      vim.api.nvim_create_autocmd("LspAttach", {
        callback = function(event)
          local opts = { buffer = event.buf }
          vim.keymap.set("n", "gd", vim.lsp.buf.definition, opts)
          vim.keymap.set("n", "K", vim.lsp.buf.hover, opts)
          vim.keymap.set("n", "<leader>rn", vim.lsp.buf.rename, opts)
          vim.keymap.set("n", "<leader>ca", vim.lsp.buf.code_action, opts)
          vim.keymap.set("n", "gr", vim.lsp.buf.references, opts)
        end,
      })
    end,
  },

  -- ── conform.nvim: formatter runner
  -- formatters_by_ft is intentionally empty — add entries per-project in .nvim.lua,
  -- or globally in ~/.config/nvim/lua/user.lua once T-019 lands.
  -- format_on_save falls back to LSP formatting when no formatter is configured.
  -- <leader>F — format current buffer manually.
  {
    "stevearc/conform.nvim",
    event = "BufWritePre",
    keys = {
      {
        "<leader>F",
        function()
          require("conform").format({ async = true })
        end,
        desc = "Format buffer",
      },
    },
    opts = {
      formatters_by_ft = {},
      format_on_save = {
        timeout_ms = 1000,
        lsp_fallback = true,
      },
    },
  },

  -- ── nvim-lint: linter runner
  -- linters_by_ft is intentionally empty — add entries per-project in .nvim.lua.
  -- Reports via vim.diagnostic. The BufWritePost autocmd triggers lint.try_lint()
  -- which is a no-op when no linters are configured for the current filetype.
  {
    "mfussenegger/nvim-lint",
    event = { "BufWritePost" },
    config = function()
      local lint = require("lint")
      lint.linters_by_ft = {}
      vim.api.nvim_create_autocmd("BufWritePost", {
        desc = "nvim-lint: run linters after save",
        callback = function()
          lint.try_lint()
        end,
      })
    end,
  },

  -- ── nvim-dap + nvim-dap-ui + mason-nvim-dap: debugger layer
  -- mason-nvim-dap with handlers = {} auto-installs default adapter configs for any
  -- Mason-installed DAP adapter — no per-language boilerplate required.
  -- nvim-dap-ui opens/closes automatically when a debug session starts/ends.
  --
  -- NOTE: Python (debugpy) — debugpy runs in Mason's own venv, not the project venv.
  -- If your project uses a virtualenv, set dap.configurations.python[n].pythonPath
  -- to your interpreter path (e.g. in .nvim.lua). Aid cannot safely auto-detect this.
  --
  -- Keymaps:
  --   <leader>dc  — continue / start
  --   <leader>db  — toggle breakpoint
  --   <leader>dB  — conditional breakpoint
  --   <leader>di  — step into
  --   <leader>do  — step over
  --   <leader>dO  — step out
  --   <leader>dr  — open REPL
  --   <leader>dq  — terminate session
  --   <leader>du  — toggle DAP UI manually
  {
    "mfussenegger/nvim-dap",
    dependencies = {
      {
        "rcarriga/nvim-dap-ui",
        dependencies = { "nvim-neotest/nvim-nio" },
        config = function()
          local dapui = require("dapui")
          dapui.setup()
          -- Auto-open/close the UI when a session starts/ends
          local dap = require("dap")
          dap.listeners.after.event_initialized["dapui_config"] = function()
            dapui.open()
          end
          dap.listeners.before.event_terminated["dapui_config"] = function()
            dapui.close()
          end
          dap.listeners.before.event_exited["dapui_config"] = function()
            dapui.close()
          end
        end,
      },
      {
        "jay-babu/mason-nvim-dap.nvim",
        dependencies = { "williamboman/mason.nvim" },
        opts = {
          -- handlers = {} activates automatic default configs for every installed adapter
          handlers = {},
        },
      },
    },
    keys = {
      {
        "<leader>dc",
        function()
          require("dap").continue()
        end,
        desc = "Debug: continue",
      },
      {
        "<leader>db",
        function()
          require("dap").toggle_breakpoint()
        end,
        desc = "Debug: toggle breakpoint",
      },
      {
        "<leader>dB",
        function()
          require("dap").set_breakpoint(vim.fn.input("Condition: "))
        end,
        desc = "Debug: conditional breakpoint",
      },
      {
        "<leader>di",
        function()
          require("dap").step_into()
        end,
        desc = "Debug: step into",
      },
      {
        "<leader>do",
        function()
          require("dap").step_over()
        end,
        desc = "Debug: step over",
      },
      {
        "<leader>dO",
        function()
          require("dap").step_out()
        end,
        desc = "Debug: step out",
      },
      {
        "<leader>dr",
        function()
          require("dap").repl.open()
        end,
        desc = "Debug: open REPL",
      },
      {
        "<leader>dq",
        function()
          require("dap").terminate()
        end,
        desc = "Debug: terminate",
      },
      {
        "<leader>du",
        function()
          require("dapui").toggle()
        end,
        desc = "Debug: toggle UI",
      },
    },
  },

  -- Autocompletion
  {
    "hrsh7th/nvim-cmp",
    dependencies = {
      "hrsh7th/cmp-nvim-lsp",
      "hrsh7th/cmp-buffer",
      "hrsh7th/cmp-path",
      "hrsh7th/cmp-nvim-lsp-signature-help", -- function parameter hints in the popup
      "garymjr/nvim-snippets",               -- vim.snippet adapter (nvim 0.10+ built-in)
    },
    config = function()
      local cmp = require("cmp")
      cmp.setup({
        -- Show the popup automatically as you type; pre-select the first item so
        -- <CR> confirms immediately without a separate <Tab> to select.
        completion = { completeopt = "menu,menuone,noinsert" },
        snippet = {
          expand = function(args)
            vim.snippet.expand(args.body) -- nvim 0.10+ built-in snippet engine
          end,
        },
        mapping = cmp.mapping.preset.insert({
          ["<C-Space>"] = cmp.mapping.complete(), -- trigger completion manually
          ["<CR>"]      = cmp.mapping.confirm({ select = true }),
          ["<Tab>"]     = cmp.mapping.select_next_item(),
          ["<S-Tab>"]   = cmp.mapping.select_prev_item(),
          ["<C-e>"]     = cmp.mapping.abort(),
          -- Scroll docs in the detail window without leaving insert mode
          ["<C-d>"]     = cmp.mapping.scroll_docs(4),
          ["<C-u>"]     = cmp.mapping.scroll_docs(-4),
        }),
        sources = cmp.config.sources({
          { name = "nvim_lsp" },                  -- LSP completions
          { name = "nvim_lsp_signature_help" },   -- function signature hints
          { name = "snippets" },                  -- vim.snippet snippets
          { name = "buffer" },                    -- words from current buffer
          { name = "path" },                      -- filesystem paths
        }),
      })
    end,
  },
})

-- ============================================================
-- APPEARANCE
-- ============================================================
-- apply_palette() reads the current palette module and re-applies every
-- highlight group that depends on it.  Called once at startup and again by
-- sync.watch_palette() whenever palette.lua is saved — giving instant
-- hot-reload without restarting aid.
function _G.apply_palette()
  -- Bust the module cache so require() picks up the saved file, not the old table.
  package.loaded["palette"] = nil
  local ok, fresh = pcall(require, "palette")
  if not ok then
    vim.notify("palette.lua error: " .. tostring(fresh), vim.log.levels.ERROR)
    return
  end
  p = fresh -- update the module-level variable used by setup_statusline()

  vim.api.nvim_set_hl(0, "Normal", { bg = p.none })
  vim.api.nvim_set_hl(0, "NormalFloat", { bg = p.none })
  vim.api.nvim_set_hl(0, "GitSignsAdd", { fg = p.git_add })
  vim.api.nvim_set_hl(0, "GitSignsDelete", { fg = p.git_del })
  vim.api.nvim_set_hl(0, "GitSignsDeleteLn", { bg = p.git_del_ln })
  vim.api.nvim_set_hl(0, "GitSignsChange", { fg = p.git_chg })
  vim.api.nvim_set_hl(0, "GitSignsChangeLn", { bg = p.git_chg_ln })
  vim.api.nvim_set_hl(0, "NvimTreeGitDirtyIcon", { fg = p.git_dot })
  vim.api.nvim_set_hl(0, "NvimTreeGitStagedIcon", { fg = p.git_dot })
  vim.api.nvim_set_hl(0, "Cursor", { fg = p.cursor_fg, bg = p.purple })
  vim.api.nvim_set_hl(0, "MiniStatuslineDevinfo", { fg = p.fg, bg = p.blue })
  vim.api.nvim_set_hl(0, "MiniStatuslineFilename", { fg = p.fg, bg = p.lavender })
  vim.api.nvim_set_hl(0, "MiniStatuslineFileinfo", { fg = p.fg, bg = p.blue })
  vim.api.nvim_set_hl(0, "MiniStatuslineInactive", { fg = p.fg, bg = p.lavender })
  vim.api.nvim_set_hl(0, "StatusSepDevinfoToFilename", { fg = p.blue, bg = p.lavender })
  vim.opt.guicursor = "n-v-c:block-Cursor,i-ci-ve:ver25-Cursor"

  -- Re-apply bufferline highlights from updated palette.
  -- bufferline.nvim exposes no runtime highlight update API, but overwriting
  -- the highlight groups directly takes effect immediately on the next redraw.
  local hl = vim.api.nvim_set_hl
  hl(0, "BufferLineFill", { bg = p.tab_bg })
  hl(0, "BufferLineBackground", { fg = p.tab_fg, bg = p.tab_bg })
  hl(0, "BufferLineTab", { fg = p.tab_fg, bg = p.tab_bg })
  hl(0, "BufferLineTabSelected", { fg = p.tab_fg, bg = p.tab_sel, bold = true })
  hl(0, "BufferLineTabSeparator", { fg = p.tab_bg, bg = p.tab_bg })
  hl(0, "BufferLineTabSeparatorSelected", { fg = p.tab_sel, bg = p.tab_sel })
  hl(0, "BufferLineTabClose", { fg = p.tab_fg, bg = p.tab_bg })
  hl(0, "BufferLineSeparator", { fg = p.tab_bg, bg = p.tab_bg })
  hl(0, "BufferLineSeparatorSelected", { fg = p.tab_sel, bg = p.tab_sel })
  hl(0, "BufferLineSeparatorVisible", { fg = p.tab_bg, bg = p.tab_bg })
  -- nocombine: prevents LSP/treesitter semantic tokens from bleeding their
  -- fg color over the buffer name text in the tab bar (BUG-021).
  hl(0, "BufferLineBufferSelected", { fg = p.tab_fg, bg = p.tab_sel, bold = true, nocombine = true })
  hl(0, "BufferLineBufferVisible", { fg = p.tab_fg, bg = p.tab_bg, nocombine = true })
  hl(0, "BufferLineCloseButton", { fg = p.tab_fg, bg = p.tab_bg })
  hl(0, "BufferLineCloseButtonSelected", { fg = p.tab_fg, bg = p.tab_sel })
  hl(0, "BufferLineCloseButtonVisible", { fg = p.tab_fg, bg = p.tab_bg })
  hl(0, "BufferLineModified", { fg = p.tab_fg, bg = p.tab_bg })
  hl(0, "BufferLineModifiedSelected", { fg = p.tab_fg, bg = p.tab_sel })
  hl(0, "BufferLineModifiedVisible", { fg = p.tab_fg, bg = p.tab_bg })
  hl(0, "BufferLineDuplicate", { fg = p.tab_fg, bg = p.tab_bg })
  hl(0, "BufferLineDuplicateSelected", { fg = p.tab_fg, bg = p.tab_sel })
  hl(0, "BufferLineDuplicateVisible", { fg = p.tab_fg, bg = p.tab_bg })
  hl(0, "BufferLineIndicatorSelected", { fg = p.tab_sel, bg = p.tab_sel })
  hl(0, "BufferLineIndicatorVisible", { fg = p.tab_bg, bg = p.tab_bg })
  hl(0, "BufferLineNumbers", { fg = p.tab_fg, bg = p.tab_bg })
  hl(0, "BufferLineNumbersSelected", { fg = p.tab_fg, bg = p.tab_sel })
  hl(0, "BufferLineNumbersVisible", { fg = p.tab_fg, bg = p.tab_bg })
  hl(0, "BufferLineDiagnostic", { fg = p.tab_fg, bg = p.tab_bg })
  hl(0, "BufferLineDiagnosticSelected", { fg = p.tab_fg, bg = p.tab_sel })
  hl(0, "BufferLineDiagnosticVisible", { fg = p.tab_fg, bg = p.tab_bg })
  -- Per-severity: prevents LSP diagnostic colors tinting the buffer name (BUG-021)
  hl(0, "BufferLineError", { fg = p.tab_fg, bg = p.tab_bg })
  hl(0, "BufferLineErrorSelected", { fg = p.tab_fg, bg = p.tab_sel, bold = true, nocombine = true })
  hl(0, "BufferLineErrorVisible", { fg = p.tab_fg, bg = p.tab_bg })
  hl(0, "BufferLineErrorDiagnostic", { fg = p.tab_fg, bg = p.tab_bg })
  hl(0, "BufferLineErrorDiagnosticSelected", { fg = p.tab_fg, bg = p.tab_sel })
  hl(0, "BufferLineErrorDiagnosticVisible", { fg = p.tab_fg, bg = p.tab_bg })
  hl(0, "BufferLineWarning", { fg = p.tab_fg, bg = p.tab_bg })
  hl(0, "BufferLineWarningSelected", { fg = p.tab_fg, bg = p.tab_sel, bold = true, nocombine = true })
  hl(0, "BufferLineWarningVisible", { fg = p.tab_fg, bg = p.tab_bg })
  hl(0, "BufferLineWarningDiagnostic", { fg = p.tab_fg, bg = p.tab_bg })
  hl(0, "BufferLineWarningDiagnosticSelected", { fg = p.tab_fg, bg = p.tab_sel })
  hl(0, "BufferLineWarningDiagnosticVisible", { fg = p.tab_fg, bg = p.tab_bg })
  hl(0, "BufferLineInfo", { fg = p.tab_fg, bg = p.tab_bg })
  hl(0, "BufferLineInfoSelected", { fg = p.tab_fg, bg = p.tab_sel, bold = true, nocombine = true })
  hl(0, "BufferLineInfoVisible", { fg = p.tab_fg, bg = p.tab_bg })
  hl(0, "BufferLineInfoDiagnostic", { fg = p.tab_fg, bg = p.tab_bg })
  hl(0, "BufferLineInfoDiagnosticSelected", { fg = p.tab_fg, bg = p.tab_sel })
  hl(0, "BufferLineInfoDiagnosticVisible", { fg = p.tab_fg, bg = p.tab_bg })
  hl(0, "BufferLineHint", { fg = p.tab_fg, bg = p.tab_bg })
  hl(0, "BufferLineHintSelected", { fg = p.tab_fg, bg = p.tab_sel, bold = true, nocombine = true })
  hl(0, "BufferLineHintVisible", { fg = p.tab_fg, bg = p.tab_bg })
  hl(0, "BufferLineHintDiagnostic", { fg = p.tab_fg, bg = p.tab_bg })
  hl(0, "BufferLineHintDiagnosticSelected", { fg = p.tab_fg, bg = p.tab_sel })
  hl(0, "BufferLineHintDiagnosticVisible", { fg = p.tab_fg, bg = p.tab_bg })
  hl(0, "BufferLineTruncMarker", { fg = p.tab_fg, bg = p.tab_bg })
  hl(0, "BufferLineOffsetSeparator", { fg = p.tab_bg, bg = p.tab_bg })

  vim.cmd("redrawtabline")
end

-- Apply on startup
apply_palette()

-- ============================================================
-- DIAGNOSTICS
-- ============================================================
vim.diagnostic.config({
  signs = {
    text = {
      [vim.diagnostic.severity.ERROR] = "󰅖",
      [vim.diagnostic.severity.WARN] = "󰀪",
      [vim.diagnostic.severity.INFO] = "󰋽",
      [vim.diagnostic.severity.HINT] = "󰌶",
    },
  },
  virtual_text = true,
  underline = true,
  update_in_insert = false,
})

-- ============================================================
-- AUTOCMDS
-- ============================================================

-- Enable word wrap for prose filetypes (spell off by default, toggle with <leader>sS)
vim.api.nvim_create_autocmd("FileType", {
  pattern = { "markdown", "text", "gitcommit" },
  callback = function()
    vim.opt_local.wrap = true
    vim.opt_local.linebreak = true
    vim.opt_local.spell = false
  end,
})

-- Git-sync: full refresh (gitsigns + nvim-tree + treemux) when nvim regains
-- focus or a terminal buffer (e.g. lazygit float) closes — these events
-- signal that external state (git, filesystem) may have changed.
vim.api.nvim_create_autocmd({ "FocusGained" }, {
  pattern = "*",
  callback = function()
    sync.sync()
  end,
})

-- Also fire when a terminal buffer closes (catches lazygit float exit directly)
vim.api.nvim_create_autocmd("TermClose", {
  pattern = "*",
  callback = function()
    sync.sync()
  end,
})

-- Lightweight checktime only on high-frequency events — avoids constant
-- sign-column redraws (gitsigns/nvim-tree) that cause line-number flicker.
-- checktime is sufficient here: it reloads buffers edited externally (e.g.
-- by opencode) without triggering a full git-state repaint.
vim.api.nvim_create_autocmd({ "BufEnter", "CursorHold", "CursorHoldI" }, {
  pattern = "*",
  callback = function()
    sync.checktime()
  end,
})

-- Bust aidignore cache and restart file watcher when cwd changes so
-- nvim-tree + Telescope pick up the correct .aidignore for the new directory.
vim.api.nvim_create_autocmd("DirChanged", {
  pattern = "*",
  callback = function()
    require("aidignore").reset()
  end,
})

-- On startup: open nvim-tree (outside tmux only) and show cheatsheet on empty buffer.
-- This autocmd lives here (not inside nvim-tree's config) so it is registered
-- before VimEnter fires regardless of when nvim-tree's lazy load triggers.
vim.api.nvim_create_autocmd("VimEnter", {
  callback = function(data)
    local is_file = vim.fn.filereadable(data.file) == 1
    local is_empty = data.file == "" and vim.bo[data.buf].buftype == ""
    if (is_file or is_empty) and not vim.o.diff then
      -- Outside tmux: use nvim-tree directly (in tmux, treemux sidebar is
      -- opened by aid.sh via run-shell before nvim starts)
      if not vim.env.TMUX or vim.env.TMUX == "" then
        require("nvim-tree.api").tree.toggle({ focus = false, find_file = true })
      end
    end
    -- Open cheatsheet when launched with no file (empty buffer = fresh/restarted aid session)
    if is_empty and not vim.o.diff then
      vim.schedule(_cs_open)
    end
    -- Watch the current buffer's directory for external edits (e.g. opencode).
    -- BufEnter handles subsequent file opens; VimLeave cleans up all handles.
    sync.watch_buf(data.buf)
    -- Watch palette.lua so saving it hot-reloads all colors without restarting.
    -- Registered once here; idempotent (watch_palette() stops any prior handle).
    sync.watch_palette()
  end,
})

-- Watch each buffer's directory as it's entered, so opencode edits to any
-- open file are picked up immediately without requiring a pane switch.
vim.api.nvim_create_autocmd("BufEnter", {
  callback = function(ev)
    sync.watch_buf(ev.buf)
  end,
})

-- Clean up all fs_event handles on exit to avoid libuv handle leak warnings.
vim.api.nvim_create_autocmd("VimLeave", {
  callback = function()
    sync.stop_watchers()
  end,
})

-- Re-apply palette after any event that can reset highlight groups.
-- ColorScheme fires when a colorscheme is loaded/reloaded and wipes all hl groups.
-- LspAttach is intentionally NOT used here — it fires per-buffer during the LSP
-- attach sequence and calling apply_palette() mid-attach disrupts LSP startup.
-- Instead, a one-time deferred call after VimEnter covers the post-startup window
-- where LSP servers first attach and can overwrite hl groups (BUG-021).
vim.api.nvim_create_autocmd("ColorScheme", {
  desc = "BUG-021: re-apply palette after colorscheme resets hl groups",
  callback = function()
    apply_palette()
  end,
})
vim.api.nvim_create_autocmd("VimEnter", {
  once = true,
  desc = "BUG-021: re-apply palette once after all plugins and LSP servers have initialised",
  callback = function()
    vim.defer_fn(apply_palette, 500)
  end,
})
