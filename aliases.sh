#!/usr/bin/env bash
# tdl/aliases.sh — sourced by ~/.config/.aliases
# All tdl IDE shell behaviour lives here.

# dev layout: treemux (left) | nvim + terminal (middle) | opencode (right)
# usage: tdl          → create new session in current directory
#        tdl <name>   → attach to existing named session
tdl() {
  if [[ -n "$1" ]]; then
    tmux attach -t "$1"
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
  while tmux has-session -t "$session" 2>/dev/null; do
    session="nvim@${base}${n}"
    (( n++ ))
  done
  tmux new-session -d -s "$session" -x "$(tput cols)" -y "$(tput lines)"
  # IDE layout sizes — all pane geometry owned here, not scattered in tmux.conf
  # sidebar=21, right (opencode)=29% of total width; editor gets the remainder
  tmux set-option -t "$session" @treemux-tree-width 21
  sleep 1.5
  local main_pane
  main_pane=$(tmux list-panes -t "$session" -F "#{pane_index} #{pane_width}" | sort -k2 -n | tail -1 | cut -d' ' -f1)
  tmux split-window -h -p 29 -t "$session:0.$main_pane"
  tmux send-keys -t "$session:0.$((main_pane + 1))" "opencode $launch_dir" Enter
  tmux select-pane -t "$session:0.$main_pane"
  tmux send-keys -t "$session:0.$main_pane" "cd $launch_dir && nvim" Enter
  tmux attach -t "$session"
}

# Auto-open treemux sidebar whenever nvim is launched inside a tmux session.
# Outside tmux (TMUX unset) it's a transparent pass-through.
nvim() {
  if [[ -n "$TMUX" ]]; then
    ~/.config/tmux/ensure_treemux.sh
  fi
  command nvim "$@"
}
