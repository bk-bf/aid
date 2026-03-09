#!/usr/bin/env bash
# ensure_treemux.sh — open treemux sidebar if not already open; never closes it.
# Called from nvim VimEnter and the session-created hook.
#
# Layout enforcement
# ──────────────────
# The three-pane layout (sidebar | editor | opencode) cannot be fully
# specified upfront because treemux adds the sidebar *after* the initial
# editor/opencode split in aliases.sh.  Once the sidebar exists we know
# the exact window width and can resize the opencode pane to the correct
# absolute column count, ensuring it always occupies OPENCODE_PCT % of the
# total window regardless of terminal size.

TREEMUX_SCRIPTS="${AID_DIR:-$(cd "$(dirname "$(realpath "$0")")" && pwd)}/tmux/plugins/treemux/scripts"

# Target: opencode occupies this percentage of the total window width.
# At 154 cols, 28% -> 43 cols.
OPENCODE_PCT=28

# ARGS string is stored by sidebar.tmux under @treemux-key-Tab
ARGS=$(tmux -L aid show-option -gqv '@treemux-key-Tab')
PANE_ID="${TMUX_PANE:-$(tmux -L aid display-message -p '#{pane_id}')}"

if [ -z "$ARGS" ]; then
    # sidebar.tmux may not have finished yet (race at session start).
    # Retry for up to 3 seconds before giving up.
    for _i in 1 2 3 4 5 6; do
        sleep 0.5
        ARGS=$(tmux -L aid show-option -gqv '@treemux-key-Tab')
        [ -n "$ARGS" ] && break
    done
    if [ -z "$ARGS" ]; then
        exit 0
    fi
fi

# Check if sidebar is already registered and the pane actually exists
sidebar_pane=""
existing=$(tmux -L aid show-option -gqv "@-treemux-registered-pane-$PANE_ID")
if [ -n "$existing" ]; then
    sidebar_pane=$(echo "$existing" | cut -d',' -f1)
    if tmux -L aid list-panes -F "#{pane_id}" | grep -q "^${sidebar_pane}$"; then
        # Sidebar already open — still enforce layout proportions then exit
        _enforce_layout() {
            local window_width target_cols opencode_pane
            window_width=$(tmux -L aid display-message -p '#{window_width}')
            target_cols=$(awk -v w="$window_width" -v pct="$OPENCODE_PCT" \
                'BEGIN { printf "%d", int(w * pct / 100 + 0.5) }')
            opencode_pane=$(tmux -L aid list-panes -F "#{pane_id} #{pane_left}" \
                | grep -v "^${sidebar_pane} " \
                | sort -k2 -n \
                | tail -1 \
                | cut -d' ' -f1)
            if [ -n "$opencode_pane" ] && [ "$opencode_pane" != "$PANE_ID" ]; then
                tmux -L aid resize-pane -t "$opencode_pane" -x "$target_cols"
            fi
        }
        _enforce_layout
        exit 0
    fi
fi

"$TREEMUX_SCRIPTS/toggle.sh" "$ARGS" "$PANE_ID"

# ── Layout correction ────────────────────────────────────────────────────────
# Treemux has just opened the sidebar.  Read sidebar_pane from the tmux option
# that toggle.sh just wrote, then resize opencode to the target column count.

# Give treemux a moment to register the pane option
sleep 0.2
sidebar_pane=$(tmux -L aid show-option -gqv "@-treemux-registered-pane-$PANE_ID" \
    | cut -d',' -f1)

window_width=$(tmux -L aid display-message -p '#{window_width}')
target_cols=$(awk -v w="$window_width" -v pct="$OPENCODE_PCT" \
    'BEGIN { printf "%d", int(w * pct / 100 + 0.5) }')

# Rightmost pane that is not the sidebar and not the current (editor) pane
opencode_pane=$(tmux -L aid list-panes -F "#{pane_id} #{pane_left}" \
    | grep -v "^${sidebar_pane} " \
    | grep -v "^${PANE_ID} " \
    | sort -k2 -n \
    | tail -1 \
    | cut -d' ' -f1)

if [ -n "$opencode_pane" ]; then
    tmux -L aid resize-pane -t "$opencode_pane" -x "$target_cols"
fi
