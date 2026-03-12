#!/usr/bin/env bash
# orchestrator.sh — aid --mode orchestrator bootstrap.
#
# Starts the T3/Codex-style multi-session layout on the aid tmux server.
#
# Layout per aid@<name> session (widths approximate):
#   [navigator ~20%] | [opencode ~55%] | [diff ~25%]
#   [tab: nvim — full width]
#
# The navigator (left pane) runs aid-sessions (fzf-based) which shows all
# aid@* orchestrator sessions and their opencode conversations. Selecting a
# conversation calls POST /tui/select-session on the session's opencode HTTP
# API port so the conversation switches without losing any history.
#
# On first launch with no existing sessions: auto-create from cwd basename.
# On subsequent launches: auto-attach to the most recently used aid@* session.
#
# This script is exec'd by aid.sh when --mode orchestrator is passed.
# All AID_* vars are inherited from aid.sh.

set -euo pipefail

: "${AID_DIR:?}"
: "${AID_DATA:?}"
: "${AID_CONFIG:?}"
export AID_DIR AID_DATA AID_CONFIG

# shellcheck source=lib/sessions/aid-meta
source "$AID_DIR/lib/sessions/aid-meta"

dbg() { [[ "${AID_DEBUG:-0}" -eq 1 ]] && echo "[orc:debug] $*" >&2 || true; }

# _spawn_log <log_file> <message>
# Write a structured SPAWN log line to the debug log file (when set).
# Format matches aid-sessions: "<unix_ms> SPAWN <message>"
_spawn_log() {
  local _log="$1"; shift
  [[ -z "$_log" ]] && return 0
  local _ms; _ms=$(date +%s%3N 2>/dev/null || printf '%s000' "$(date +%s)")
  printf '%s SPAWN %s\n' "$_ms" "$*" >> "$_log"
}

# ── tmux server bootstrap ─────────────────────────────────────────────────────

_ensure_server() {
  if ! tmux -L aid list-sessions &>/dev/null; then
    dbg "starting aid tmux server"
    "$AID_DIR/lib/gen-tmux-palette.sh"
    tmux -L aid -f "$AID_DIR/tmux.conf" new-session -d -s "aid@_bootstrap" \
      -x "$(tput cols)" -y "$(tput lines)"
    tmux -L aid source-file "$AID_DATA/tmux/palette.conf"
    # Global env vars — only set on a fresh server to avoid clobbering vars
    # for existing aid sessions on other branches sharing this tmux server.
    tmux -L aid set-environment -g AID_DIR             "$AID_DIR"
    tmux -L aid set-environment -g AID_DATA            "$AID_DATA"
    tmux -L aid set-environment -g AID_CONFIG          "$AID_CONFIG"
    tmux -L aid set-environment -g XDG_DATA_HOME       "$AID_DATA"
    tmux -L aid set-environment -g XDG_STATE_HOME      "$HOME/.local/state/aid"
    tmux -L aid set-environment -g XDG_CACHE_HOME      "$HOME/.cache/aid"
    tmux -L aid set-environment -g TMUX_PLUGIN_MANAGER_PATH "$AID_DATA/tmux/plugins/"
    tmux -L aid set-environment -g NVIM_APPNAME        "nvim"
    tmux -L aid set-environment -g OPENCODE_CONFIG_DIR "$AID_DIR/opencode"
    tmux -L aid set-environment -g OPENCODE_TUI_CONFIG "$AID_DIR/opencode/tui.json"
    dbg "server started"
  else
    dbg "server already running"
  fi
}

# ── Session helpers ───────────────────────────────────────────────────────────

# _attach_or_switch <session>
# Switches the tmux client to <session>.
#
# When called from within a pane subprocess (e.g. aid-sessions 'n' key),
# the plain `switch-client -t` targets whichever client tmux deems "current",
# which may be wrong.  AID_CALLER_CLIENT (exported by aid-sessions) contains
# the tty of the actual terminal the user is sitting at, so we use -c when
# available.
_attach_or_switch() {
  local target="$1"
  if [[ -n "${TMUX:-}" ]]; then
    if [[ -n "${AID_CALLER_CLIENT:-}" ]]; then
      tmux -L aid switch-client -c "$AID_CALLER_CLIENT" -t "$target"
    else
      tmux -L aid switch-client -t "$target"
    fi
  else
    tmux -L aid attach -t "$target"
  fi
}

# _most_recent_session
# Print the aid@* session name most recently attached to, or "" if none.
_most_recent_session() {
  tmux -L aid list-sessions \
    -F "#{session_last_attached} #{session_name}" 2>/dev/null \
    | grep -E ' aid@[^_][^/]*$' \
    | sort -rn \
    | awk 'NR==1{print $NF}' \
    || true
}

# ── Layout spawner ────────────────────────────────────────────────────────────

# spawn_orc_session <name> <repo_path>
# Creates a new aid@<name> tmux session with the 3-pane orchestrator layout:
#   left  (~20%)  aid-sessions navigator (fzf, persistent)
#   center (~55%) opencode
#   right  (~25%) aid-diff (git diff review pane)
# Plus a second window "nvim" (full-width nvim + treemux sidebar).
spawn_orc_session() {
  local name="$1" repo_path="$2"
  local session="aid@${name}"

  if tmux -L aid has-session -t "$session" 2>/dev/null; then
    dbg "session $session already exists — attaching"
    _attach_or_switch "$session"
    return
  fi

  dbg "spawning session=$session repo=$repo_path"

  # Per-session nvim socket.
  local safe_name nvim_socket
  safe_name=$(printf '%s' "$name" | tr '/' '-')
  nvim_socket="/tmp/aid-nvim-${safe_name}.sock"

  # Deterministic HTTP port for this session's opencode server.
  # Range 4200-5199 — derived from session name so it's stable across restarts.
  local orc_port
  orc_port=$(( 4200 + $(printf '%s' "$name" | cksum | cut -d' ' -f1) % 1000 ))

  tmux -L aid new-session -d -s "$session" -c "$repo_path" \
    -x "$(tput cols)" -y "$(tput lines)"
  tmux -L aid source-file "$AID_DATA/tmux/palette.conf"

  # Build the Orchestrator status bar strings from palette.lua.
  local _PL_R _PL_L _purple _blue _lavender _fg _cursor_fg
  _PL_R=$(printf '\xee\x82\xb0')
  _PL_L=$(printf '\xee\x82\xb2')
  _pal() { lua - "$AID_DIR/nvim/lua/palette.lua" <<LUA
local p = assert(loadfile(arg[1]))(); io.write(p.$1)
LUA
  }
  _purple=$(_pal purple); _blue=$(_pal blue); _lavender=$(_pal lavender)
  _fg=$(_pal fg);         _cursor_fg=$(_pal cursor_fg)
  local orch_status_l orch_status_r
  orch_status_l="#[fg=${_cursor_fg},bg=${_purple},bold] Orchestrator #[fg=${_purple},bg=${_blue},none]${_PL_R}"
  orch_status_r="#[fg=${_lavender},bg=${_blue}] #{pane_current_command} #[fg=${_blue},bg=${_lavender}]${_PL_L}#[fg=${_fg},bg=${_lavender}] %H:%M #[fg=${_lavender},bg=${_purple}]${_PL_L}#[fg=${_cursor_fg},bg=${_purple},bold] #{?client_prefix,PREFIX,#h} "

  # Pre-seed vimbridge placeholders.
  local tmux_socket session_id
  tmux_socket=$(tmux -L aid display-message -t "$session" -p "#{socket_path}")
  session_id=$(tmux -L aid display-message  -t "$session" -p "#{session_id}")
  printf ' ' > "${tmux_socket}-${session_id}-vimbridge"
  printf ' ' > "${tmux_socket}-${session_id}-vimbridge-R"
  # Window 0 (orchestrator layout) starts active — show the Orchestrator bar immediately.
  tmux -L aid set-option -t "$session" status-left  "$orch_status_l"
  tmux -L aid set-option -t "$session" status-right "$orch_status_r"

  # Session-local env.
  tmux -L aid set-environment -t "$session" AID_NVIM_SOCKET   "$nvim_socket"
  tmux -L aid set-environment -t "$session" AID_ORC_NAME      "$name"
  tmux -L aid set-environment -t "$session" AID_ORC_REPO      "$repo_path"
  tmux -L aid set-environment -t "$session" AID_ORC_PORT      "$orc_port"

  # ── Build the layout ──
  # Normal mode (3 panes, side by side):
  #   nav (left ~20%) | opencode (center ~55%) | diff (right ~25%)
  #
  # Debug mode (4 panes):
  #   nav (left ~20%) | opencode (center ~55%) | diff (right ~25%)
  #   ─────────────── debug log (3 lines height, full width) ────────────────
  #
  # Initial pane → will become the navigator (left).
  local nav_pane
  nav_pane=$(tmux -L aid list-panes -t "$session" -F "#{pane_id}" | head -1)

  # In debug mode: first split the window horizontally (top/bottom) so the
  # debug pane spans the full width at the bottom.  Then split the top half
  # vertically into nav | opencode | diff.
  local dbg_pane="" debug_log=""
  if [[ "${AID_DEBUG:-0}" -eq 1 ]]; then
    debug_log="${repo_path}/log-$(date '+%Y%m%d-%H%M%S').txt"
    : > "$debug_log"
    # Split bottom 3 lines off the initial (full-width) pane.
    dbg_pane=$(tmux -L aid split-window -v -t "$nav_pane" -P -F "#{pane_id}" \
      -l "3" -- sleep infinity)
    tmux -L aid set-environment -t "$session" AID_DEBUG_LOG "$debug_log"
    dbg "dbg_pane=$dbg_pane debug_log=$debug_log"
    _spawn_log "$debug_log" "session=${session} repo=${repo_path} port=${orc_port} nav=${nav_pane} dbg=${dbg_pane} log=${debug_log}"
  fi

  # Split the top pane (nav_pane) vertically: right side becomes opencode.
  # opencode gets ~80% of remaining width (nav keeps ~20%).
  local orc_pane
  orc_pane=$(tmux -L aid split-window -h -t "$nav_pane" -P -F "#{pane_id}" \
    -l "80%" -- sleep infinity)

  # Split the right side of opencode: rightmost ~25% becomes the diff pane.
  local diff_pane
  diff_pane=$(tmux -L aid split-window -h -t "$orc_pane" -P -F "#{pane_id}" \
    -l "25%" -- sleep infinity)

  # After the horizontal splits, tmux may have re-equalized the vertical split
  # and grown the debug pane.  Pin it back to the desired height.
  if [[ -n "$dbg_pane" ]]; then
    tmux -L aid resize-pane -t "$dbg_pane" -y 3
  fi

  dbg "nav=$nav_pane orc=$orc_pane diff=$diff_pane"
  _spawn_log "$debug_log" "panes ready: nav=${nav_pane} orc=${orc_pane} diff=${diff_pane}${dbg_pane:+ dbg=${dbg_pane}}"

  # Store pane IDs in session env so aid-sessions can find the opencode pane.
  tmux -L aid set-environment -t "$session" AID_ORC_NAV_PANE  "$nav_pane"
  tmux -L aid set-environment -t "$session" AID_ORC_ORC_PANE  "$orc_pane"
  tmux -L aid set-environment -t "$session" AID_ORC_DIFF_PANE "$diff_pane"

  # Start opencode in the right pane with a fixed HTTP port so the navigator
  # can reach the /tui/select-session API without port discovery.
  #
  # XDG_DATA_HOME must be set INLINE here (not just as a global tmux env var)
  # because respawn-pane inline commands do not inherit the global tmux
  # environment.  Without it, opencode falls back to ~/.local/share/opencode
  # and serves the user's entire conversation history across all projects,
  # ignoring the per-branch isolation we want.
  _spawn_log "$debug_log" "respawn orc_pane=${orc_pane}: opencode --port ${orc_port} ${repo_path}"
  tmux -L aid respawn-pane -k -t "$orc_pane" \
    "OPENCODE_CONFIG_DIR=$(printf '%q' "$AID_DIR/opencode") OPENCODE_TUI_CONFIG=$(printf '%q' "$AID_DIR/opencode/tui.json") XDG_DATA_HOME=$(printf '%q' "$AID_DATA") opencode --port ${orc_port} $(printf '%q' "$repo_path")"
  _spawn_log "$debug_log" "orc_pane=${orc_pane} respawned (opencode)"

  # In debug mode use --watch so panes hot-reload on source file changes.
  local bun_run="bun run"
  [[ "${AID_DEBUG:-0}" -eq 1 ]] && bun_run="bun run --watch"

  # Start the navigator in the left pane (aid-sessions.ts: TypeScript/Bun navigator).
  local nav_env
  nav_env="AID_DIR=$(printf '%q' "$AID_DIR") AID_DATA=$(printf '%q' "$AID_DATA") AID_CONFIG=$(printf '%q' "${AID_CONFIG:-}")"
  [[ -n "$debug_log" ]] && nav_env+=" AID_DEBUG_LOG=$(printf '%q' "$debug_log")"
  _spawn_log "$debug_log" "respawn nav_pane=${nav_pane}: aid-sessions.ts (bun_run=${bun_run})"
  tmux -L aid respawn-pane -k -t "$nav_pane" \
    "${nav_env} ${bun_run} $(printf '%q' "$AID_DIR/lib/sessions/aid-sessions.ts")"
  _spawn_log "$debug_log" "nav_pane=${nav_pane} respawned (aid-sessions.ts)"

  # Start aid-diff in the right pane (TypeScript/Bun diff review pane).
  local diff_env
  diff_env="AID_DIR=$(printf '%q' "$AID_DIR") AID_ORC_REPO=$(printf '%q' "$repo_path")"
  [[ -n "$debug_log" ]] && diff_env+=" AID_DEBUG_LOG=$(printf '%q' "$debug_log")"
  _spawn_log "$debug_log" "respawn diff_pane=${diff_pane}: aid-diff.ts (bun_run=${bun_run})"
  tmux -L aid respawn-pane -k -t "$diff_pane" \
    "${diff_env} ${bun_run} $(printf '%q' "$AID_DIR/lib/sessions/aid-diff.ts")"
  _spawn_log "$debug_log" "diff_pane=${diff_pane} respawned (aid-diff.ts)"

  # Start the debug log viewer if in debug mode.
  if [[ -n "$dbg_pane" && -n "$debug_log" ]]; then
    _spawn_log "$debug_log" "respawn dbg_pane=${dbg_pane}: aid-sessions-debug"
    tmux -L aid respawn-pane -k -t "$dbg_pane" \
      "AID_DEBUG_LOG=$(printf '%q' "$debug_log") $(printf '%q' "$AID_DIR/lib/sessions/aid-sessions-debug")"
    _spawn_log "$debug_log" "dbg_pane=${dbg_pane} respawned (aid-sessions-debug)"
  fi

  # ── Window 1: nvim (DISABLED — uncomment to re-enable) ──
  # _spawn_log "$debug_log" "creating nvim window"
  # tmux -L aid new-window -t "$session" -n "nvim" -c "$repo_path"
  # local nvim_pane
  # nvim_pane=$(tmux -L aid list-panes -t "${session}:nvim" -F "#{pane_id}" | head -1)
  # _spawn_log "$debug_log" "nvim window created: nvim_pane=${nvim_pane}"
  #
  # # Treemux sidebar in nvim window.
  # _tmx() { tmux -L aid show-option -gqv "$1"; }
  # local treemux_args
  # treemux_args="$(_tmx @treemux-nvim-command),$(_tmx @treemux-tree-nvim-init-file),,$(_tmx @treemux-python-command),left,$(_tmx @treemux-tree-width),top,70%,editor,0.5,2,5,0,,$(_tmx @treemux-tree-client)"
  # local treemux_args_focus
  # treemux_args_focus="$(_tmx @treemux-nvim-command),$(_tmx @treemux-tree-nvim-init-file),,$(_tmx @treemux-python-command),left,$(_tmx @treemux-tree-width),top,70%,editor,0.5,2,5,0,focus,$(_tmx @treemux-tree-client)"
  # tmux -L aid set-option -gq "@treemux-key-Tab"    "$treemux_args"
  # tmux -L aid set-option -gq "@treemux-key-Bspace" "$treemux_args_focus"
  # tmux -L aid run-shell -t "$nvim_pane" "$AID_DIR/lib/ensure_treemux.sh"
  #
  # _spawn_log "$debug_log" "respawn nvim_pane=${nvim_pane}: nvim --listen ${nvim_socket}"
  # tmux -L aid respawn-pane -k -t "$nvim_pane" \
  #   "cd $(printf '%q' "$repo_path") && while true; do rm -f $(printf '%q' "$nvim_socket"); XDG_CONFIG_HOME=$(printf '%q' "$AID_DIR") XDG_DATA_HOME=$(printf '%q' "$AID_DATA") XDG_STATE_HOME=$HOME/.local/state/aid XDG_CACHE_HOME=$HOME/.cache/aid LG_CONFIG_FILE=$(printf '%q' "$AID_CONFIG/lazygit/config.yml") NVIM_APPNAME=nvim nvim --listen $(printf '%q' "$nvim_socket"); done"
  # _spawn_log "$debug_log" "nvim_pane=${nvim_pane} respawned (nvim)"

  # Return to window 0 (3-pane layout).
  tmux -L aid select-window -t "${session}:0"
  # Focus the opencode (center) pane by default.
  tmux -L aid select-pane -t "$orc_pane"

  # Tag this session as an orchestrator session so the launcher can
  # distinguish it from plain aid sessions sharing the same tmux server.
  tmux -L aid set-option -t "$session" "@aid_mode" "orchestrator"

  # Write metadata.
  _meta_write "$name" "$repo_path"

  # Hook: update last_active on pane focus.
  tmux -L aid set-hook -t "$session" pane-focus-in \
    "run-shell \"AID_DATA=$(printf '%q' "$AID_DATA") $(printf '%q' "$AID_DIR/lib/sessions/aid-meta-touch") $(printf '%q' "$session")\""

  # Hook: status bar context — vimbridge on nvim window, Orchestrator bar on orc window.
  local vimbridge_l="#(cat #{socket_path}-\#{session_id}-vimbridge)"
  local vimbridge_r="#(cat #{socket_path}-\#{session_id}-vimbridge-R)"
  tmux -L aid set-hook -t "$session" after-select-window \
    "if-shell '[ \"#{window_name}\" = nvim ]' \
       'set-option -t $(printf '%q' "$session") status-left $(printf '%q' "$vimbridge_l") ; set-option -t $(printf '%q' "$session") status-right $(printf '%q' "$vimbridge_r")' \
       'set-option -t $(printf '%q' "$session") status-left $(printf '%q' "$orch_status_l") ; set-option -t $(printf '%q' "$session") status-right $(printf '%q' "$orch_status_r")'"

  dbg "session $session ready"
  _spawn_log "$debug_log" "session=${session} ready — calling _attach_or_switch"
  _attach_or_switch "$session"
  _spawn_log "$debug_log" "_attach_or_switch returned (rc=$?)"
}

# ── New session prompt ────────────────────────────────────────────────────────

# _new_session_from_cwd
# Auto-derive session name from $PWD + the aid branch (same logic as aid.sh).
# Name form: <aid_branch>@<basename_of_pwd>  (e.g. aid@my-project)
# Appends a numeric suffix to avoid collisions with existing sessions.
# No user prompts — spawns immediately.
_new_session_from_cwd() {
  local repo_path="$PWD"

  # Base name: sanitised basename of the repo path (same transform as aid.sh).
  local base
  base=$(basename "$repo_path" | sed 's/^\.*//' | tr -cs '[:alnum:]-_' '-' | sed 's/-$//')
  [[ -z "$base" ]] && base="dev"

  # Append a numeric suffix if a session with this name already exists.
  # spawn_orc_session prepends "aid@", so we check "aid@${name}".
  local name="$base"
  local n=2
  while tmux -L aid has-session -t "aid@${name}" 2>/dev/null; do
    name="${base}${n}"
    (( n++ ))
  done

  spawn_orc_session "$name" "$repo_path"
}

# ── Main ──────────────────────────────────────────────────────────────────────

_ensure_server

# --new: create a new orchestrator session from cwd (called from navigator 'n' key).
if [[ "${1:-}" == "--new" ]]; then
  _new_session_from_cwd
  exit 0
fi

# --resurrect <name> <repo_path>: re-spawn a dead session.
if [[ "${1:-}" == "--resurrect" ]]; then
  spawn_orc_session "${2:?}" "${3:?}"
  exit 0
fi

# Normal launch: always create a new orchestrator session from cwd.
# (To attach to an existing session, use `aid -a`.)
_new_session_from_cwd
