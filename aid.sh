#!/usr/bin/env bash
# aid.sh — main entry point. Symlinked to ~/.local/bin/aid by install.sh.
# See docs/ARCHITECTURE.md for the full isolation and boot-sequence docs.

set -euo pipefail

AID_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
AID_IGNORE=""
XDG_DATA_HOME="$HOME/.local/share/aid"
XDG_STATE_HOME="$HOME/.local/state/aid"
XDG_CACHE_HOME="$HOME/.cache/aid"
OPENCODE_CONFIG_DIR="$AID_DIR/opencode"
OPENCODE_TUI_CONFIG="$AID_DIR/opencode/tui.json"
LG_CONFIG_FILE="$HOME/.config/aid/lazygit/config.yml"
# tmux/plugins/ lives inside AID_DIR (not XDG_DATA_HOME) — the repo is self-contained.
# See docs/DECISIONS.md § ADR-014 if you want to reconsider moving plugins to XDG_DATA_HOME.
TMUX_PLUGIN_MANAGER_PATH="$AID_DIR/tmux/plugins/"

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
    tmux -L aid switch-client -t "$1"
  else
    tmux -L aid attach -t "$1"
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
  aid -i, --install     (re)run install.sh — install/update plugins and symlinks
  aid -l, --list        list running sessions
  aid -d, --debug       verbose output (set -x + step tracing)
  aid -h, --help        show this help
EOF
    exit
    ;;
  -l|--list)
    tmux -L aid list-sessions 2>/dev/null || echo "no aid sessions"
    exit
    ;;
  -i|--install)
    exec "$AID_DIR/boot.sh"
    ;;
  -a|--attach)
    shift
    if [[ -n "${1:-}" ]]; then
      # aid -a <name>
      attach_or_switch "$1"
      exit
    fi
    # aid -a with no name — interactive list
    mapfile -t _sessions < <(tmux -L aid list-sessions -F "#{session_name}" 2>/dev/null)
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

# Regenerate tmux/palette.conf from nvim/lua/palette.lua before the server starts.
# This keeps the tmux status bar in sync with the Lua palette without duplicating hex values.
"$AID_DIR/gen-tmux-palette.sh"

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
while tmux -L aid has-session -t "$session" 2>/dev/null; do
  session="aid@${base}${n}"
  (( n++ ))
done
dbg "session=$session"

# Bootstrap project files from templates on first run.
# Each file is only written if it does not already exist anywhere in the
# directory walk — existing files are never overwritten.
_tmpl_dir="$AID_DIR/nvim/templates"
_bootstrap_file() {
  local name="$1" found=0 dir="$launch_dir"
  for _i in $(seq 1 20); do
    [[ -f "$dir/$name" ]] && { found=1; break; }
    local parent; parent="$(dirname "$dir")"
    [[ "$parent" == "$dir" ]] && break
    dir="$parent"
  done
  if (( found == 0 )); then
    cp "$_tmpl_dir/$name" "$launch_dir/$name"
    dbg "bootstrapped $name from template"
  fi
}
_bootstrap_file ".aidignore"
_bootstrap_file ".nvim.lua"
_bootstrap_file "opencode.json"

# Parse .aidignore (walks up from launch_dir) and build AID_IGNORE=comma,separated,list.
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
  # Template copy above guarantees the file exists; this is a safety fallback.
  _aidignore_file="$launch_dir/.aidignore"
fi
if [[ -n "$_aidignore_file" ]]; then
  AID_IGNORE=$(grep -v '^\s*#' "$_aidignore_file" | grep -v '^\s*$' | paste -sd ',' || true)
fi
export AID_IGNORE
dbg "aidignore=$_aidignore_file AID_IGNORE=${AID_IGNORE:-<empty>}"

# Start the aid-isolated tmux server with its own config.
# Note: source-file in tmux.conf cannot expand #{E:VAR} format strings in its
# path argument (tmux limitation) — palette.conf is sourced explicitly below
# after the server is up, using the real $AID_DIR path.
dbg "starting tmux session"
tmux -L aid -f "$AID_DIR/tmux.conf" new-session -d -s "$session" \
  -x "$(tput cols)" -y "$(tput lines)"

# Apply the palette now that the server is running and we have the real path.
# Must come before set-environment block so status bar colours are correct
# immediately on attach.
tmux -L aid source-file "$AID_DIR/tmux/palette.conf"

# Set status-left/right to the vimbridge cat strings session-locally.
# palette.conf uses set -g (global) so sourcing it again later (prefix+r) won't
# clobber these session-local values.
# tpipeline_restore is disabled — no save/restore on focus changes needed.
# The bar always reads from the vimbridge files via #(cat ...) regardless of
# which pane is focused; nvim keeps the files updated continuously.
tmux -L aid set-option -t "$session" status-left  "#(cat #{socket_path}-\#{session_id}-vimbridge)"
tmux -L aid set-option -t "$session" status-right "#(cat #{socket_path}-\#{session_id}-vimbridge-R)"

# Pre-seed the vimbridge files with a placeholder so #(cat ...) never returns
# empty during the nvim startup window (empty cat output causes tmux to fall
# back to the global status-left, showing only the session name).
_tmux_socket=$(tmux -L aid display-message -t "$session" -p "#{socket_path}")
_session_id=$(tmux -L aid display-message -t "$session" -p "#{session_id}")
printf ' ' > "${_tmux_socket}-${_session_id}-vimbridge"
printf ' ' > "${_tmux_socket}-${_session_id}-vimbridge-R"

# Export key vars into the tmux server so every pane inherits them.
# XDG_CONFIG_HOME is intentionally absent — setting it globally would make
# every pane shell treat $AID_DIR as its config home (see ARCHITECTURE.md).
# It is injected inline only on the nvim respawn-pane command below.
tmux -L aid set-environment -g AID_DIR                  "$AID_DIR"
tmux -L aid set-environment -g AID_IGNORE               "$AID_IGNORE"
tmux -L aid set-environment -g XDG_DATA_HOME            "$XDG_DATA_HOME"
tmux -L aid set-environment -g XDG_STATE_HOME           "$XDG_STATE_HOME"
tmux -L aid set-environment -g XDG_CACHE_HOME           "$XDG_CACHE_HOME"
tmux -L aid set-environment -g OPENCODE_CONFIG_DIR      "$OPENCODE_CONFIG_DIR"
tmux -L aid set-environment -g OPENCODE_TUI_CONFIG      "$OPENCODE_TUI_CONFIG"
tmux -L aid set-environment -g TMUX_PLUGIN_MANAGER_PATH "$TMUX_PLUGIN_MANAGER_PATH"
# NVIM_APPNAME in the server environment means every pane shell inherits it.
tmux -L aid set-environment -g NVIM_APPNAME "nvim"
# AID_NVIM_SOCKET: session-local so concurrent sessions each target their own nvim.
nvim_socket="/tmp/aid-nvim-${session}.sock"
tmux -L aid set-environment -t "$session" AID_NVIM_SOCKET "$nvim_socket"
dbg "nvim_socket=$nvim_socket"

# sidebar.tmux (run via TPM) targets the default tmux socket, not -L aid, so
# @treemux-key-Tab is never written to the aid server. Set it directly here.
_tmx() { tmux -L aid show-option -gqv "$1"; }
_treemux_args="$(_tmx @treemux-nvim-command),$(_tmx @treemux-tree-nvim-init-file),,$(_tmx @treemux-python-command),left,$(_tmx @treemux-tree-width),top,70%,editor,0.5,2,5,0,,$(_tmx @treemux-tree-client)"
_treemux_args_focus="$(_tmx @treemux-nvim-command),$(_tmx @treemux-tree-nvim-init-file),,$(_tmx @treemux-python-command),left,$(_tmx @treemux-tree-width),top,70%,editor,0.5,2,5,0,focus,$(_tmx @treemux-tree-client)"
tmux -L aid set-option -gq "@treemux-key-Tab"    "${_treemux_args}"
tmux -L aid set-option -gq "@treemux-key-Bspace" "${_treemux_args_focus}"
dbg "treemux-key-Tab=${_treemux_args}"

# IDE layout sizes — all pane geometry owned here, not scattered in tmux.conf
# sidebar=21 cols set in tmux.conf (must be before sidebar.tmux runs);
# opencode=29% of total width; editor gets the remainder.

# Find the initial (only) pane and capture its stable ID before any splits.
editor_pane_id=$(tmux -L aid list-panes -t "$session" -F "#{pane_id}" | head -1)
dbg "editor_pane_id=$editor_pane_id"

# Split right: opencode occupies 29% of width, spawned directly into opencode
# (no shell prompt — avoids zsh intercept, send-keys mangling, autocorrect).
dbg "splitting opencode pane"
tmux -L aid split-window -h -p 29 -t "$editor_pane_id" \
  "OPENCODE_CONFIG_DIR=$(printf '%q' "$OPENCODE_CONFIG_DIR") OPENCODE_TUI_CONFIG=$(printf '%q' "$OPENCODE_TUI_CONFIG") opencode $(printf '%q' "$launch_dir")"
opencode_pane_id=$(tmux -L aid list-panes -t "$session" -F "#{pane_id} #{pane_left}" \
  | sort -k2 -n | tail -1 | cut -d' ' -f1)
dbg "opencode_pane_id=$opencode_pane_id"
tmux -L aid select-pane -t "$editor_pane_id"

# Open treemux sidebar: run-shell -t executes inside the aid server with $TMUX
# and $TMUX_PANE set, which toggle.sh's bare tmux calls require.
# Pane IDs are stable — treemux inserting the sidebar won't shift them.
dbg "running ensure_treemux.sh"
tmux -L aid run-shell -t "$editor_pane_id" "$AID_DIR/ensure_treemux.sh"

# Respawn the editor pane directly into the nvim restart loop — bypasses the
# interactive shell entirely so zsh autocorrect / send-keys mangling can't fire.
# The pane is never a bare shell: when the user quits nvim (:q) the loop
# immediately restarts it on the same socket.
# To kill the session entirely: close the tmux window or run `aid kill`.
dbg "respawning editor pane into nvim loop"
tmux -L aid respawn-pane -k -t "$editor_pane_id" \
  "cd $(printf '%q' "$launch_dir") && while true; do rm -f $(printf '%q' "$nvim_socket"); XDG_CONFIG_HOME=$(printf '%q' "$AID_DIR") XDG_DATA_HOME=$(printf '%q' "$XDG_DATA_HOME") XDG_STATE_HOME=$(printf '%q' "$XDG_STATE_HOME") XDG_CACHE_HOME=$(printf '%q' "$XDG_CACHE_HOME") LG_CONFIG_FILE=$(printf '%q' "$LG_CONFIG_FILE") NVIM_APPNAME=nvim nvim --listen $(printf '%q' "$nvim_socket"); done"

dbg "attaching to session=$session"
attach_or_switch "$session"
