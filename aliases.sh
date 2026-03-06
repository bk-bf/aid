#!/usr/bin/env bash
# tdl/aliases.sh — sourced by ~/.config/.aliases
# All tdl IDE shell behaviour lives here.
#
# Isolation: tdl runs on its own tmux server socket (-L tdl) with its own
# config (-f), and launches nvim as NVIM_APPNAME=nvim-tdl so it never
# touches the user's ~/.config/nvim or existing tmux sessions.

# Resolve the tdl repo dir from this file's location (works after source too)
_TDL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# dev layout: treemux (left) | nvim + terminal (middle) | opencode (right)
# usage: tdl          → create new session in current directory
#        tdl <name>   → attach to existing named session
tdl() {
  if [[ -n "$1" ]]; then
    tmux -L tdl attach -t "$1"
    return
  fi
  # capture launch dir before tmux changes context
  local launch_dir="$PWD"
  # pick a unique session name from current dir (strip leading dots, replace special chars)
  local base session
  base=$(basename "$launch_dir" | sed 's/^\.*//' | tr -cs '[:alnum:]-_' '-' | sed 's/-$//')
  [[ -z "$base" ]] && base="dev"
  session="nvim@$base"
  local n=2
  while tmux -L tdl has-session -t "$session" 2>/dev/null; do
    session="nvim@${base}${n}"
    (( n++ ))
  done

  # Start the tdl-isolated tmux server with its own config
  tmux -L tdl -f "$_TDL_DIR/tmux.conf" new-session -d -s "$session" \
    -x "$(tput cols)" -y "$(tput lines)"

  # Export TDL_DIR into the server environment so tmux.conf's bind r can reference it
  tmux -L tdl set-environment -g TDL_DIR "$_TDL_DIR"

  # IDE layout sizes — all pane geometry owned here, not scattered in tmux.conf
  # sidebar=21, right (opencode)=28% of total width; editor gets the remainder
  tmux -L tdl set-option -t "$session" @treemux-tree-width 21
  # Wait for sidebar.tmux to finish setting @treemux-key-Tab, then open treemux.
  # The session-created hook also calls ensure_treemux.sh but may race; this is
  # the authoritative call that runs after plugins have had time to initialise.
  sleep 1.5
  local main_pane
  main_pane=$(tmux -L tdl list-panes -t "$session" -F "#{pane_index} #{pane_width}" \
    | sort -k2 -n | tail -1 | cut -d' ' -f1)
  tmux -L tdl split-window -h -p 29 -t "$session:0.$main_pane"
  tmux -L tdl send-keys -t "$session:0.$((main_pane + 1))" "opencode $launch_dir" Enter
  tmux -L tdl select-pane -t "$session:0.$main_pane"
  # Open treemux sidebar: send ensure_treemux.sh to the main pane so it runs
  # inside the session with correct $TMUX context (required by toggle.sh).
  tmux -L tdl send-keys -t "$session:0.$main_pane" \
    "$_TDL_DIR/ensure_treemux.sh" Enter
  tmux -L tdl send-keys -t "$session:0.$main_pane" \
    "cd $launch_dir && NVIM_APPNAME=nvim-tdl nvim" Enter
  tmux -L tdl attach -t "$session"
}
