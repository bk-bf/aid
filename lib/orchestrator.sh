#!/usr/bin/env bash
# orchestrator.sh — aid --mode orchestrator bootstrap.
#
# Starts the T3/Codex-style multi-session layout on the aid tmux server:
#   - Each opencode context lives in its own tmux session named aid@<project>/<slug>
#   - The session navigator (aid-sessions) is available as a global prefix+s popup
#   - The first invocation creates the dashboard session and prompts for a first context
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

# AID_CALLER_CLIENT — the tty of the terminal that launched this orchestrator
# invocation (e.g. /dev/pts/3).  Resolved once here so that every
# display-popup -c and switch-client -c targets the exact right terminal no
# matter how many re-execs or sub-popups occur.
# Resolution order (first non-empty wins):
#   1. Already set (re-exec inside a popup) — keep it.
#   2. Inside the aid tmux server: ask tmux for the client attached to TMUX_PANE.
#   3. Fallback: the calling terminal's own tty (works from plain terminals and
#      from inside any other tmux server — covers the normal launch path).
if [[ -z "${AID_CALLER_CLIENT:-}" ]]; then
  if [[ -n "${TMUX_PANE:-}" ]]; then
    AID_CALLER_CLIENT=$(tmux -L aid display-message -t "$TMUX_PANE" -p "#{client_tty}" 2>/dev/null || true)
  fi
  if [[ -z "${AID_CALLER_CLIENT:-}" ]]; then
    AID_CALLER_CLIENT=$(tty 2>/dev/null || true)
  fi
fi
export AID_CALLER_CLIENT

# ── Helpers ───────────────────────────────────────────────────────────────────

# Ensure the aid tmux server is running with the aid config.
# If no sessions exist yet, start the server by creating a scratch session that
# we immediately hide; the real sessions are spawned by spawn_orc_session below.
_ensure_server() {
  if ! tmux -L aid list-sessions &>/dev/null; then
    dbg "starting aid tmux server"
    "$AID_DIR/lib/gen-tmux-palette.sh"
    tmux -L aid -f "$AID_DIR/tmux.conf" new-session -d -s "aid@dashboard" \
      -x "$(tput cols)" -y "$(tput lines)"
    tmux -L aid source-file "$AID_DATA/tmux/palette.conf"
    tmux -L aid set-environment -g XDG_STATE_HOME           "$HOME/.local/state/aid"
    tmux -L aid set-environment -g XDG_CACHE_HOME           "$HOME/.cache/aid"
    tmux -L aid set-environment -g TMUX_PLUGIN_MANAGER_PATH "$AID_DATA/tmux/plugins/"
    tmux -L aid set-environment -g NVIM_APPNAME             "nvim"
    # Replicate treemux key setup from aid.sh (TPM targets default socket, not -L aid).
    _tmx() { tmux -L aid show-option -gqv "$1"; }
    _treemux_args="$(_tmx @treemux-nvim-command),$(_tmx @treemux-tree-nvim-init-file),,$(_tmx @treemux-python-command),left,$(_tmx @treemux-tree-width),top,70%,editor,0.5,2,5,0,,$(_tmx @treemux-tree-client)"
    _treemux_args_focus="$(_tmx @treemux-nvim-command),$(_tmx @treemux-tree-nvim-init-file),,$(_tmx @treemux-python-command),left,$(_tmx @treemux-tree-width),top,70%,editor,0.5,2,5,0,focus,$(_tmx @treemux-tree-client)"
    tmux -L aid set-option -gq "@treemux-key-Tab"    "${_treemux_args}"
    tmux -L aid set-option -gq "@treemux-key-Bspace" "${_treemux_args_focus}"
    dbg "server started, dashboard session created"
  else
    dbg "server already running"
  fi
  # Always update AID_DIR/AID_DATA/AID_CONFIG in the server environment so that
  # sessions spawned from a branch install use the branch's paths, even when the
  # server was originally started by a different (e.g. main) aid install.
  tmux -L aid set-environment -g AID_DIR             "$AID_DIR"
  tmux -L aid set-environment -g AID_DATA            "$AID_DATA"
  tmux -L aid set-environment -g AID_CONFIG          "$AID_CONFIG"
  tmux -L aid set-environment -g XDG_DATA_HOME       "$AID_DATA"
  tmux -L aid set-environment -g OPENCODE_CONFIG_DIR "$AID_DIR/opencode"
  tmux -L aid set-environment -g OPENCODE_TUI_CONFIG "$AID_DIR/opencode/tui.json"
}

# spawn_orc_session <project> <slug> <repo_path>
# Creates a new aid@<project>/<slug> tmux session with the orchestrator 3-pane layout:
#   left: ~25% opencode  (NOTE: in the orchestrator the "left" visible pane after
#         treemux sidebar opens is opencode — same treemux+opencode architecture
#         as the standard layout but opencode is the focus pane, not nvim)
#   right: lazygit for diff review
#   tab "nvim": full-width nvim window
#
# Layout (column order, left to right):
#   [treemux sidebar] | [opencode — main focus] | [lazygit]
#
# The session navigator popup (prefix+s → aid-sessions) lets the user move
# between sessions without leaving the terminal.
spawn_orc_session() {
  local project="$1" slug="$2" repo_path="$3"
  local session="aid@${project}/${slug}"

  if tmux -L aid has-session -t "$session" 2>/dev/null; then
    echo "aid: session '$session' already exists — attaching" >&2
    _attach_or_switch "$session"
    return
  fi

  dbg "spawning session=$session repo=$repo_path"

  # Per-session nvim socket.
  local safe_name
  safe_name=$(printf '%s' "${project}/${slug}" | tr '/' '-')
  local nvim_socket="/tmp/aid-nvim-${safe_name}.sock"

  tmux -L aid new-session -d -s "$session" -c "$repo_path" \
    -x "$(tput cols)" -y "$(tput lines)"

  # Apply palette (server-global, idempotent).
  tmux -L aid source-file "$AID_DATA/tmux/palette.conf"

  # Pre-seed vimbridge placeholders for this session's status bar.
  local _tmux_socket _session_id
  _tmux_socket=$(tmux -L aid display-message -t "$session" -p "#{socket_path}")
  _session_id=$(tmux -L aid display-message -t "$session" -p "#{session_id}")
  printf ' ' > "${_tmux_socket}-${_session_id}-vimbridge"
  printf ' ' > "${_tmux_socket}-${_session_id}-vimbridge-R"
  tmux -L aid set-option -t "$session" status-left  "#(cat #{socket_path}-\#{session_id}-vimbridge)"
  tmux -L aid set-option -t "$session" status-right "#(cat #{socket_path}-\#{session_id}-vimbridge-R)"

  # Session-local env.
  tmux -L aid set-environment -t "$session" AID_NVIM_SOCKET "$nvim_socket"
  tmux -L aid set-environment -t "$session" AID_ORC_PROJECT "$project"
  tmux -L aid set-environment -t "$session" AID_ORC_SLUG    "$slug"
  tmux -L aid set-environment -t "$session" AID_ORC_REPO    "$repo_path"

  # --- Build the 3-pane layout ---
  # Initial pane will become opencode (the primary focus pane in orchestrator).
  local orc_pane_id
  orc_pane_id=$(tmux -L aid list-panes -t "$session" -F "#{pane_id}" | head -1)
  dbg "orc_pane_id=$orc_pane_id"

  # Split right: lazygit for diff review (~25% of total width).
  dbg "splitting lazygit pane"
  tmux -L aid split-window -h -p 25 -t "$orc_pane_id" \
    "cd $(printf '%q' "$repo_path") && lazygit --use-config-file=$(printf '%q' "$AID_CONFIG/lazygit/config.yml")"

  # Return focus to the opencode pane before opening treemux sidebar
  # (sidebar toggle reads the focused pane to determine insert position).
  tmux -L aid select-pane -t "$orc_pane_id"

  # Open treemux sidebar on the left.
    tmux -L aid run-shell -t "$orc_pane_id" "$AID_DIR/lib/ensure_treemux.sh"

  # Respawn the opencode pane into opencode directly (no shell, same pattern as aid.sh).
  dbg "respawning opencode pane"
  tmux -L aid respawn-pane -k -t "$orc_pane_id" \
    "OPENCODE_CONFIG_DIR=$(printf '%q' "$AID_DIR/opencode") OPENCODE_TUI_CONFIG=$(printf '%q' "$AID_DIR/opencode/tui.json") opencode $(printf '%q' "$repo_path")"

  # Add a second window for nvim (full-width, same restart-loop pattern as aid.sh).
  dbg "creating nvim window"
  tmux -L aid new-window -t "$session" -n "nvim" -c "$repo_path"
  local nvim_pane_id
  nvim_pane_id=$(tmux -L aid list-panes -t "${session}:nvim" -F "#{pane_id}" | head -1)
  tmux -L aid respawn-pane -k -t "$nvim_pane_id" \
    "cd $(printf '%q' "$repo_path") && while true; do rm -f $(printf '%q' "$nvim_socket"); XDG_CONFIG_HOME=$(printf '%q' "$AID_DIR") XDG_DATA_HOME=$(printf '%q' "$AID_DATA") XDG_STATE_HOME=$HOME/.local/state/aid XDG_CACHE_HOME=$HOME/.cache/aid LG_CONFIG_FILE=$(printf '%q' "$AID_CONFIG/lazygit/config.yml") NVIM_APPNAME=nvim nvim --listen $(printf '%q' "$nvim_socket"); done"

  # Open treemux sidebar in the nvim window too (T-ORC-6).
  # run-shell executes ensure_treemux.sh in the context of the nvim pane so the
  # sidebar opens on the left, leaving nvim as the right/focus pane.
  tmux -L aid run-shell -t "$nvim_pane_id" "$AID_DIR/lib/ensure_treemux.sh"

  # Switch back to window 0 (opencode layout) as the default entry point.
  tmux -L aid select-window -t "${session}:0"

  # Write metadata for the session navigator.
  _write_session_metadata "$project" "$slug" "$repo_path"

  # Hook: update last_active timestamp whenever any pane in this session is focused.
  tmux -L aid set-hook -t "$session" pane-focus-in \
    "run-shell \"AID_DATA=$(printf '%q' "$AID_DATA") $(printf '%q' "$AID_DIR/lib/sessions/aid-meta-touch") aid@${project}/${slug}\""

  # T-ORC-7: Status bar context tracking.
  # When the nvim window is focused, let vim-tpipeline drive status-left/right
  # via the vimbridge files.  When any other window (opencode layout) is focused,
  # show a static project/slug label so the bar doesn't display stale nvim output.
  local _orc_label=" ${project}/${slug} "
  local _vimbridge_l="#(cat \#{socket_path}-\#{session_id}-vimbridge)"
  local _vimbridge_r="#(cat \#{socket_path}-\#{session_id}-vimbridge-R)"
  tmux -L aid set-hook -t "$session" after-select-window \
    "if-shell '[ \"#{window_name}\" = nvim ]' \
       'set-option -t $(printf '%q' "$session") status-left $(printf '%q' "$_vimbridge_l") ; set-option -t $(printf '%q' "$session") status-right $(printf '%q' "$_vimbridge_r")' \
       'set-option -t $(printf '%q' "$session") status-left $(printf '%q' "$_orc_label") ; set-option -t $(printf '%q' "$session") status-right \"\"'"

  dbg "session $session ready"
  _attach_or_switch "$session"
}

# _write_session_metadata <project> <slug> <repo_path>
# Delegates to _meta_write from aid-meta (sourced at top of file).
_write_session_metadata() {
  local project="$1" slug="$2" repo_path="$3"
  _meta_write "$project" "$slug" "$repo_path"
  dbg "metadata written via _meta_write for aid@${project}/${slug}"
}

# _aid_client_tty
# Returns AID_CALLER_CLIENT if it is a currently connected client of the aid
# tmux server, otherwise returns empty string.
# This guards every -c flag: passing a tty that belongs to a different server
# (e.g. the user's personal tmux) causes "can't find client" errors.
_aid_client_tty() {
  [[ -z "${AID_CALLER_CLIENT:-}" ]] && return 0
  if tmux -L aid list-clients -F "#{client_tty}" 2>/dev/null \
      | grep -qxF "$AID_CALLER_CLIENT"; then
    printf '%s' "$AID_CALLER_CLIENT"
  fi
}

# _attach_or_switch <session>
# Switch the calling client to <session>.
# Uses AID_CALLER_CLIENT (client tty, e.g. /dev/pts/3) when it is a known aid
# server client, so we always switch the exact right terminal.
_attach_or_switch() {
  local _target_session="$1"
  local _sock _c
  _sock=$(printf '%s' "${TMUX:-}" | cut -d',' -f1)
  if [[ -n "${TMUX:-}" && "$(basename "$_sock")" == "aid" ]]; then
    _c=$(_aid_client_tty)
    if [[ -n "$_c" ]]; then
      tmux -L aid switch-client -c "$_c" -t "$_target_session"
    else
      tmux -L aid switch-client -t "$_target_session"
    fi
  else
    tmux -L aid attach -t "$_target_session"
  fi
}

# ── Prompt for first session ──────────────────────────────────────────────────
# Creates a new session via a series of fzf prompts.
#
# Always runs inside a tmux display-popup so fzf has a real tty.
# When called outside a popup (AID_IN_NEW_POPUP unset), it re-execs itself
# inside one by opening a display-popup running orchestrator.sh --new.
#
# _fzf_prompt <label> <default>
# Single-field fzf prompt: pre-fills <default> as the query; Enter confirms.
# Prints the entered value to stdout.
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
  # If we're not already inside the popup, open one and re-exec --new inside it.
  # Use -c only when AID_CALLER_CLIENT is a connected aid server client.
  if [[ "${AID_IN_NEW_POPUP:-0}" -ne 1 ]]; then
    local _c _c_flag=()
    _c=$(_aid_client_tty)
    [[ -n "$_c" ]] && _c_flag=(-c "$_c")
    tmux -L aid display-popup -E -w 72 -h 20 "${_c_flag[@]}" \
      "AID_IN_NEW_POPUP=1 AID_CALLER_CLIENT=$(printf '%q' "${AID_CALLER_CLIENT:-}") AID_DIR=$(printf '%q' "$AID_DIR") AID_DATA=$(printf '%q' "$AID_DATA") AID_CONFIG=$(printf '%q' "$AID_CONFIG") TMUX=$(printf '%q' "${TMUX:-}") $(printf '%q' "$AID_DIR/lib/orchestrator.sh") --new"
    return
  fi

  local default_project default_slug default_repo
  default_repo="$PWD"
  default_project=$(basename "$PWD" | sed 's/^\.*//' | tr -cs '[:alnum:]-_' '-' | sed 's/-$//')
  # Derive slug from branch name; fall back to "main" if not in a git repo or on a detached HEAD.
  default_slug=$(git -C "$PWD" rev-parse --abbrev-ref HEAD 2>/dev/null \
    | grep -v '^HEAD$' \
    | sed 's|.*/||' | tr -cs '[:alnum:]-_' '-' | sed 's/-$//')
  [[ -z "$default_slug" ]] && default_slug="main"

  _project=$(_fzf_prompt "project" "$default_project") || { echo "aid: cancelled" >&2; exit 1; }
  _project=$(printf '%s' "${_project:-$default_project}" | tr -cs '[:alnum:]-_' '-' | sed 's/-$//')
  [[ -z "$_project" ]] && _project="$default_project"

  _slug=$(_fzf_prompt "session slug" "$default_slug") || { echo "aid: cancelled" >&2; exit 1; }
  _slug=$(printf '%s' "${_slug:-$default_slug}" | tr -cs '[:alnum:]-_' '-' | sed 's/-$//')
  [[ -z "$_slug" ]] && _slug="$default_slug"

  # Repo path: fzf over find output so the user can also navigate with Tab.
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
    | head -1) || { echo "aid: cancelled" >&2; exit 1; }
  _repo="${_repo:-$default_repo}"

  # Expand ~ manually in case the user typed it.
  _repo="${_repo/#\~/$HOME}"

  if [[ ! -d "$_repo" ]]; then
    echo "aid: repo path '$_repo' does not exist" >&2
    exit 1
  fi

  spawn_orc_session "$_project" "$_slug" "$_repo"
}

# ── Main ──────────────────────────────────────────────────────────────────────

_ensure_server

# --new flag: skip the existing-sessions branch and go straight to the prompt.
# Used by aid-sessions ctrl-n to create a new session from inside the navigator.
if [[ "${1:-}" == "--new" ]]; then
  _prompt_new_session
  exit 0
fi

# --resurrect <project> <slug> <repo_path>: re-spawn a dead session from metadata.
# Called by aid-sessions when the user selects a dead session entry.
if [[ "${1:-}" == "--resurrect" ]]; then
  spawn_orc_session "${2:?}" "${3:?}" "${4:?}"
  exit 0
fi

# Check whether there are any sessions to show in the navigator for this
# branch install.  We use aid-sessions-list (which unions live tmux sessions
# with dead entries from the branch's sessions.json) rather than a raw tmux
# count so that sessions owned by other aid installs sharing the same tmux
# server don't falsely prevent the new-session prompt from appearing.
_existing_list=$(AID_SESSIONS_COLLAPSE="" \
  "$AID_DIR/lib/sessions/aid-sessions-list" 2>/dev/null || true)

if [[ -z "$_existing_list" ]]; then
  # No sessions known to this branch install — prompt for a first one.
  _prompt_new_session
else
  # Sessions already exist — open the navigator so the user can pick one or
  # create a new one.
  dbg "existing sessions found, opening navigator"
  # Use display-popup only when the current terminal is a client of the aid
  # server itself.  $TMUX is set both inside the aid server and inside any
  # other tmux server, so we must check the socket name explicitly.
  _in_aid_server=0
  if [[ -n "${TMUX:-}" ]]; then
    _tmux_sock=$(printf '%s' "${TMUX}" | cut -d',' -f1)
    [[ "$(basename "$_tmux_sock")" == "aid" ]] && _in_aid_server=1
  fi
  if [[ "$_in_aid_server" -eq 1 ]]; then
    # Already inside the aid server: open the navigator as a popup overlay.
    # Use -c only when AID_CALLER_CLIENT is a connected aid server client.
    _nav_c=()
    _nav_c_val=$(_aid_client_tty)
    [[ -n "$_nav_c_val" ]] && _nav_c=(-c "$_nav_c_val")
    tmux -L aid display-popup -E -w 70% -h 60% "${_nav_c[@]}" \
      "AID_CALLER_CLIENT=$(printf '%q' "${AID_CALLER_CLIENT:-}") AID_DIR=$(printf '%q' "$AID_DIR") AID_DATA=$(printf '%q' "$AID_DATA") AID_CONFIG=$(printf '%q' "$AID_CONFIG") TMUX=$(printf '%q' "${TMUX:-}") $(printf '%q' "$AID_DIR")/lib/sessions/aid-sessions"
  else
    # Outside the aid server (plain terminal or a different tmux server): run
    # the session navigator directly so the user can pick or create a session.
    "$AID_DIR/lib/sessions/aid-sessions"
  fi
fi
