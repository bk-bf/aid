#!/usr/bin/env bash
# orchestrator.sh — aid --mode orchestrator bootstrap.
#
# Starts the T3/Codex-style multi-session layout on the aid tmux server:
#   - Each opencode context lives in its own tmux session named aid/<project>/<slug>
#   - The session navigator (aid-sessions) is available as a global prefix+s popup
#   - The first invocation creates the dashboard session and prompts for a first context
#
# This script is exec'd by aid.sh when --mode orchestrator is passed.
# All AID_* vars are inherited from aid.sh.

set -euo pipefail

: "${AID_DIR:?}"
: "${AID_DATA:?}"
: "${AID_CONFIG:?}"

dbg() { [[ "${AID_DEBUG:-0}" -eq 1 ]] && echo "[orc:debug] $*" >&2 || true; }

# ── Helpers ───────────────────────────────────────────────────────────────────

# Ensure the aid tmux server is running with the aid config.
# If no sessions exist yet, start the server by creating a scratch session that
# we immediately hide; the real sessions are spawned by spawn_orc_session below.
_ensure_server() {
  if ! tmux -L aid list-sessions &>/dev/null; then
    dbg "starting aid tmux server"
    "$AID_DIR/gen-tmux-palette.sh"
    tmux -L aid -f "$AID_DIR/tmux.conf" new-session -d -s "aid/dashboard" \
      -x "$(tput cols)" -y "$(tput lines)"
    tmux -L aid source-file "$AID_DATA/tmux/palette.conf"
    # Inject shared env vars into the server so every spawned session inherits them.
    tmux -L aid set-environment -g AID_DIR                  "$AID_DIR"
    tmux -L aid set-environment -g AID_DATA                 "$AID_DATA"
    tmux -L aid set-environment -g AID_CONFIG               "$AID_CONFIG"
    tmux -L aid set-environment -g XDG_DATA_HOME            "$AID_DATA"
    tmux -L aid set-environment -g XDG_STATE_HOME           "$HOME/.local/state/aid"
    tmux -L aid set-environment -g XDG_CACHE_HOME           "$HOME/.cache/aid"
    tmux -L aid set-environment -g OPENCODE_CONFIG_DIR      "$AID_DIR/opencode"
    tmux -L aid set-environment -g OPENCODE_TUI_CONFIG      "$AID_DIR/opencode/tui.json"
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
}

# spawn_orc_session <project> <slug> <repo_path>
# Creates a new aid/<project>/<slug> tmux session with the orchestrator 3-pane layout:
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
  local session="aid/${project}/${slug}"

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
  tmux -L aid run-shell -t "$orc_pane_id" "$AID_DIR/ensure_treemux.sh"

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

  # Switch back to window 0 (opencode layout) as the default entry point.
  tmux -L aid select-window -t "${session}:0"

  # Write metadata for the session navigator.
  _write_session_metadata "$project" "$slug" "$repo_path"

  dbg "session $session ready"
  _attach_or_switch "$session"
}

# _write_session_metadata <project> <slug> <repo_path>
# Appends or updates ~/.local/share/aid/sessions.json with this session's metadata.
# Uses a simple jq-based upsert; degrades gracefully if jq is absent.
_write_session_metadata() {
  local project="$1" slug="$2" repo_path="$3"
  local metadata_file="$AID_DATA/sessions.json"
  local tmux_session="aid/${project}/${slug}"
  local branch
  branch=$(git -C "$repo_path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  local now
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")

  if ! command -v jq &>/dev/null; then
    dbg "jq not found — skipping session metadata write"
    return
  fi

  # Ensure the file exists with a valid JSON array.
  [[ -f "$metadata_file" ]] || echo "[]" > "$metadata_file"

  local entry
  entry=$(jq -n \
    --arg session "$tmux_session" \
    --arg repo    "$repo_path" \
    --arg branch  "$branch" \
    --arg created "$now" \
    --arg active  "$now" \
    '{"tmux_session":$session,"repo_path":$repo,"branch":$branch,"created_at":$created,"last_active":$active}')

  # Upsert: remove existing entry for this session, append new one.
  jq --argjson entry "$entry" \
    'map(select(.tmux_session != $entry.tmux_session)) + [$entry]' \
    "$metadata_file" > "${metadata_file}.tmp" && mv "${metadata_file}.tmp" "$metadata_file"

  dbg "metadata written to $metadata_file"
}

# _attach_or_switch <session>
_attach_or_switch() {
  if [[ -n "${TMUX:-}" ]]; then
    tmux -L aid switch-client -t "$1"
  else
    tmux -L aid attach -t "$1"
  fi
}

# ── Prompt for first session ──────────────────────────────────────────────────
# If there are no existing aid/* sessions (other than aid/dashboard), prompt the
# user to create the first one, defaulting to the current directory.

_prompt_new_session() {
  local default_project default_slug default_repo
  default_repo="$PWD"
  default_project=$(basename "$PWD" | sed 's/^\.*//' | tr -cs '[:alnum:]-_' '-' | sed 's/-$//')
  # Derive slug from branch name; fall back to "main" if not in a git repo or on a detached HEAD.
  default_slug=$(git -C "$PWD" rev-parse --abbrev-ref HEAD 2>/dev/null \
    | grep -v '^HEAD$' \
    | sed 's|.*/||' | tr -cs '[:alnum:]-_' '-' | sed 's/-$//')
  [[ -z "$default_slug" ]] && default_slug="main"

  echo ""
  echo "aid orchestrator — new session"
  echo ""
  printf "  project [%s]: " "$default_project"
  read -r _project
  _project="${_project:-$default_project}"

  printf "  session [%s]: " "$default_slug"
  read -r _slug
  _slug="${_slug:-$default_slug}"

  printf "  repo path [%s]: " "$default_repo"
  read -r _repo
  _repo="${_repo:-$default_repo}"

  # Expand ~ manually since read doesn't do shell expansion.
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

# Count existing aid/<project>/<slug> sessions (exclude aid/dashboard).
_existing=$(tmux -L aid list-sessions -F "#{session_name}" 2>/dev/null \
  | grep -cE '^aid/[^/]+/[^/]+$' || true)

if [[ "$_existing" -eq 0 ]]; then
  # First run — prompt for a session and spawn it.
  _prompt_new_session
else
  # Sessions already exist — open the navigator so the user can pick one or
  # create a new one.
  dbg "existing sessions found, opening navigator"
  if [[ -n "${TMUX:-}" ]]; then
    # Already inside tmux: open the navigator as a popup overlay.
    tmux -L aid display-popup -E -w 70% -h 60% \
      "AID_DIR=$(printf '%q' "$AID_DIR") $(printf '%q' "$AID_DIR")/aid-sessions"
  else
    # Outside tmux: attach to the most recently active aid/* session.
    _last=$(tmux -L aid list-sessions -F "#{session_last_attached} #{session_name}" 2>/dev/null \
      | grep -E ' aid/[^/]+/[^/]+$' | sort -rn | head -1 | awk '{print $2}')
    if [[ -n "$_last" ]]; then
      _attach_or_switch "$_last"
    else
      _prompt_new_session
    fi
  fi
fi
