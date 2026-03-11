#!/usr/bin/env bash
# orchestrator.sh — aid --mode orchestrator bootstrap.
#
# Starts the T3/Codex-style multi-session layout on the aid tmux server.
#
# Layout per aid@<name> session (widths approximate):
#   [navigator ~25%] | [opencode ~75%]
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
_attach_or_switch() {
  local target="$1"
  if [[ -n "${TMUX:-}" ]]; then
    tmux -L aid switch-client -t "$target"
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
# Creates a new aid@<name> tmux session with the 2-pane orchestrator layout:
#   left  (~25%)  aid-sessions navigator (fzf, persistent)
#   right (~75%)  opencode
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
  local safe_name nvim_socket debug_log dbg_pane
  debug_log=""
  dbg_pane=""
  safe_name=$(printf '%s' "$name" | tr '/' '-')
  nvim_socket="/tmp/aid-nvim-${safe_name}.sock"

  # Deterministic HTTP port for this session's opencode server.
  # Range 4200-5199 — derived from session name so it's stable across restarts.
  local orc_port
  orc_port=$(( 4200 + $(printf '%s' "$name" | cksum | cut -d' ' -f1) % 1000 ))

  tmux -L aid new-session -d -s "$session" -c "$repo_path" \
    -x "$(tput cols)" -y "$(tput lines)"

  tmux -L aid source-file "$AID_DATA/tmux/palette.conf"

  # Pre-seed vimbridge placeholders.
  local tmux_socket session_id
  tmux_socket=$(tmux -L aid display-message -t "$session" -p "#{socket_path}")
  session_id=$(tmux -L aid display-message  -t "$session" -p "#{session_id}")
  printf ' ' > "${tmux_socket}-${session_id}-vimbridge"
  printf ' ' > "${tmux_socket}-${session_id}-vimbridge-R"
  tmux -L aid set-option -t "$session" status-left  "#(cat #{socket_path}-\#{session_id}-vimbridge)"
  tmux -L aid set-option -t "$session" status-right "#(cat #{socket_path}-\#{session_id}-vimbridge-R)"

  # Session-local env.
  tmux -L aid set-environment -t "$session" AID_NVIM_SOCKET   "$nvim_socket"
  tmux -L aid set-environment -t "$session" AID_ORC_NAME      "$name"
  tmux -L aid set-environment -t "$session" AID_ORC_REPO      "$repo_path"
  tmux -L aid set-environment -t "$session" AID_ORC_PORT      "$orc_port"

  # ── Build the 2-pane layout (or 3-pane in debug mode) ──
  # Window 0 starts with a single pane.  We split it into columns:
  #   nav (left ~25%) | opencode (right ~75%)
  # In debug mode a third pane is appended to the right of opencode:
  #   nav (~20%) | opencode (~55%) | debug (~25%)
  #
  # Initial pane → will become the navigator (left).
  local nav_pane
  nav_pane=$(tmux -L aid list-panes -t "$session" -F "#{pane_id}" | head -1)

  # Split right from nav: this becomes opencode (75% of total, or ~55% in debug mode).
  local orc_width="75%"
  [[ "${AID_DEBUG:-0}" -eq 1 ]] && orc_width="55%"
  local orc_pane
  orc_pane=$(tmux -L aid split-window -h -t "$nav_pane" -P -F "#{pane_id}" \
    -l "$orc_width" -- sleep infinity)

  dbg "nav=$nav_pane orc=$orc_pane"

  # In debug mode: split a third pane to the right of opencode for the live log.
  local dbg_pane=""
  local debug_log=""
  if [[ "${AID_DEBUG:-0}" -eq 1 ]]; then
    debug_log="${AID_DATA}/debug/aid-sessions-${name}.log"
    mkdir -p "$(dirname "$debug_log")"
    : > "$debug_log"
    dbg_pane=$(tmux -L aid split-window -h -t "$orc_pane" -P -F "#{pane_id}" \
      -l "31%" -- sleep infinity)
    tmux -L aid set-environment -t "$session" AID_DEBUG_LOG "$debug_log"
    dbg "dbg_pane=$dbg_pane debug_log=$debug_log"
  fi

  # Store pane IDs in session env so aid-sessions can find the opencode pane.
  tmux -L aid set-environment -t "$session" AID_ORC_NAV_PANE "$nav_pane"
  tmux -L aid set-environment -t "$session" AID_ORC_ORC_PANE "$orc_pane"

  # Start opencode in the right pane with a fixed HTTP port so the navigator
  # can reach the /tui/select-session API without port discovery.
  tmux -L aid respawn-pane -k -t "$orc_pane" \
    "OPENCODE_CONFIG_DIR=$(printf '%q' "$AID_DIR/opencode") OPENCODE_TUI_CONFIG=$(printf '%q' "$AID_DIR/opencode/tui.json") opencode --port ${orc_port} $(printf '%q' "$repo_path")"

  # Start the navigator in the left pane (aid-sessions: fzf-based navigator).
  local nav_env
  nav_env="AID_DIR=$(printf '%q' "$AID_DIR") AID_DATA=$(printf '%q' "$AID_DATA") AID_CONFIG=$(printf '%q' "${AID_CONFIG:-}")"
  [[ -n "$debug_log" ]] && nav_env+=" AID_DEBUG_LOG=$(printf '%q' "$debug_log")"
  tmux -L aid respawn-pane -k -t "$nav_pane" \
    "${nav_env} $(printf '%q' "$AID_DIR/lib/sessions/aid-sessions")"

  # Start the debug log viewer if in debug mode.
  if [[ -n "$dbg_pane" && -n "$debug_log" ]]; then
    tmux -L aid respawn-pane -k -t "$dbg_pane" \
      "AID_DEBUG_LOG=$(printf '%q' "$debug_log") $(printf '%q' "$AID_DIR/lib/sessions/aid-sessions-debug")"
  fi

  # ── Window 1: nvim ──
  tmux -L aid new-window -t "$session" -n "nvim" -c "$repo_path"
  local nvim_pane
  nvim_pane=$(tmux -L aid list-panes -t "${session}:nvim" -F "#{pane_id}" | head -1)

  # Treemux sidebar in nvim window.
  _tmx() { tmux -L aid show-option -gqv "$1"; }
  local treemux_args
  treemux_args="$(_tmx @treemux-nvim-command),$(_tmx @treemux-tree-nvim-init-file),,$(_tmx @treemux-python-command),left,$(_tmx @treemux-tree-width),top,70%,editor,0.5,2,5,0,,$(_tmx @treemux-tree-client)"
  local treemux_args_focus
  treemux_args_focus="$(_tmx @treemux-nvim-command),$(_tmx @treemux-tree-nvim-init-file),,$(_tmx @treemux-python-command),left,$(_tmx @treemux-tree-width),top,70%,editor,0.5,2,5,0,focus,$(_tmx @treemux-tree-client)"
  tmux -L aid set-option -gq "@treemux-key-Tab"    "$treemux_args"
  tmux -L aid set-option -gq "@treemux-key-Bspace" "$treemux_args_focus"
  tmux -L aid run-shell -t "$nvim_pane" "$AID_DIR/lib/ensure_treemux.sh"

  tmux -L aid respawn-pane -k -t "$nvim_pane" \
    "cd $(printf '%q' "$repo_path") && while true; do rm -f $(printf '%q' "$nvim_socket"); XDG_CONFIG_HOME=$(printf '%q' "$AID_DIR") XDG_DATA_HOME=$(printf '%q' "$AID_DATA") XDG_STATE_HOME=$HOME/.local/state/aid XDG_CACHE_HOME=$HOME/.cache/aid LG_CONFIG_FILE=$(printf '%q' "$AID_CONFIG/lazygit/config.yml") NVIM_APPNAME=nvim nvim --listen $(printf '%q' "$nvim_socket"); done"

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

  # Hook: status bar context — vimbridge when nvim window active, else project label.
  local orc_label=" ${name} "
  local vimbridge_l="#(cat \#{socket_path}-\#{session_id}-vimbridge)"
  local vimbridge_r="#(cat \#{socket_path}-\#{session_id}-vimbridge-R)"
  tmux -L aid set-hook -t "$session" after-select-window \
    "if-shell '[ \"#{window_name}\" = nvim ]' \
       'set-option -t $(printf '%q' "$session") status-left $(printf '%q' "$vimbridge_l") ; set-option -t $(printf '%q' "$session") status-right $(printf '%q' "$vimbridge_r")' \
       'set-option -t $(printf '%q' "$session") status-left $(printf '%q' "$orc_label") ; set-option -t $(printf '%q' "$session") status-right \"\"'"

  dbg "session $session ready"
  _attach_or_switch "$session"
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

# Normal launch: find existing orchestrator sessions (tagged @aid_mode=orchestrator).
# This explicitly excludes plain aid sessions sharing the same tmux server.
# Use awk field match (not grep) — @aid_mode is last field, no trailing space.
_existing=$(tmux -L aid list-sessions \
  -F "#{session_last_attached} #{@aid_mode} #{session_name}" 2>/dev/null \
  | awk '$2 == "orchestrator" {print $1, $3}' \
  | sort -rn \
  | awk '{print $NF}' \
  || true)

if [[ -z "$_existing" ]]; then
  # No orchestrator sessions yet — auto-create one from cwd.
  _new_session_from_cwd
else
  # Auto-attach to most recently used orchestrator session.
  _target=$(printf '%s\n' "$_existing" | head -1)
  dbg "auto-attaching to $_target"
  _attach_or_switch "$_target"
fi
