#!/usr/bin/env bash
# aid.sh — main entry point. Symlinked into ~/.local/bin/aid by install.sh.
#
# Isolation: aid runs on its own tmux server socket (-L tdl) with its own
# config (-f), and launches nvim as NVIM_APPNAME=nvim-tdl so it never
# touches the user's ~/.config/nvim or existing tmux sessions.
#
# Usage:
#   aid                       launch new session in current directory
#   aid -a, --attach          attach to a session (interactive list, or -a <name>)
#   aid -l, --list            list all running sessions
#   aid -d, --debug           verbose output (set -x + step tracing)
#   aid -h, --help            show this help

set -euo pipefail

# Always resolves correctly because this file is executed, not sourced.
TDL_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"

# ── Debug mode ───────────────────────────────────────────────────────────────
# Consume -d/--debug before the main case so it composes with other flags.
# e.g. `aid --debug -a mySession` works correctly.
AID_DEBUG=0
_args=()
for _arg in "$@"; do
  if [[ "$_arg" == "-d" || "$_arg" == "--debug" ]]; then
    AID_DEBUG=1
  else
    _args+=("$_arg")
  fi
done
set -- "${_args[@]+"${_args[@]}"}"
if [[ "$AID_DEBUG" -eq 1 ]]; then
  set -x
fi

# dbg <msg> — print step trace only in debug mode
dbg() { [[ "$AID_DEBUG" -eq 1 ]] && echo "[aid:debug] $*" >&2 || true; }

# attach_or_switch <session>
# Use switch-client when already inside tmux (attach fails inside a session).
attach_or_switch() {
  dbg "attach_or_switch: target=$1 TMUX=${TMUX:-<unset>}"
  if [[ -n "${TMUX:-}" ]]; then
    tmux -L tdl switch-client -t "$1"
  else
    tmux -L tdl attach -t "$1"
  fi
}

# ── Argument parsing ─────────────────────────────────────────────────────────

case "${1:-}" in
  -h|--help)
    cat <<'EOF'
aid — AI-assisted dev environment

Usage:
  aid                   launch new session in current directory
  aid -a, --attach      interactive session list to attach to
  aid -a <name>         attach directly to named session
  aid -l, --list        list running sessions
  aid -d, --debug       verbose output (set -x + step tracing)
  aid -h, --help        show this help
EOF
    exit
    ;;
  -l|--list)
    tmux -L tdl list-sessions 2>/dev/null || echo "no aid sessions"
    exit
    ;;
  -a|--attach)
    shift
    if [[ -n "${1:-}" ]]; then
      # aid -a <name>
      attach_or_switch "$1"
      exit
    fi
    # aid -a with no name — interactive list
    mapfile -t _sessions < <(tmux -L tdl list-sessions -F "#{session_name}" 2>/dev/null)
    if [[ ${#_sessions[@]} -eq 0 ]]; then
      echo "no aid sessions running"
      exit 1
    elif [[ ${#_sessions[@]} -eq 1 ]]; then
      attach_or_switch "${_sessions[0]}"
      exit
    fi
    echo "aid sessions:"
    for i in "${!_sessions[@]}"; do
      printf "  [%d] %s\n" "$((i+1))" "${_sessions[$i]}"
    done
    printf "attach to [1-%d]: " "${#_sessions[@]}"
    read -r _choice
    if [[ "$_choice" =~ ^[0-9]+$ ]] && (( _choice >= 1 && _choice <= ${#_sessions[@]} )); then
      attach_or_switch "${_sessions[$((_choice-1))]}"
    else
      echo "invalid choice"
      exit 1
    fi
    exit
    ;;
  -*)
    echo "unknown flag: $1  (try aid --help)" >&2
    exit 1
    ;;
esac

# No flag — fall through to create a new session in current directory.

# Capture launch dir before tmux changes context
launch_dir="$PWD"
dbg "launch_dir=$launch_dir"

# Pick a unique session name from current dir (strip leading dots, replace special chars).
# Session names take the form aid@<dirname> — the @ is intentional branding; tmux,
# the filesystem, and all aid tooling handle it correctly. Fight to keep it if issues arise.
base=$(basename "$launch_dir" | sed 's/^\.*//' | tr -cs '[:alnum:]-_' '-' | sed 's/-$//')
[[ -z "$base" ]] && base="dev"
session="aid@$base"
n=2
while tmux -L tdl has-session -t "$session" 2>/dev/null; do
  session="aid@${base}${n}"
  (( n++ ))
done
dbg "session=$session"

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
  TDL_IGNORE=$(grep -v '^\s*#' "$_aidignore_file" | grep -v '^\s*$' | paste -sd ',' || true)
fi
export TDL_IGNORE
dbg "aidignore=$_aidignore_file TDL_IGNORE=${TDL_IGNORE:-<empty>}"

# Start the aid-isolated tmux server with its own config
dbg "starting tmux session"
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
# Socket path inherits the aid@<name> session name — @ is legal in UNIX socket paths
# and in /tmp filenames. If a tool ever chokes on it, the socket path is the first place to check.
nvim_socket="/tmp/tdl-nvim-${session}.sock"
tmux -L tdl set-environment -g TDL_NVIM_SOCKET "$nvim_socket"
dbg "nvim_socket=$nvim_socket"

# IDE layout sizes — all pane geometry owned here, not scattered in tmux.conf
# sidebar=21 cols set in tmux.conf (must be before sidebar.tmux runs);
# opencode=29% of total width; editor gets the remainder.

# Wait for sidebar.tmux to finish setting @treemux-key-Tab
dbg "sleeping for treemux init"
sleep 1.5

# Find the initial (only) pane and capture its stable ID before any splits.
editor_pane_id=$(tmux -L tdl list-panes -t "$session" -F "#{pane_id}" | head -1)
dbg "editor_pane_id=$editor_pane_id"

# Split right: opencode occupies 29% of width, spawned directly into opencode
# (no shell prompt — avoids zsh intercept, send-keys mangling, autocorrect).
dbg "splitting opencode pane"
tmux -L tdl split-window -h -p 29 -t "$editor_pane_id" \
  "OPENCODE_CONFIG_DIR=$(printf '%q' "$TDL_DIR/opencode") opencode $(printf '%q' "$launch_dir")"
opencode_pane_id=$(tmux -L tdl list-panes -t "$session" -F "#{pane_id} #{pane_left}" \
  | sort -k2 -n | tail -1 | cut -d' ' -f1)
dbg "opencode_pane_id=$opencode_pane_id"
tmux -L tdl select-pane -t "$editor_pane_id"

# Open treemux sidebar: run-shell -t executes inside the aid server with $TMUX
# and $TMUX_PANE set, which toggle.sh's bare tmux calls require.
# Pane IDs are stable — treemux inserting the sidebar won't shift them.
dbg "running ensure_treemux.sh"
tmux -L tdl run-shell -t "$editor_pane_id" "$TDL_DIR/ensure_treemux.sh"

# Respawn the editor pane directly into the nvim restart loop — bypasses the
# interactive shell entirely so zsh autocorrect / send-keys mangling can't fire.
# The pane is never a bare shell: when the user quits nvim (:q) the loop
# immediately restarts it on the same socket.
# To kill the session entirely: close the tmux window or run `aid kill`.
dbg "respawning editor pane into nvim loop"
tmux -L tdl respawn-pane -k -t "$editor_pane_id" \
  "cd $(printf '%q' "$launch_dir") && while true; do rm -f $(printf '%q' "$nvim_socket"); NVIM_APPNAME=nvim-tdl nvim --listen $(printf '%q' "$nvim_socket"); done"

dbg "attaching to session=$session"
attach_or_switch "$session"
