-- Even if your gitconfig redirects https to ssh (url insteadOf), this will make sure that
-- plugins will be installed via https instead of ssh.
vim.env.GIT_CONFIG_GLOBAL = ""

-- Point nvim-tree-remote at the editor nvim's socket.
-- aid.sh stores the socket path in the tmux server environment as TDL_NVIM_SOCKET
-- (e.g. /tmp/tdl-nvim-nvim@myproject.sock) and the editor nvim is launched with
-- `nvim --listen <that path>`. Setting this global bypasses the auto-detection in
-- tmux_current_window_nvim_addr.sh, which only works when the socket filename
-- contains the nvim PID — something a fixed/predictable path won't satisfy.
vim.g.nvim_tree_remote_socket_path = os.getenv("TDL_NVIM_SOCKET") or ""

-- Remove the white status bar below
vim.o.laststatus = 0

-- True colour support
vim.o.termguicolors = true

-- lazy.nvim plugin manager
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.loop.fs_stat(lazypath) then
  vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git",
    "--branch=stable", -- latest stable release
    lazypath,
  })
end
vim.opt.rtp:prepend(lazypath)

local function nvim_tree_on_attach(bufnr)
  local api = require("nvim-tree.api")
  local nt_remote = require("nvim_tree_remote")

  local function opts(desc)
    return { desc = "nvim-tree: " .. desc, buffer = bufnr, noremap = true, silent = true, nowait = true }
  end

  -- nvim_tree_remote checks node.type == "file" and falls back to local open for symlinks
  -- (type == "link"). Wrap tabnew to force symlinks through the remote path via absolute_path.
  -- The editor pane always runs nvim (aid.sh uses a restart loop), so the socket at
  -- TDL_NVIM_SOCKET is always live. The fallback split in nvim_tree_remote is disabled
  -- (pane = nil) so a dead socket produces a clear error instead of a rogue new pane.
  local function tabnew_follow_symlinks()
    local node = api.tree.get_node_under_cursor()
    if node and (node.type == "file" or node.type == "link") then
      local socket_path = vim.g.nvim_tree_remote_socket_path
      local tmux_opts = nt_remote.tmux_defaults()
      tmux_opts.pane = nil  -- never create a new split; error if socket unreachable
      require("nvim_tree_remote").remote_nvim_open(socket_path, "tabnew", node.absolute_path, tmux_opts)
    else
      nt_remote.tabnew()
    end
  end

  api.config.mappings.default_on_attach(bufnr)

  vim.keymap.set("n", "u", api.tree.change_root_to_node, opts("Dir up"))
  vim.keymap.set("n", "<F1>", api.node.show_info_popup, opts("Show info popup"))
  vim.keymap.set("n", "l", tabnew_follow_symlinks, opts("Open in treemux"))
  vim.keymap.set("n", "<CR>", tabnew_follow_symlinks, opts("Open in treemux"))
  vim.keymap.set("n", "<C-t>", tabnew_follow_symlinks, opts("Open in treemux"))
  vim.keymap.set("n", "<2-LeftMouse>", tabnew_follow_symlinks, opts("Open in treemux"))
  vim.keymap.set("n", "h", api.tree.close, opts("Close node"))
  vim.keymap.set("n", "v", nt_remote.vsplit, opts("Vsplit in treemux"))
  vim.keymap.set("n", "<C-v>", nt_remote.vsplit, opts("Vsplit in treemux"))
  vim.keymap.set("n", "<C-x>", nt_remote.split, opts("Split in treemux"))
  vim.keymap.set("n", "o", nt_remote.tabnew_main_pane, opts("Open in treemux without tmux split"))

  vim.keymap.set("n", "-", "", { buffer = bufnr })
  vim.keymap.del("n", "-", { buffer = bufnr })
  vim.keymap.set("n", "<C-k>", "", { buffer = bufnr })
  vim.keymap.del("n", "<C-k>", { buffer = bufnr })
  vim.keymap.set("n", "O", "", { buffer = bufnr })
  vim.keymap.del("n", "O", { buffer = bufnr })
end

require("lazy").setup({
  {
    "kiyoon/tmux-send.nvim",
    keys = {
      {
        "-",
        function()
          require("tmux_send").send_to_pane()
          -- (Optional) exit visual mode after sending
          vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<esc>", true, false, true), "x", true)
        end,
        mode = { "n", "x" },
        desc = "Send to tmux pane",
      },
      {
        "_",
        function()
          require("tmux_send").send_to_pane({ add_newline = false })
          -- (Optional) exit visual mode after sending
          vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<esc>", true, false, true), "x", true)
        end,
        mode = { "n", "x" },
        desc = "Send to tmux pane (plain)",
      },
      {
        "<space>-",
        function()
          require("tmux_send").send_to_pane({ count_is_uid = true })
          vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<esc>", true, false, true), "x", true)
        end,
        mode = { "n", "x" },
        desc = "Send to tmux pane w/ pane uid",
      },
      {
        "<space>_",
        function()
          require("tmux_send").send_to_pane({ count_is_uid = true, add_newline = false })
          vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<esc>", true, false, true), "x", true)
        end,
        mode = { "n", "x" },
        desc = "Send to tmux pane w/ pane uid (plain)",
      },
      {
        "<C-_>",
        function()
          require("tmux_send").save_to_tmux_buffer()
          vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<esc>", true, false, true), "x", true)
        end,
        mode = { "n", "x" },
        desc = "Save to tmux buffer",
      },
    },
  },
  "kiyoon/nvim-tree-remote.nvim",
  "folke/tokyonight.nvim",
  "nvim-tree/nvim-web-devicons",
  {
    "nvim-tree/nvim-tree.lua",
    config = function()
      local nvim_tree = require("nvim-tree")

      nvim_tree.setup({
        on_attach = nvim_tree_on_attach,
        update_focused_file = {
          enable = true,
          update_cwd = true,
        },
        renderer = {
          --root_folder_modifier = ":t",
          icons = {
            glyphs = {
              default = "",
              symlink = "",
              folder = {
                arrow_open = "",
                arrow_closed = "",
                default = "",
                open = "",
                empty = "",
                empty_open = "",
                symlink = "",
                symlink_open = "",
              },
              git = {
                unstaged = "",
                staged = "S",
                unmerged = "",
                renamed = "➜",
                untracked = "U",
                deleted = "",
                ignored = "◌",
              },
            },
          },
        },
        diagnostics = {
          enable = true,
          show_on_dirs = true,
          icons = {
            hint = "",
            info = "",
            warning = "",
            error = "",
          },
        },
        view = {
          width = 30,
          side = "left",
        },
        filters = {
          -- Read TDL_IGNORE (comma-separated, set by aid.sh from .aidignore).
          -- Falls back to hiding just .git if not running inside aid.
          custom = (function()
            local t = { ".git" }
            local env = os.getenv("TDL_IGNORE") or ""
            for entry in env:gmatch("[^,]+") do
              entry = entry:match("^%s*(.-)%s*$")
              if entry ~= "" then table.insert(t, entry) end
            end
            return t
          end)(),
          dotfiles = false,
          git_ignored = false,
        },
      })
    end,
  },
  {
    "stevearc/oil.nvim",
    -- Bug with lazy-loading? Can't open nvim-tree on home directory and then open oil.
    -- https://github.com/stevearc/oil.nvim/issues/409
    -- Fixed by disabling lazy loading
    lazy = false,
    keys = {
      {
        "<space>o",
        function()
          -- Toggle oil / nvim-tree
          -- if nvim-tree is open, close it and open oil
          -- check filetype
          if vim.bo.filetype == "NvimTree" then
            vim.g.treemux_last_opened = "nvim-tree"
            local nt_api = require("nvim-tree.api")
            local node = nt_api.tree.get_node_under_cursor()
            vim.cmd("NvimTreeClose")
            if node.type == "file" then
              local dir = vim.fn.fnamemodify(node.absolute_path, ":h")
              require("oil").open(dir)
              -- TODO: focus on the file
            else
              require("oil").open(node.absolute_path)
            end
            -- vim.cmd("Oil")
          elseif vim.bo.filetype == "neo-tree" then
            vim.notify("This shouldn't be called here.", vim.log.levels.ERROR)
          elseif vim.bo.filetype == "oil" then
            if vim.g.treemux_last_opened == "nvim-tree" then
              -- if oil is open, close it and open nvim-tree
              vim.cmd("Oil close")
              require("nvim-tree.lib").open({ current_window = true })
            elseif vim.g.treemux_last_opened == "neo-tree" then
              -- if oil is open, close it
              vim.cmd("Oil close")
              vim.cmd("Neotree")
              -- BUG: neo-tree doesn't set filetype correctly
              vim.schedule(function()
                vim.bo.filetype = "neo-tree"
              end)
            end
          end
        end,
        mode = { "n" },
        desc = "Toggle Oil/nvim-tree",
      },
    },
    config = function()
      require("oil").setup({
        default_file_explorer = false,
        keymaps = {
          ["\\"] = { "actions.select", opts = { vertical = true }, desc = "Open the entry in a vertical split" },
          ["|"] = { "actions.select", opts = { horizontal = true }, desc = "Open the entry in a horizontal split" },
          ["<C-r>"] = "actions.refresh",
          ["g?"] = "actions.show_help",
          ["<CR>"] = "actions.select",
          ["<C-t>"] = { "actions.select", opts = { tab = true }, desc = "Open the entry in new tab" },
          ["<C-p>"] = "actions.preview",
          ["<C-c>"] = "actions.close",
          -- ["-"] = "actions.parent",
          -- ["_"] = "actions.open_cwd",
          ["U"] = "actions.parent",
          ["`"] = "actions.cd",
          ["~"] = { "actions.cd", opts = { scope = "tab" }, desc = ":tcd to the current oil directory" },
          ["gs"] = "actions.change_sort",
          ["gx"] = "actions.open_external",
          ["g."] = "actions.toggle_hidden",
          ["g\\"] = "actions.toggle_trash",
        },
        use_default_keymaps = false,
      })
    end,
  },
  {
    "nvim-neo-tree/neo-tree.nvim",
    branch = "v3.x",
    dependencies = {
      "nvim-lua/plenary.nvim",
      "nvim-tree/nvim-web-devicons", -- not strictly required, but recommended
      "MunifTanjim/nui.nvim",
    },
    cmd = "Neotree",
    keys = {
      { "<space>nn", "<cmd>Neotree toggle<CR>", mode = { "n", "x" }, desc = "[N]eotree toggle" },
    },
    lazy = false, -- neo-tree will lazily load itself
    config = function()
      require("neo-tree").setup({
        filesystem = {
          hijack_netrw_behavior = "disabled",
          window = {
            mappings = {
              ["<space>"] = "noop",
              ["<space>o"] = function(state)
                vim.g.treemux_last_opened = "neo-tree"
                local node = state.tree and state.tree:get_node()
                if not node then
                  return
                end
                -- close Neo-tree first
                vim.cmd("Neotree close")

                -- BUG: without vim.schedule, neo-tree fires file_open_requested event.
                vim.schedule(function()
                  if node.type == "file" then
                    local dir = vim.fn.fnamemodify(node.path, ":h")
                    require("oil").open(dir)
                  -- TODO: focus on the file
                  elseif node.type == "directory" then
                    require("oil").open(node.path)
                  elseif node.type == "message" then
                    -- e.g. (3 hidden items)
                    -- use the path of the parent directory
                    require("oil").open(node:get_parent_id())
                  else
                    -- use root path
                    require("oil").open(state.path)
                  end
                end)
                -- TODO: if you want to focus a specific file inside Oil,
                -- you'll need extra logic to move the cursor to that entry.
              end,
              ["q"] = "noop",
            },
          },
        },
        event_handlers = {
          {
            event = "file_open_requested",
            handler = function(args)
              local nt_remote = require("nvim_tree_remote")
              local tmux_opts = nt_remote.tmux_defaults()
              local open_cmd = args.open_cmd
              if args.open_cmd == "tabnew" then
                -- HACK: use "tabnew" as a command to open without tmux split
                -- the keybinding is `t`
                tmux_opts.split_position = ""
                open_cmd = "edit"
              end
              nt_remote.remote_nvim_open(nil, open_cmd, args.path, tmux_opts)

              -- stop default open; we already did it remotely
              return { handled = true }
            end,
          },
        },
      })
    end,
  },
  {
    -- without this, neo-tree often get blocked having "press ENTER to continue"
    "rcarriga/nvim-notify",
    event = "VeryLazy",
    keys = {
      {
        "<leader>un",
        function()
          require("notify").dismiss({ silent = true, pending = true })
        end,
        desc = "Delete all Notifications",
      },
    },
    opts = {
      stages = "fade_in_slide_out",
      -- stages = "slide",
      timeout = 3000,
      max_height = function()
        return math.floor(vim.o.lines * 0.75)
      end,
      max_width = function()
        return math.floor(vim.o.columns * 0.75)
      end,
    },
    config = function(_, opts)
      require("notify").setup(opts)
      vim.notify = require("notify")
    end,
  },
  {
    "aserowy/tmux.nvim",
    config = function()
      -- Navigate tmux, and nvim splits.
      -- Sync nvim buffer with tmux buffer.
      require("tmux").setup({
        copy_sync = {
          enable = true,
          sync_clipboard = false,
          sync_registers = true,
        },
        resize = {
          enable_default_keybindings = false,
        },
      })
    end,
  },
}, {
  performance = {
    rtp = {
      disabled_plugins = {
        -- List of default plugins can be found here
        -- https://github.com/neovim/neovim/tree/master/runtime/plugin
        "gzip",
        "matchit", -- Extended %. replaced by vim-matchup
        "matchparen", -- Highlight matching paren. replaced by vim-matchup
        "netrwPlugin", -- File browser. replaced by nvim-tree, neo-tree, oil.nvim
        "tarPlugin",
        "tohtml",
        "tutor",
        "zipPlugin",
      },
    },
  },
})

vim.cmd([[ colorscheme tokyonight-night ]])
vim.o.cursorline = true

-- Auto-focus tree root to current directory (hide parents)
vim.api.nvim_create_autocmd("DirChanged", {
  callback = function()
    require("nvim-tree.api").tree.change_root(vim.fn.getcwd())
  end,
})

-- Apply transparency after colorscheme (must be last)
vim.api.nvim_set_hl(0, "Normal",         { bg = "none" })
vim.api.nvim_set_hl(0, "NormalFloat",    { bg = "none" })
vim.api.nvim_set_hl(0, "NvimTreeNormal", { bg = "none" })
vim.api.nvim_set_hl(0, "NvimTreeNormalNC", { bg = "none" })
vim.api.nvim_set_hl(0, "NvimTreeEndOfBuffer", { bg = "none" })

-- ============================================================
-- TREEMUX SELF-HEAL
-- ============================================================
-- When the main nvim switches branches (via lazygit or CLI), files that
-- existed on the old branch may no longer exist on the new one. nvim-tree
-- holds stale git status for those paths and can crash on the next refresh.
--
-- Two autocmds guard against this:
--
-- FileChangedShell — fires when nvim detects that a file it has open was
--   modified/deleted externally (i.e. after a branch switch). We reload
--   silently (no "press ENTER" prompt) and rebuild the tree.
--
-- FileChangedShellPost — fires after the above; ensures the buffer content
--   is silently reloaded even if the file was deleted (edit! would fail, so
--   we catch the error with pcall).

vim.api.nvim_create_autocmd("FileChangedShell", {
  pattern = "*",
  callback = function()
    -- Suppress the default "file changed" prompt
    vim.v.fcs_choice = "reload"
    -- Rebuild nvim-tree so deleted/renamed files don't cause stale state
    local ok, nt = pcall(require, "nvim-tree.api")
    if ok then pcall(nt.tree.reload) end
  end,
})

vim.api.nvim_create_autocmd("FileChangedShellPost", {
  pattern = "*",
  callback = function()
    -- Silent reload — handles both modified and deleted files
    pcall(vim.cmd, "silent! checktime")
    local ok, nt = pcall(require, "nvim-tree.api")
    if ok then pcall(nt.tree.reload) end
  end,
})
