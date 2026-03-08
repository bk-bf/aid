-- palette.lua — aid color palette (single source of truth)
--
-- All theme colors for aid are defined here.  Every component that needs a
-- color (bufferline, statusline, gitsigns, cursor, treemux highlights) imports
-- this module instead of hardcoding hex strings.
--
-- The same values are written to tmux/palette.conf by gen-tmux-palette.sh,
-- which reads this file directly via Lua — no values are duplicated.
--
-- Hot reload: saving this file while aid is running automatically re-applies
-- all nvim highlight groups and regenerates the tmux status bar colors.
-- No restart needed — sync.watch_palette() watches this file via inotify.

local M = {}

-- ── Core accent palette ───────────────────────────────────────────────────
M.purple      = "#b57bee"   -- accent: cursor, mode segment, session name bg
M.blue        = "#6181C6"   -- secondary: devinfo / fileinfo segment bg, tmux base
M.lavender    = "#A284C6"   -- tertiary: filename segment bg, tmux time bg

-- ── Bufferline (tab bar) ─────────────────────────────────────────────────
M.tab_bg      = "#C88E6B"   -- inactive tab background (warm tan-orange)
M.tab_sel     = "#a06a45"   -- active / selected tab background (burnt orange)
M.tab_fg      = "#ffffff"   -- all tab foreground text

-- ── Git signs ────────────────────────────────────────────────────────────
M.git_add     = "#50fa7b"   -- added line sign (Dracula green)
M.git_del     = "#ff5555"   -- deleted line sign (Dracula red)
M.git_chg     = "#ffaa00"   -- changed line sign (amber)
M.git_del_ln  = "#3d1a1a"   -- deleted line background
M.git_chg_ln  = "#3d2a00"   -- changed line background

-- ── Misc ─────────────────────────────────────────────────────────────────
M.fg          = "#ffffff"   -- universal foreground (all text on colored bg)
M.cursor_fg   = "#000000"   -- cursor text color
M.none        = "none"      -- transparent background sentinel

return M
