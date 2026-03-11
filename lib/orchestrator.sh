#!/usr/bin/env bash
# orchestrator.sh — aid --mode orchestrator bootstrap.
#
# Starts the T3/Codex-style multi-session layout on the aid tmux server.
#
# Layout per aid@<name> session (widths approximate):
#   [navigator ~25%] | [opencode ~50%] | [lazygit ~25%]
#   [tab: nvim — full width]
#
# The navigator (left pane) runs aid-sessions in a persistent fzf loop and
# shows all aid@* sessions as folders with their opencode conversations as
# children.  Selecting a conversation respawns the center pane with
#   opencode -s <session_id> <repo_path>
# so the conversation switches without losing any history (opencode DB persists).
#
# On first launch with no existing sessions: prompt for name + repo, spawn layout.
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
    tmux -L aid set-environment -g XDG_STATE_HOME           "$HOME/.local/state/aid"
    tmux -L aid set-environment -g XDG_CACHE_HOME           "$HOME/.cache/aid"
    tmux -L aid set-environment -g TMUX_PLUGIN_MANAGER_PATH "$AID_DATA/tmux/plugins/"
    tmux -L aid set-environment -g NVIM_APPNAME             "nvim"
    dbg "server started"
  else
    dbg "server already running"
  fi
  # Always update AID_* in the server so branch installs use correct paths.
  tmux -L aid set-environment -g AID_DIR             "$AID_DIR"
  tmux -L aid set-environment -g AID_DATA            "$AID_DATA"
  tmux -L aid set-environment -g AID_CONFIG          "$AID_CONFIG"
  tmux -L aid set-environment -g XDG_DATA_HOME       "$AID_DATA"
  tmux -L aid set-environment -g OPENCODE_CONFIG_DIR "$AID_DIR/opencode"
  tmux -L aid set-environment -g OPENCODE_TUI_CONFIG "$AID_DIR/opencode/tui.json"
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
# Creates a new aid@<name> tmux session with the 3-pane orchestrator layout:
#   left  (~25%)  aid-sessions navigator (fzf, persistent)
#   center (~50%) opencode
#   right  (~25%) lazygit
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

  # ── Build the 3-pane layout ──
  # Window 0 starts with a single pane.  We split it into three columns:
  #   nav (left) | opencode (center) | lazygit (right)
  #
  # Strategy: create panes via split-window, then note their IDs.
  # Initial pane → will become the navigator (left).
  local nav_pane
  nav_pane=$(tmux -L aid list-panes -t "$session" -F "#{pane_id}" | head -1)

  # Split right from nav: this becomes opencode+lazygit combined (75% of total).
  # Then split that right area: lazygit gets 25% of total = 33% of the 75% area.
  local orc_pane lazygit_pane
  orc_pane=$(tmux -L aid split-window -h -t "$nav_pane" -P -F "#{pane_id}" \
    -l "75%" -- sleep infinity)
  lazygit_pane=$(tmux -L aid split-window -h -t "$orc_pane" -P -F "#{pane_id}" \
    -l "34%" -- sleep infinity)

  dbg "nav=$nav_pane orc=$orc_pane lazygit=$lazygit_pane"

  # Store pane IDs in session env so aid-sessions can find the opencode pane.
  tmux -L aid set-environment -t "$session" AID_ORC_NAV_PANE      "$nav_pane"
  tmux -L aid set-environment -t "$session" AID_ORC_ORC_PANE      "$orc_pane"
  tmux -L aid set-environment -t "$session" AID_ORC_LAZYGIT_PANE  "$lazygit_pane"

  # Start lazygit in the right pane.
  tmux -L aid respawn-pane -k -t "$lazygit_pane" \
    "cd $(printf '%q' "$repo_path") && lazygit --use-config-file=$(printf '%q' "$AID_CONFIG/lazygit/config.yml")"

  # Start opencode in the center pane.
  tmux -L aid respawn-pane -k -t "$orc_pane" \
    "OPENCODE_CONFIG_DIR=$(printf '%q' "$AID_DIR/opencode") OPENCODE_TUI_CONFIG=$(printf '%q' "$AID_DIR/opencode/tui.json") opencode $(printf '%q' "$repo_path")"

  # Start the navigator in the left pane.
  tmux -L aid respawn-pane -k -t "$nav_pane" \
    "AID_DIR=$(printf '%q' "$AID_DIR") AID_DATA=$(printf '%q' "$AID_DATA") AID_CONFIG=$(printf '%q' "${AID_CONFIG:-}") $(printf '%q' "$AID_DIR/lib/sessions/aid-sessions")"

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

_fzf_prompt() {
  local label="$1" default="$2"
  printf '%s' "$default" \
    | fzf --print-query \
          --query="$default" \
          --bind='enter:accept' \
          --bind='esc:abort' \
          --no-info \
          --no-sort \
          --height=4 \
          --border=rounded \
          --prompt="  ${label}: " \
          --color='border:238,prompt:blue' \
    | head -1
}

_prompt_new_session() {
  # If not already in a popup/inline context and inside the aid server, open a popup.
  if [[ "${AID_IN_NEW_POPUP:-0}" -ne 1 ]]; then
    local _in_aid=0
    if [[ -n "${TMUX:-}" ]]; then
      local _s; _s=$(printf '%s' "${TMUX}" | cut -d',' -f1)
      [[ "$(basename "$_s")" == "aid" ]] && _in_aid=1
    fi
    if [[ "$_in_aid" -eq 1 ]]; then
      # Need a popup for a real tty.
      local _c _c_flag=()
      if [[ -n "${AID_CALLER_CLIENT:-}" ]] && \
         tmux -L aid list-clients -F "#{client_tty}" 2>/dev/null \
           | grep -qxF "${AID_CALLER_CLIENT}"; then
        _c="${AID_CALLER_CLIENT}"
        _c_flag=(-c "$_c")
      fi
      tmux -L aid display-popup -E -w 72 -h 20 "${_c_flag[@]}" \
        "AID_IN_NEW_POPUP=1 AID_CALLER_CLIENT=$(printf '%q' "${AID_CALLER_CLIENT:-}") AID_DIR=$(printf '%q' "$AID_DIR") AID_DATA=$(printf '%q' "$AID_DATA") AID_CONFIG=$(printf '%q' "$AID_CONFIG") TMUX=$(printf '%q' "${TMUX:-}") $(printf '%q' "$AID_DIR/lib/orchestrator.sh") --new"
      return
    fi
    # Outside the aid server: already have a real tty, fall through.
  fi

  # Prompt for session name and repo path.
  local default_name default_repo
  default_repo="$PWD"
  default_name=$(basename "$PWD" | sed 's/^\.*//' | tr -cs '[:alnum:]-_.' '-' | sed 's/-$//')
  [[ -z "$default_name" ]] && default_name="dev"

  local _name
  _name=$(_fzf_prompt "session name" "$default_name") \
    || { echo "aid: cancelled" >&2; exit 1; }
  _name=$(printf '%s' "${_name:-$default_name}" | tr -cs '[:alnum:]-_.' '-' | sed 's/-$//')
  [[ -z "$_name" ]] && _name="$default_name"

  # Check for name collision.
  if tmux -L aid has-session -t "aid@${_name}" 2>/dev/null; then
    echo "aid: session 'aid@${_name}' already exists" >&2
    exit 1
  fi

  # Repo path: fzf over find output.
  local _repo
  _repo=$(find "$HOME" -maxdepth 5 -type d 2>/dev/null \
    | fzf --print-query \
          --query="$default_repo" \
          --bind='enter:accept' \
          --bind='esc:abort' \
          --no-sort \
          --height=40% \
          --border=rounded \
          --prompt="  repo path: " \
          --color='border:238,prompt:blue' \
    | head -1) \
    || { echo "aid: cancelled" >&2; exit 1; }
  _repo="${_repo:-$default_repo}"
  _repo="${_repo/#\~/$HOME}"

  if [[ ! -d "$_repo" ]]; then
    echo "aid: repo path '$_repo' does not exist" >&2
    exit 1
  fi

  spawn_orc_session "$_name" "$_repo"
}

# ── Main ──────────────────────────────────────────────────────────────────────

_ensure_server

# --new: skip to prompt (called from navigator 'n' key or re-exec inside popup).
if [[ "${1:-}" == "--new" ]]; then
  _prompt_new_session
  exit 0
fi

# --resurrect <name> <repo_path>: re-spawn a dead session.
if [[ "${1:-}" == "--resurrect" ]]; then
  spawn_orc_session "${2:?}" "${3:?}"
  exit 0
fi

# Normal launch: find existing sessions for this branch install.
_existing=$(tmux -L aid list-sessions \
  -F "#{session_last_attached} #{session_name}" 2>/dev/null \
  | grep -E ' aid@[^_][^/]*$' \
  | sort -rn \
  | awk '{print $NF}' \
  || true)

if [[ -z "$_existing" ]]; then
  # No sessions yet — prompt for the first one.
  _prompt_new_session
else
  # Auto-attach to most recently used session.
  _target=$(printf '%s\n' "$_existing" | head -1)
  dbg "auto-attaching to $_target"
  _attach_or_switch "$_target"
fi
