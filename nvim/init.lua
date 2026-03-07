-- ============================================================
-- LEADER KEY
-- ============================================================
vim.g.mapleader = " "

-- Disable netrw before any plugin loads — nvim-tree handles all file/dir
-- browsing; netrw must not hijack directory opens or VimEnter.
vim.g.loaded_netrw       = 1
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
-- GIT-SYNC COORDINATOR
-- ============================================================
-- Central module that refreshes all git-aware components after an external
-- git operation (branch switch, pull, stash pop). See nvim/sync.lua.
local sync = require("sync")

-- ============================================================
-- CHEATSHEET
-- ============================================================
-- Opens nvim/cheatsheet.md as a normal file buffer on startup. Re-open: <leader>?
local _cs_path = vim.fn.stdpath("config") .. "/cheatsheet.md"

local function _cs_open()
  vim.cmd("edit " .. vim.fn.fnameescape(_cs_path))
end

-- <leader>? — reopen cheatsheet any time
vim.keymap.set("n", "<leader>?", _cs_open, { desc = "Open cheatsheet" })

-- ============================================================
-- BOOTSTRAP LAZY.NVIM
-- ============================================================
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.loop.fs_stat(lazypath) then
  vim.fn.system({ "git", "clone", "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git", lazypath })
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
  local f = io.open(_bm_file, "r"); if not f then return {} end
  local t = {}
  for l in f:lines() do if l ~= "" then table.insert(t, l) end end
  f:close(); return t
end
local function _bm_write(t)
  local f = io.open(_bm_file, "w"); if not f then return end
  for _, p in ipairs(t) do f:write(p .. "\n") end; f:close()
end
-- Returns the most meaningful path: real file buffer → its path; otherwise → cwd
local function _bm_current()
  local p = vim.fn.expand("%:p")
  if p ~= "" and vim.fn.filereadable(p) == 1 then return p end
  return vim.fn.getcwd()
end
local function _bm_open_picker()
  local t = _bm_read(); if #t == 0 then vim.notify("No bookmarks"); return end
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  require("telescope.pickers").new({}, {
    prompt_title = "Bookmarks",
    finder = require("telescope.finders").new_table({
      results = t,
      entry_maker = function(p)
        local is_dir = vim.fn.isdirectory(p) == 1
        local icon = is_dir and " " or " "
        return { value = p, display = icon .. vim.fn.fnamemodify(p, ":~"), ordinal = p, path = p }
      end,
    }),
    previewer = conf.file_previewer({}),
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr)
      actions.select_default:replace(function()
        actions.close(prompt_bufnr)
        local entry = action_state.get_selected_entry()
        if not entry then return end
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
  }):find()
end
vim.keymap.set("n", "<leader>ba", function()
  local p = _bm_current()
  local t = _bm_read()
  for _, v in ipairs(t) do if v == p then vim.notify("Already bookmarked"); return end end
  table.insert(t, p); _bm_write(t)
  local label = vim.fn.isdirectory(p) == 1 and "Dir" or "File"
  vim.notify(label .. " bookmarked: " .. vim.fn.fnamemodify(p, ":~"))
end, { desc = "Bookmark: add file or dir" })
vim.keymap.set("n", "<leader>bd", function()
  local p = _bm_current(); local t = _bm_read(); local new = {}; local removed = false
  for _, v in ipairs(t) do if v ~= p then table.insert(new, v) else removed = true end end
  if removed then _bm_write(new); vim.notify("Bookmark removed") else vim.notify("Not bookmarked") end
end, { desc = "Bookmark: remove file or dir" })
vim.keymap.set("n", "<leader>bb", _bm_open_picker, { desc = "Bookmark: open file or dir" })

-- <leader>f — fuzzy find files with Telescope
vim.keymap.set("n", "<leader>f", "<cmd>Telescope find_files<cr>", { desc = "Find files" })
-- <leader>1 — search text across all files | <leader>2 — switch open buffers
vim.keymap.set("n", "<leader>1", "<cmd>Telescope live_grep<cr>",  { desc = "Search in files" })
vim.keymap.set("n", "<leader>2", "<cmd>Telescope buffers<cr>",    { desc = "Open buffers" })

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
vim.keymap.set("n", "<leader>7", vim.diagnostic.goto_next, { desc = "Next diagnostic" })
vim.keymap.set("n", "<leader>8", vim.diagnostic.goto_prev, { desc = "Prev diagnostic" })
vim.keymap.set("n", "<leader>9", vim.diagnostic.open_float, { desc = "Show diagnostic" })

-- Spell
-- <leader>sS — toggle spell (en) | <leader>se — English | <leader>sd — German | <leader>sn — off
vim.keymap.set("n", "<leader>sS", function()
  local on = not vim.opt_local.spell:get()
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
        local git        = sl.section_git({ trunc_width = 75 })
        local diag       = sl.section_diagnostics({ trunc_width = 75 })
        local filename   = sl.section_filename({ trunc_width = 140 })
        local fileinfo   = sl.section_fileinfo({ trunc_width = 120 })
        local location   = sl.section_location({ trunc_width = 75 })

        -- Dynamic separator colors based on current mode highlight
        local ok, minfo = pcall(vim.api.nvim_get_hl, 0, { name = mode_hl, link = false })
        local mode_bg = (ok and minfo.bg) and string.format("#%06x", minfo.bg) or "#b57bee"
        vim.api.nvim_set_hl(0, "StatusSepModeToDevinfo",  { fg = mode_bg,   bg = "#6181C6" })
        vim.api.nvim_set_hl(0, "StatusSepFileinfoToMode", { fg = "#6181C6", bg = mode_bg   })

        local arrow = "\xee\x82\xb0" -- U+E0B0 Powerline right arrow 
        local sep = function(hl) return string.format("%%#%s#%s", hl, arrow) end

        return sl.combine_groups({
          { hl = mode_hl,                  strings = { mode } },
          sep("StatusSepModeToDevinfo"),
          { hl = "MiniStatuslineDevinfo",  strings = { git, diag } },
          sep("StatusSepDevinfoToFilename"),
          "%<",
          { hl = "MiniStatuslineFilename", strings = { filename } },
          "%=",
          { hl = "MiniStatuslineFileinfo", strings = { fileinfo } },
          sep("StatusSepFileinfoToMode"),
          { hl = mode_hl,                  strings = { location } },
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
      filters = { dotfiles = false, git_ignored = false },  -- show hidden and git-ignored files
    },
    keys = {
      { "<leader>t",  "<cmd>NvimTreeToggle<cr>",   desc = "Toggle file tree" },
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
          local p = _bm_current()
          local t = _bm_read()
          for _, v in ipairs(t) do if v == p then vim.notify("Already bookmarked"); return end end
          table.insert(t, p); _bm_write(t)
          local label = vim.fn.isdirectory(p) == 1 and "Dir" or "File"
          vim.notify(label .. " bookmarked: " .. vim.fn.fnamemodify(p, ":~"))
        end)
        map("<leader>bd", "Bookmark: remove cwd", function()
          local p = _bm_current(); local t = _bm_read(); local new = {}; local removed = false
          for _, v in ipairs(t) do if v ~= p then table.insert(new, v) else removed = true end end
          if removed then _bm_write(new); vim.notify("Bookmark removed") else vim.notify("Not bookmarked") end
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
        add    = { text = "▎" },
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
      },
      highlights = {
        fill                      = { bg = "#C88E6B" },
        background                = { fg = "#ffffff", bg = "#C88E6B" },
        tab                       = { fg = "#ffffff", bg = "#C88E6B" },
        tab_selected              = { fg = "#ffffff", bg = "#a06a45", bold = true },
        tab_separator             = { fg = "#C88E6B", bg = "#C88E6B" },
        tab_separator_selected    = { fg = "#a06a45", bg = "#a06a45" },
        tab_close                 = { fg = "#ffffff", bg = "#C88E6B" },
        separator                 = { fg = "#C88E6B", bg = "#C88E6B" },
        separator_selected        = { fg = "#a06a45", bg = "#a06a45" },
        separator_visible         = { fg = "#C88E6B", bg = "#C88E6B" },
        buffer_selected           = { fg = "#ffffff", bg = "#a06a45", bold = true },
        buffer_visible            = { fg = "#ffffff", bg = "#C88E6B" },
        close_button              = { fg = "#ffffff", bg = "#C88E6B" },
        close_button_selected     = { fg = "#ffffff", bg = "#a06a45" },
        close_button_visible      = { fg = "#ffffff", bg = "#C88E6B" },
        modified                  = { fg = "#ffffff", bg = "#C88E6B" },
        modified_selected         = { fg = "#ffffff", bg = "#a06a45" },
        modified_visible          = { fg = "#ffffff", bg = "#C88E6B" },
        duplicate                 = { fg = "#ffffff", bg = "#C88E6B" },
        duplicate_selected        = { fg = "#ffffff", bg = "#a06a45" },
        duplicate_visible         = { fg = "#ffffff", bg = "#C88E6B" },
        indicator_selected        = { fg = "#a06a45", bg = "#a06a45" },
        indicator_visible         = { fg = "#C88E6B", bg = "#C88E6B" },
        numbers                   = { fg = "#ffffff", bg = "#C88E6B" },
        numbers_selected          = { fg = "#ffffff", bg = "#a06a45" },
        numbers_visible           = { fg = "#ffffff", bg = "#C88E6B" },
        diagnostic                = { fg = "#ffffff", bg = "#C88E6B" },
        diagnostic_selected       = { fg = "#ffffff", bg = "#a06a45" },
        diagnostic_visible        = { fg = "#ffffff", bg = "#C88E6B" },
        trunc_marker              = { fg = "#ffffff", bg = "#C88E6B" },
        offset_separator          = { fg = "#C88E6B", bg = "#C88E6B" },
      },
    },
    keys = {
      { "<Tab>",       "<cmd>BufferLineCycleNext<cr>", desc = "Next tab" },
      { "<S-Tab>",     "<cmd>BufferLineCyclePrev<cr>", desc = "Prev tab" },
      { "<leader>q",   "<cmd>bdelete<cr>",             desc = "Close tab" },
      { "<leader>tb",  function()
          vim.o.showtabline = vim.o.showtabline == 2 and 1 or 2
        end, desc = "Toggle tab bar" },
    },
    config = function(_, opts)
      require("bufferline").setup(opts)
      -- Force a tabline redraw so bufferline renders immediately on startup
      -- without requiring a keypress (Tab) to trigger the first render.
      -- defer_fn gives the UI time to fully initialise before redrawing.
      vim.defer_fn(function() vim.cmd("redrawtabline") end, 50)
    end,
  },

  -- Fuzzy finder
  {
    "nvim-telescope/telescope.nvim",
    dependencies = { "nvim-lua/plenary.nvim" },
    opts = {
      pickers = {
        find_files = { hidden = true, no_ignore_vcs = true, follow = true },
        live_grep  = { additional_args = { "--hidden", "--no-ignore-vcs", "--glob", "!**/.git/*" } },
      },
    },
    config = function(_, opts)
      -- Merge .aidignore patterns into defaults.file_ignore_patterns
      local aidignore = require("aidignore")
      local base = { "^%.git[/\\]" }
      for _, p in ipairs(aidignore.patterns().telescope) do
        table.insert(base, p)
      end
      opts.defaults = opts.defaults or {}
      opts.defaults.file_ignore_patterns = base
      require("telescope").setup(opts)
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
                return dir, stat.type  -- "file" = worktree, "directory" = normal repo
              end
              local parent = vim.fn.fnamemodify(dir, ":h")
              if parent == dir then break end
              dir = parent
            end
            return nil, nil
          end

          local buf_dir = vim.fn.expand("%:p:h")
          if buf_dir == "" then buf_dir = vim.fn.getcwd() end

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
              git_dir = vim.fn.system("git -C " .. vim.fn.shellescape(work_tree) .. " rev-parse --git-dir"):gsub("%s+$", "")
              if vim.v.shell_error ~= 0 then git_dir = nil end
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
  { "echasnovski/mini.pairs",      opts = {} },
  { "echasnovski/mini.cursorword", opts = {} },

  -- Session save/restore (per working directory, auto-saves on exit)
  {
    "folke/persistence.nvim",
    event = "BufReadPre",
    opts = {},
    keys = {
      { "<leader>sl", function() require("persistence").load({ last = true }) end, desc = "Restore last session" },
      { "<leader>ss", function() require("persistence").load() end,               desc = "Restore session for cwd" },
      { "<leader>sd", function() require("persistence").stop() end,               desc = "Don't save session on exit" },
    },
  },

  -- Statusline content provider (hidden via laststatus=0, piped to tmux by tpipeline)
  {
    "echasnovski/mini.statusline",
    config = function() _G.setup_statusline() end,
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
    build = "cd app && npm install",
    ft = { "markdown" },
    keys = {
      { "<leader>mp", function()
          vim.cmd("MarkdownPreview")
          vim.fn.jobstart({ "notify-send", "Markdown Preview", "Preview opened" })
        end, desc = "Markdown preview open" },
      { "<leader>ms", function()
          vim.cmd("MarkdownPreviewStop")
          vim.fn.jobstart({ "notify-send", "Markdown Preview", "Preview stopped" })
        end, desc = "Markdown preview stop" },
    },
  },

  -- Syntax highlighting
  {
    "nvim-treesitter/nvim-treesitter",
    build = ":TSUpdate",
    config = function()
      require("nvim-treesitter.config").setup({
        ensure_installed = {
          "lua", "python", "bash", "json", "jsonc", "toml", "yaml", "ini",
          "css", "markdown", "markdown_inline", "go",
        },
        auto_install = true,
        highlight = { enable = true },
        indent = { enable = true },
      })
    end,
  },

  -- LSP
  {
    "neovim/nvim-lspconfig",
    config = function()
      local capabilities = require("cmp_nvim_lsp").default_capabilities()

      -- Add language servers here as needed, e.g.:
      -- vim.lsp.config('lua_ls',   { capabilities = capabilities })
      -- vim.lsp.config('pyright',  { capabilities = capabilities })
      -- vim.lsp.config('bashls',   { capabilities = capabilities })
      vim.lsp.config('gopls', { capabilities = capabilities })
      vim.lsp.enable('gopls')

      -- Keymaps available when LSP attaches to a buffer
      vim.api.nvim_create_autocmd("LspAttach", {
        callback = function(event)
          local opts = { buffer = event.buf }
          vim.keymap.set("n", "gd", vim.lsp.buf.definition, opts)
          vim.keymap.set("n", "K",  vim.lsp.buf.hover, opts)
          vim.keymap.set("n", "<leader>rn", vim.lsp.buf.rename, opts)
          vim.keymap.set("n", "<leader>ca", vim.lsp.buf.code_action, opts)
          vim.keymap.set("n", "gr", vim.lsp.buf.references, opts)
        end,
      })
    end,
  },

  -- Autocompletion
  {
    "hrsh7th/nvim-cmp",
    dependencies = {
      "hrsh7th/cmp-nvim-lsp",
      "hrsh7th/cmp-buffer",
      "hrsh7th/cmp-path",
    },
    config = function()
      local cmp = require("cmp")
      cmp.setup({
        mapping = cmp.mapping.preset.insert({
          ["<C-Space>"] = cmp.mapping.complete(),  -- trigger completion manually
          ["<CR>"]      = cmp.mapping.confirm({ select = true }),
          ["<Tab>"]     = cmp.mapping.select_next_item(),
          ["<S-Tab>"]   = cmp.mapping.select_prev_item(),
          ["<C-e>"]     = cmp.mapping.abort(),
        }),
        sources = cmp.config.sources({
          { name = "nvim_lsp" },  -- LSP suggestions
          { name = "buffer" },    -- words from current buffer
          { name = "path" },      -- filesystem paths
        }),
      })
    end,
  },
})




-- ============================================================
-- APPEARANCE
-- ============================================================
vim.api.nvim_set_hl(0, "Normal", { bg = "none" })
vim.api.nvim_set_hl(0, "NormalFloat", { bg = "none" })
vim.api.nvim_set_hl(0, "GitSignsDelete",   { fg = "#ff5555" })
vim.api.nvim_set_hl(0, "GitSignsDeleteLn", { bg = "#3d1a1a" })
vim.api.nvim_set_hl(0, "GitSignsChange",   { fg = "#ffaa00" })
vim.api.nvim_set_hl(0, "GitSignsChangeLn", { bg = "#3d2a00" })
vim.api.nvim_set_hl(0, "Cursor", { fg = "#000000", bg = "#b57bee" })
vim.api.nvim_set_hl(0, "MiniStatuslineDevinfo",  { fg = "#ffffff", bg = "#6181C6" })
vim.api.nvim_set_hl(0, "MiniStatuslineFilename",  { fg = "#ffffff", bg = "#A284C6" })
vim.api.nvim_set_hl(0, "MiniStatuslineFileinfo",  { fg = "#ffffff", bg = "#6181C6" })
vim.api.nvim_set_hl(0, "MiniStatuslineInactive",  { fg = "#ffffff", bg = "#A284C6" })
vim.api.nvim_set_hl(0, "StatusSepDevinfoToFilename", { fg = "#6181C6", bg = "#A284C6" })
vim.opt.guicursor = "n-v-c:block-Cursor,i-ci-ve:ver25-Cursor"

-- ============================================================
-- DIAGNOSTICS
-- ============================================================
vim.diagnostic.config({
  signs = {
    text = {
      [vim.diagnostic.severity.ERROR] = "󰅖",
      [vim.diagnostic.severity.WARN]  = "󰀪",
      [vim.diagnostic.severity.INFO]  = "󰋽",
      [vim.diagnostic.severity.HINT]  = "󰌶",
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

-- Git-sync: refresh all git-aware components when nvim regains focus
-- or when a terminal buffer (e.g. lazygit float) closes.
vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter", "CursorHold", "CursorHoldI" }, {
  pattern = "*",
  callback = function() sync.sync() end,
})

-- Also fire when a terminal buffer closes (catches lazygit float exit directly)
vim.api.nvim_create_autocmd("TermClose", {
  pattern = "*",
  callback = function() sync.sync() end,
})

-- Bust aidignore cache and restart file watcher when cwd changes so
-- nvim-tree + Telescope pick up the correct .aidignore for the new directory.
vim.api.nvim_create_autocmd("DirChanged", {
  pattern = "*",
  callback = function() require("aidignore").reset() end,
})

-- On startup: open nvim-tree (outside tmux only) and show cheatsheet on empty buffer.
-- This autocmd lives here (not inside nvim-tree's config) so it is registered
-- before VimEnter fires regardless of when nvim-tree's lazy load triggers.
vim.api.nvim_create_autocmd("VimEnter", {
  callback = function(data)
    local is_file  = vim.fn.filereadable(data.file) == 1
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
  end,
})

