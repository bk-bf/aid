#!/usr/bin/env bash
# aid.sh — main entry point. Symlinked to ~/.local/bin/aid by install.sh.
# See docs/ARCHITECTURE.md for the full isolation and boot-sequence docs.

set -euo pipefail

AID_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
AID_IGNORE=""
# AID_DATA — runtime artifact root (tmux plugins, palette.conf, nvim plugin data).
# Always under ~/.local/share/aid[/<branch>]; never the source dir.
# For end users AID_DIR === AID_DATA (boot.sh installs source into ~/.local/share/aid).
# For branch sessions AID_DATA is set before re-exec and inherited here.
AID_DATA="${AID_DATA:-$HOME/.local/share/aid}"
AID_CONFIG="${AID_CONFIG:-$HOME/.config/aid}"
XDG_STATE_HOME="$HOME/.local/state/aid"
XDG_CACHE_HOME="$HOME/.cache/aid"
OPENCODE_CONFIG_DIR="$AID_DIR/opencode"
OPENCODE_TUI_CONFIG="$AID_DIR/opencode/tui.json"

# ── Debug mode + branch + no-ai pre-pass ─────────────────────────────────────
# Consume -d/--debug, --branch, and --no-ai before the main case so they
# compose with other flags.  e.g. `aid --no-ai --debug --branch T-009` works.
# AID_BRANCH="" means flag absent; AID_BRANCH="__interactive__" means --branch
# with no value (show interactive remote branch picker).
AID_DEBUG=0
AID_NO_AI=0
AID_BRANCH=""
AID_MODE=""
_args=()
_skip_next=0
_skip_next_for=""
for _arg in "$@"; do
  if [[ "$_skip_next" -eq 1 ]]; then
    # Next token after --branch or --mode: could be another flag (starts with -)
    # or a positional arg that is the value.  If it looks like a flag, treat
    # the preceding option as bare/interactive and re-process this token.
    if [[ "$_arg" == -* ]]; then
      if [[ "$_skip_next_for" == "branch" ]]; then
        AID_BRANCH="__interactive__"
      fi
      _skip_next=0
      _skip_next_for=""
      # Fall through to re-process _arg in the case below.
    else
      if [[ "$_skip_next_for" == "branch" ]]; then
        AID_BRANCH="$_arg"
      elif [[ "$_skip_next_for" == "mode" ]]; then
        AID_MODE="$_arg"
      fi
      _skip_next=0
      _skip_next_for=""
      continue
    fi
  fi
  case "$_arg" in
    -d|--debug)
      AID_DEBUG=1 ;;
    --no-ai)
      AID_NO_AI=1 ;;
    --branch)
      # value expected as next arg
      _skip_next=1
      _skip_next_for="branch" ;;
    --branch=*)
      AID_BRANCH="${_arg#*=}"
      [[ -z "$AID_BRANCH" ]] && AID_BRANCH="__interactive__" ;;
    --mode)
      _skip_next=1
      _skip_next_for="mode" ;;
    --mode=*)
      AID_MODE="${_arg#*=}" ;;
    *)
      _args+=("$_arg") ;;
  esac
done
# --branch at end of args with nothing following → interactive
if [[ "$_skip_next" -eq 1 && "$_skip_next_for" == "branch" ]]; then
  AID_BRANCH="__interactive__"
fi
set -- "${_args[@]+"${_args[@]}"}"
if [[ "$AID_DEBUG" -eq 1 ]]; then
  set -x
fi

# ── Branch re-exec ────────────────────────────────────────────────────────────
# If --branch was given, clone/update ~/.local/share/aid/<branch> from the same
# remote as the current install, bootstrap on first use, then re-exec into that
# branch's aid.sh forwarding all remaining args.
# --branch main is a no-op (you're already on main).
# --branch with no value: list remote branches interactively.
if [[ -n "$AID_BRANCH" ]]; then
  _remote_url="$(git -C "$AID_DIR" remote get-url origin 2>/dev/null || true)"
  if [[ -z "$_remote_url" ]]; then
    echo "aid: cannot determine remote URL (no 'origin' remote in $AID_DIR)" >&2
    exit 1
  fi

  # Interactive branch picker when no branch name was supplied.
  if [[ "$AID_BRANCH" == "__interactive__" ]]; then
    # List remote branches, strip 'origin/' prefix, exclude main and dev-docs.
    mapfile -t _branches < <(
      git -C "$AID_DIR" ls-remote --heads origin \
        | awk '{sub(/refs\/heads\//, "", $2); print $2}' \
        | grep -v -E '^(main|dev-docs)$'
    )
    if [[ ${#_branches[@]} -eq 0 ]]; then
      echo "aid: no feature branches found on remote"
      exit 0
    fi
    echo "available branches:"
    for i in "${!_branches[@]}"; do
      # Mark branches that already have a local install
      _mark=""
      [[ -d "$HOME/.local/share/aid/${_branches[$i]}" ]] && _mark=" (installed)"
      printf "  [%d] %s%s\n" "$((i+1))" "${_branches[$i]}" "$_mark"
    done
    printf "branch [1-%d]: " "${#_branches[@]}"
    read -r _choice
    if [[ "$_choice" =~ ^[0-9]+$ ]] && (( _choice >= 1 && _choice <= ${#_branches[@]} )); then
      AID_BRANCH="${_branches[$((_choice-1))]}"
    else
      echo "aid: invalid choice" >&2
      exit 1
    fi
  fi

  if [[ "$AID_BRANCH" == "main" ]]; then
    echo "aid: already on main — nothing to do" >&2
    exit 0
  fi

  _branch_dir="$HOME/.local/share/aid/${AID_BRANCH}"
  if [[ -d "$_branch_dir" ]]; then
    echo "aid: updating branch '${AID_BRANCH}' at ${_branch_dir} ..."
    git -C "$_branch_dir" pull
  else
    echo "aid: cloning branch '${AID_BRANCH}' from ${_remote_url} ..."
    if ! git clone --branch "$AID_BRANCH" --single-branch "$_remote_url" "$_branch_dir"; then
      echo "aid: branch '${AID_BRANCH}' not found on remote" >&2
      exit 1
    fi
  fi
  _branch_aid="$_branch_dir/aid.sh"
  if [[ ! -x "$_branch_aid" ]]; then
    echo "aid: no executable aid.sh found in branch dir '${_branch_dir}'" >&2
    exit 1
  fi
  # Isolated runtime dirs — source is the cloned branch dir (AID_DATA == AID_DIR
  # for branch installs, same as the production convention), personal config in
  # ~/.config/aid/<branch>.
  export AID_DATA="$_branch_dir"
  export AID_CONFIG="$HOME/.config/aid/${AID_BRANCH}"
  # Auto-bootstrap on first use.
  if [[ ! -d "$AID_DATA/tmux/plugins/tpm" ]]; then
    echo "aid: first run for branch '${AID_BRANCH}' — bootstrapping ${AID_DATA} ..."
    AID_DATA="$AID_DATA" AID_CONFIG="$AID_CONFIG" bash "$_branch_dir/install.sh"
  fi
  # Re-build the arg list: restore pre-pass flags, then append remaining args.
  _fwd=()
  [[ "$AID_DEBUG" -eq 1 ]]  && _fwd+=("--debug")
  [[ -n "$AID_MODE" ]]       && _fwd+=("--mode" "$AID_MODE")
  [[ "$AID_NO_AI" -eq 1 ]]  && _fwd+=("--no-ai")
  _fwd+=("$@")
  exec "$_branch_aid" "${_fwd[@]+"${_fwd[@]}"}"
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
  aid                        launch new session in current directory
  aid --no-ai                launch without opencode; orc window is also skipped
  aid -a, --attach           interactive session list to attach to
  aid -a <name>              attach directly to named session
  aid -i, --install          (re)run install.sh — install/update plugins and symlinks
  aid --update               pull latest aid + re-run install.sh (alias for -i)
  aid -l, --list             list running sessions
  aid --branch <name>        run a remote branch of aid in its own isolated install
                               clones/updates ~/.local/share/aid/<name> from origin,
                               bootstraps on first use, then re-execs into that aid.sh.
                               Useful for testing feature branches before they land in main.
  aid -d, --debug            verbose output (set -x + step tracing)
  aid -h, --help             show this help

Layout:
  Each session has two windows toggled with prefix+1 / prefix+2:
    1 (ide) — sidebar + nvim + opencode
    2 (orc) — navigator + opencode (with HTTP API) + diff
EOF
    exit
    ;;
  -l|--list)
    tmux -L aid list-sessions 2>/dev/null || echo "no aid sessions"
    exit
    ;;
  -i|--install|--update)
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
"$AID_DIR/lib/gen-tmux-palette.sh"

# Capture launch dir before tmux changes context
launch_dir="$PWD"
dbg "launch_dir=$launch_dir"

# Pick a unique session name from current dir (strip leading dots, replace special chars).
# Session names take the form <prefix>@<dirname> — the @ is intentional branding; tmux,
# the filesystem, and all aid tooling handle it correctly. Fight to keep it if issues arise.
# The prefix is derived from the running git branch: main → "aid", any other branch → branch name.
_aid_branch="$(git -C "$AID_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
[[ "$_aid_branch" == "main" || "$_aid_branch" == "HEAD" || -z "$_aid_branch" ]] && _aid_branch="aid"
base=$(basename "$launch_dir" | sed 's/^\.*//' | tr -cs '[:alnum:]-_' '-' | sed 's/-$//')
[[ -z "$base" ]] && base="dev"
session="${_aid_branch}@$base"
n=2
while tmux -L aid has-session -t "$session" 2>/dev/null; do
  session="${_aid_branch}@${base}${n}"
  (( n++ ))
done
dbg "session=$session"

# Bootstrap project files from templates on first run.
# Each file is only written if it does not already exist anywhere in the
# directory walk — existing files are never overwritten.
_tmpl_dir="$AID_DIR/nvim/templates"
_bootstrap_file() {
  local name="$1" found=0 dir="$launch_dir"
  for _i in {1..20}; do
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
for _i in {1..20}; do
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
tmux -L aid source-file "$AID_DATA/tmux/palette.conf"

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
tmux -L aid set-environment -g AID_DATA                 "$AID_DATA"
tmux -L aid set-environment -g AID_CONFIG               "$AID_CONFIG"
tmux -L aid set-environment -g AID_IGNORE               "$AID_IGNORE"
tmux -L aid set-environment -g XDG_DATA_HOME            "$AID_DATA"
tmux -L aid set-environment -g XDG_STATE_HOME           "$XDG_STATE_HOME"
tmux -L aid set-environment -g XDG_CACHE_HOME           "$XDG_CACHE_HOME"
tmux -L aid set-environment -g OPENCODE_CONFIG_DIR      "$OPENCODE_CONFIG_DIR"
tmux -L aid set-environment -g OPENCODE_TUI_CONFIG      "$OPENCODE_TUI_CONFIG"
tmux -L aid set-environment -g TMUX_PLUGIN_MANAGER_PATH "$AID_DATA/tmux/plugins/"
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
# Skipped when --no-ai is set (T-009).
if [[ "$AID_NO_AI" -eq 0 ]]; then
  dbg "splitting opencode pane"
  tmux -L aid split-window -h -p 29 -t "$editor_pane_id" \
    "OPENCODE_CONFIG_DIR=$(printf '%q' "$OPENCODE_CONFIG_DIR") OPENCODE_TUI_CONFIG=$(printf '%q' "$OPENCODE_TUI_CONFIG") opencode $(printf '%q' "$launch_dir")"
  dbg "opencode_pane_id=$(tmux -L aid list-panes -t "$session" -F "#{pane_id} #{pane_left}" | sort -k2 -n | tail -1 | cut -d' ' -f1)"
  tmux -L aid select-pane -t "$editor_pane_id"
else
  dbg "--no-ai set: skipping opencode pane"
fi

# Open treemux sidebar: run-shell -t executes inside the aid server with $TMUX
# and $TMUX_PANE set, which toggle.sh's bare tmux calls require.
# Pane IDs are stable — treemux inserting the sidebar won't shift them.
dbg "running ensure_treemux.sh"
tmux -L aid run-shell -t "$editor_pane_id" "$AID_DIR/lib/ensure_treemux.sh"

# Respawn the editor pane directly into the nvim restart loop — bypasses the
# interactive shell entirely so zsh autocorrect / send-keys mangling can't fire.
# The pane is never a bare shell: when the user quits nvim (:q) the loop
# immediately restarts it on the same socket.
# To kill the session entirely: close the tmux window or run `aid kill`.
dbg "respawning editor pane into nvim loop"
tmux -L aid respawn-pane -k -t "$editor_pane_id" \
  "cd $(printf '%q' "$launch_dir") && while true; do rm -f $(printf '%q' "$nvim_socket"); XDG_CONFIG_HOME=$(printf '%q' "$AID_DIR") XDG_DATA_HOME=$(printf '%q' "$AID_DATA") XDG_STATE_HOME=$(printf '%q' "$XDG_STATE_HOME") XDG_CACHE_HOME=$(printf '%q' "$XDG_CACHE_HOME") LG_CONFIG_FILE=$(printf '%q' "$AID_CONFIG/lazygit/config.yml") NVIM_APPNAME=nvim nvim --listen $(printf '%q' "$nvim_socket"); done"

# ── Window 1: orchestrator layout (nav | opencode | diff) ────────────────────
# Skipped when --no-ai is set — the orc window requires opencode to be useful.
if [[ "$AID_NO_AI" -eq 0 ]]; then
  dbg "creating orchestrator window"
  tmux -L aid new-window -t "$session" -n "orc" -c "$launch_dir"

  # Deterministic HTTP port for this session's opencode server.
  orc_port=$(( 4200 + $(printf '%s' "$session" | cksum | cut -d' ' -f1) % 1000 ))
  tmux -L aid set-environment -t "$session" AID_ORC_PORT "$orc_port"
  tmux -L aid set-environment -t "$session" AID_ORC_REPO "$launch_dir"

  local_nav_pane=$(tmux -L aid list-panes -t "${session}:orc" -F "#{pane_id}" | head -1)

  # Split right: opencode gets ~80%, nav keeps ~20%.
  local_orc_pane=$(tmux -L aid split-window -h -t "$local_nav_pane" -P -F "#{pane_id}" \
    -l "80%" -- sleep infinity)
  # Split right: diff gets ~25% of remaining.
  local_diff_pane=$(tmux -L aid split-window -h -t "$local_orc_pane" -P -F "#{pane_id}" \
    -l "25%" -- sleep infinity)

  dbg "orc window: nav=$local_nav_pane orc=$local_orc_pane diff=$local_diff_pane port=$orc_port"

  # Store pane IDs for aid-sessions.
  tmux -L aid set-environment -t "$session" AID_ORC_NAV_PANE  "$local_nav_pane"
  tmux -L aid set-environment -t "$session" AID_ORC_ORC_PANE  "$local_orc_pane"
  tmux -L aid set-environment -t "$session" AID_ORC_DIFF_PANE "$local_diff_pane"

  # Respawn opencode with HTTP port.
  tmux -L aid respawn-pane -k -t "$local_orc_pane" \
    "OPENCODE_CONFIG_DIR=$(printf '%q' "$OPENCODE_CONFIG_DIR") OPENCODE_TUI_CONFIG=$(printf '%q' "$OPENCODE_TUI_CONFIG") XDG_DATA_HOME=$(printf '%q' "$AID_DATA") opencode --port ${orc_port} $(printf '%q' "$launch_dir")"

  # Respawn the navigator.
  local_nav_env="AID_DIR=$(printf '%q' "$AID_DIR") AID_DATA=$(printf '%q' "$AID_DATA") AID_CONFIG=$(printf '%q' "${AID_CONFIG:-}")"
  tmux -L aid respawn-pane -k -t "$local_nav_pane" \
    "${local_nav_env} bun run $(printf '%q' "$AID_DIR/lib/sessions/aid-sessions.ts")"

  # Respawn the diff pane.
  local_diff_env="AID_DIR=$(printf '%q' "$AID_DIR") AID_ORC_REPO=$(printf '%q' "$launch_dir")"
  tmux -L aid respawn-pane -k -t "$local_diff_pane" \
    "${local_diff_env} bun run $(printf '%q' "$AID_DIR/lib/sessions/aid-diff.ts")"

  # Build the ORCH status bar strings from the live global palette.
  orch_status_l=$(tmux -L aid show-option -gqv status-left | sed 's/ #S / ORCH /g')
  orch_status_r=$(tmux -L aid show-option -gqv status-right)

  # ── Status bar hook: vimbridge on ide window, ORCH pill on orc window ──────
  vimbridge_l="#(cat \#{socket_path}-\#{session_id}-vimbridge)"
  vimbridge_r="#(cat \#{socket_path}-\#{session_id}-vimbridge-R)"
  tmux -L aid set-hook -t "$session" after-select-window \
    "if-shell '[ \"#{window_name}\" = orc ]' \
       'set-option -t $(printf '%q' "$session") status-left $(printf '%q' "$orch_status_l") ; set-option -t $(printf '%q' "$session") status-right $(printf '%q' "$orch_status_r")' \
       'set-option -t $(printf '%q' "$session") status-left $(printf '%q' "$vimbridge_l") ; set-option -t $(printf '%q' "$session") status-right $(printf '%q' "$vimbridge_r")'"
else
  dbg "--no-ai set: skipping orchestrator window"
fi

# Return to window 0 (IDE layout) for initial attach.
tmux -L aid select-window -t "${session}:0"

dbg "attaching to session=$session"
attach_or_switch "$session"
