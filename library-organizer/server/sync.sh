#!/usr/bin/env bash
# ============================================================================
# server/sync.sh — run sync-lossless.sh on the server, inside tmux
# ============================================================================
# Usage:
#   sync.sh auto          Start a non-interactive sync of the inbox in a detached
#                         tmux session and return at once (phone-friendly).
#   sync.sh interactive   Open (or re-attach to) an interactive sync for albums
#                         that need manual beets matching. Needs a terminal:
#                         run it from an SSH session (Termius/Blink/Terminal).
#
# Both run `sync-lossless.sh -o <inbox>` against the local bind-mount, so no SMB
# staging copies are needed. Albums beets does not import end up in
# navidrome_inbox_pending/ (see sync-lossless.sh: finalize_source).
# ============================================================================

set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

MODE="${1:-}"

if [ "$MODE" != "auto" ] && [ "$MODE" != "interactive" ]; then
    sed -n '4,11p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
fi

command -v tmux >/dev/null 2>&1 || err "tmux not installed (apt install tmux)"
[ -x "$SYNC_SCRIPT" ] || err "sync-lossless.sh not found or not executable: $SYNC_SCRIPT"
[ -d "$INBOX" ] || err "Inbox not found: $INBOX (is the bind-mount in place?)"
mkdir -p "$LOG_DIR"

# printf %q-quote a command so it survives tmux's `sh -c`.
quote_cmd() {
    local out="" arg
    for arg in "$@"; do out+="$(printf '%q' "$arg") "; done
    echo "${out% }"
}

case "$MODE" in
    auto)
        session_running "$SESSION_AUTO" && err "A sync is already running. Check it with status.sh."
        session_running "$SESSION_INTERACTIVE" && err "An interactive sync is open. Finish it first."
        albums=$(count_albums "$INBOX")
        if [ "$albums" -eq 0 ]; then
            success "Inbox is empty, nothing to sync."
            exit 0
        fi
        log="$LOG_DIR/sync-$(date +%Y%m%d-%H%M%S).log"
        cmd=$(quote_cmd env "${SYNC_ENV[@]}" "$SYNC_SCRIPT" -o -j 2 "$INBOX")
        # Exit status goes to the log so status.sh can report it.
        tmux new-session -d -s "$SESSION_AUTO" \
            "$cmd > $(printf '%q' "$log") 2>&1; echo \"=== EXIT: \$? ===\" >> $(printf '%q' "$log")"
        ln -sfn "$log" "$LOG_DIR/latest.log"
        success "Sync started: $albums album(s). Log: $log"
        ;;
    interactive)
        [ -t 0 ] || err "Interactive mode needs a terminal. Connect over SSH and run: $0 interactive"
        session_running "$SESSION_AUTO" && err "A non-interactive sync is running. Wait for it (status.sh)."
        if session_running "$SESSION_INTERACTIVE"; then
            info "Re-attaching to the open interactive sync..."
            exec tmux attach-session -t "=$SESSION_INTERACTIVE"
        fi
        albums=$(count_albums "$INBOX")
        if [ "$albums" -eq 0 ]; then
            success "Inbox is empty, nothing to sync."
            exit 0
        fi
        cmd=$(quote_cmd env "${SYNC_ENV[@]}" "$SYNC_SCRIPT" -i -o -j 1 "$INBOX")
        exec tmux new-session -s "$SESSION_INTERACTIVE" \
            "$cmd; echo; read -r -p 'Done. Press Return to close...' _"
        ;;
esac
