#!/usr/bin/env bash
# aid.sh — main entry point. Symlinked into ~/.local/bin/aid by install.sh.
#
# Isolation: aid runs on its own tmux server socket (-L tdl) with its own
# config (-f), and launches nvim as NVIM_APPNAME=nvim-tdl so it never
# touches the user's ~/.config/nvim or existing tmux sessions.

set -euo pipefail

# Always resolves correctly because this file is executed, not sourced.
TDL_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"

# ── Session routing ──────────────────────────────────────────────────────────
# aid <name>   → attach to that session directly
# aid new      → skip session list, always create a new session
# aid          → attach to the only existing session;
#                if multiple exist, print a list and prompt;
#                if none exist, create a new one (falls through below)

if [[ "${1:-}" == "ls" ]]; then
  tmux -L tdl list-sessions 2>/dev/null || echo "no aid sessions"
  exit
elif [[ "${1:-}" == "new" ]]; then
  shift  # drop "new", fall through to create path
elif [[ -n "${1:-}" ]]; then
  tmux -L tdl attach -t "$1"
  exit
else
  # No argument — check for existing sessions
  mapfile -t _sessions < <(tmux -L tdl list-sessions -F "#{session_name}" 2>/dev/null)
  if [[ ${#_sessions[@]} -eq 1 ]]; then
    tmux -L tdl attach -t "${_sessions[0]}"
    exit
  elif [[ ${#_sessions[@]} -gt 1 ]]; then
    echo "aid sessions:"
    for i in "${!_sessions[@]}"; do
      printf "  [%d] %s\n" "$((i+1))" "${_sessions[$i]}"
    done
    printf "  [n] new session in %s\n" "$PWD"
    printf "attach to [1-%d / n]: " "${#_sessions[@]}"
    read -r _choice
    if [[ "$_choice" == "n" || "$_choice" == "N" ]]; then
      : # fall through to create path
    elif [[ "$_choice" =~ ^[0-9]+$ ]] && (( _choice >= 1 && _choice <= ${#_sessions[@]} )); then
      tmux -L tdl attach -t "${_sessions[$((_choice-1))]}"
      exit
    else
      echo "invalid choice — creating new session"
    fi
  fi
  # zero sessions or user chose 'n': fall through to create
fi

# Capture launch dir before tmux changes context
launch_dir="$PWD"

# Pick a unique session name from current dir (strip leading dots, replace special chars)
base=$(basename "$launch_dir" | sed 's/^\.*//' | tr -cs '[:alnum:]-_' '-' | sed 's/-$//')
[[ -z "$base" ]] && base="dev"
session="aid@$base"
n=2
while tmux -L tdl has-session -t "$session" 2>/dev/null; do
  session="aid@${base}${n}"
  (( n++ ))
done

# Parse .aidignore (walks up from launch_dir) and build TDL_IGNORE=comma,separated,list.
# If no .aidignore is found anywhere, create an empty one in launch_dir so the
# file watcher in nvim has a file to watch from the start.
TDL_IGNORE=""
_aidignore_file=""
_dir="$launch_dir"
for _i in $(seq 1 20); do
  if [[ -f "$_dir/.aidignore" ]]; then
    _aidignore_file="$_dir/.aidignore"
    break
  fi
  _parent="$(dirname "$_dir")"
  [[ "$_parent" == "$_dir" ]] && break
  _dir="$_parent"
done
if [[ -z "$_aidignore_file" ]]; then
  touch "$launch_dir/.aidignore"
  _aidignore_file="$launch_dir/.aidignore"
fi
if [[ -n "$_aidignore_file" ]]; then
  TDL_IGNORE=$(grep -v '^\s*#' "$_aidignore_file" | grep -v '^\s*$' | paste -sd ',')
fi
export TDL_IGNORE

# Start the aid-isolated tmux server with its own config
tmux -L tdl -f "$TDL_DIR/tmux.conf" new-session -d -s "$session" \
  -x "$(tput cols)" -y "$(tput lines)"

# Export TDL_DIR, TDL_IGNORE, and OPENCODE_CONFIG_DIR into the server environment
# so all panes inherit them. OPENCODE_CONFIG_DIR isolates opencode to aid's own
# config dir (commands/, package.json) instead of ~/.config/opencode/.
tmux -L tdl set-environment -g TDL_DIR "$TDL_DIR"
tmux -L tdl set-environment -g TDL_IGNORE "$TDL_IGNORE"
tmux -L tdl set-environment -g OPENCODE_CONFIG_DIR "$TDL_DIR/opencode"
# NVIM_APPNAME in the server environment means every pane shell inherits it —
# no dependency on the send-keys command being delivered intact.
tmux -L tdl set-environment -g NVIM_APPNAME "nvim-tdl"
# TDL_NVIM_SOCKET must be set before ensure_treemux.sh runs so the sidebar nvim
# inherits it at startup and sets g:nvim_tree_remote_socket_path correctly.
nvim_socket="/tmp/tdl-nvim-${session}.sock"
tmux -L tdl set-environment -g TDL_NVIM_SOCKET "$nvim_socket"

# IDE layout sizes — all pane geometry owned here, not scattered in tmux.conf
# sidebar=21 cols set in tmux.conf (must be before sidebar.tmux runs);
# opencode=29% of total width; editor gets the remainder.

# Wait for sidebar.tmux to finish setting @treemux-key-Tab
sleep 1.5

# Find the initial (only) pane and capture its stable ID before any splits.
editor_pane_id=$(tmux -L tdl list-panes -t "$session" -F "#{pane_id}" | head -1)

# Split right: opencode occupies 29% of width, spawned directly into opencode
# (no shell prompt — avoids zsh intercept, send-keys mangling, autocorrect).
tmux -L tdl split-window -h -p 29 -t "$editor_pane_id" \
  "OPENCODE_CONFIG_DIR=$(printf '%q' "$TDL_DIR/opencode") opencode $(printf '%q' "$launch_dir")"
opencode_pane_id=$(tmux -L tdl list-panes -t "$session" -F "#{pane_id} #{pane_left}" \
  | sort -k2 -n | tail -1 | cut -d' ' -f1)
tmux -L tdl select-pane -t "$editor_pane_id"

# Open treemux sidebar: run-shell -t executes inside the aid server with $TMUX
# and $TMUX_PANE set, which toggle.sh's bare tmux calls require.
# Pane IDs are stable — treemux inserting the sidebar won't shift them.
tmux -L tdl run-shell -t "$editor_pane_id" "$TDL_DIR/ensure_treemux.sh"

# Respawn the editor pane directly into the nvim restart loop — bypasses the
# interactive shell entirely so zsh autocorrect / send-keys mangling can't fire.
# The pane is never a bare shell: when the user quits nvim (:q) the loop
# immediately restarts it on the same socket.
# To kill the session entirely: close the tmux window or run `aid kill`.
tmux -L tdl respawn-pane -k -t "$editor_pane_id" \
  "cd $(printf '%q' "$launch_dir") && while true; do rm -f $(printf '%q' "$nvim_socket"); NVIM_APPNAME=nvim-tdl nvim --listen $(printf '%q' "$nvim_socket"); done"

tmux -L tdl attach -t "$session"
