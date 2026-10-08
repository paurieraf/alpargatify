#!/usr/bin/env bash
# ============================================================================
# server/status.sh — what is the server-side sync doing?
# ============================================================================
# Usage: status.sh [LINES]   (default 25 log lines)
# Prints running sessions, inbox/pending counts and the tail of the last log,
# without colour codes so it reads well in the iOS shortcut result.
# ============================================================================

set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

LINES_SHOWN="${1:-25}"

if session_running "$SESSION_AUTO"; then
    echo "Sync: RUNNING"
elif session_running "$SESSION_INTERACTIVE"; then
    echo "Sync: interactive session open (attach: sync.sh interactive)"
else
    echo "Sync: idle"
fi
echo "Inbox:   $(count_albums "$INBOX") album(s)"
echo "Pending: $(count_albums "$PENDING") album(s)"

latest="$LOG_DIR/latest.log"
if [ -f "$latest" ]; then
    echo
    echo "--- $(basename "$(readlink -f "$latest")") ---"
    # Strip ANSI colours written by sync-lossless.sh.
    tail -n "$LINES_SHOWN" "$latest" | sed 's/\x1b\[[0-9;]*m//g'
fi
