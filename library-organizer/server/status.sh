#!/usr/bin/env bash
# ============================================================================
# server/status.sh — what is the server-side sync doing?
# ============================================================================
# Usage:
#   status.sh [LINES]    Progress of the current/last automatic sync (phase,
#                        albums done/total, elapsed), inbox/failed counts and
#                        the last LINES log lines (default 15).
#   status.sh failed     Albums in navidrome_inbox_failed/ and why, newest first,
#                        plus the lists of FLAC albums still missing their Opus copy.
# Plain text, no colour codes, so it reads well in the iOS shortcut result.
# ============================================================================

set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

strip_ansi() { sed "s/$(printf '\033')\[[0-9;]*[A-Za-z]//g"; }

# Seconds -> "1h 05m" / "4m 10s".
human_duration() {
    local s="$1"
    if [ "$s" -ge 3600 ]; then printf '%dh %02dm' $((s / 3600)) $((s % 3600 / 60))
    else printf '%dm %02ds' $((s / 60)) $((s % 60)); fi
}

show_failed() {
    local txt n=0
    echo "Failed albums: $(count_albums "$FAILED") (in $FAILED)"
    while IFS= read -r txt; do
        [ -n "$txt" ] || continue
        n=$((n + 1))
        echo
        echo "• $(basename "$txt" .txt)"
        grep -E '^(Date|Mode|Exit code):' "$txt" | sed 's/^/  /'
        # The reason is the indented line right after "Reason:".
        sed -n '/^Reason:/{n;p;}' "$txt"
    done < <(ls -t "$FAILED"/*.txt 2>/dev/null)
    [ "$n" -gt 0 ] || echo "No reports."
    show_lossy_missing
}

# Lists written by sync-lossless.sh when an album's Opus copy failed.
show_lossy_missing() {
    local list
    while IFS= read -r list; do
        [ -n "$list" ] || continue
        echo
        echo "Without Opus copy ($(basename "$list"), redo: sync.sh lossy \"$list\"):"
        sed 's/^/  - /' "$list"
    done < <(ls -t "$FAILED"/lossy-missing-*.list 2>/dev/null)
}

show_progress() {
    local log="$1" total done_ok done_ko started phase exit_line start_ts now

    total=$(sed -n 's/^=== ALBUMS: \([0-9]*\) ===$/\1/p' "$log" | head -1)
    done_ok=$(grep -c 'Organized .* successfully' "$log" || true)
    done_ko=$(grep -c 'Not imported:' "$log" || true)
    started=$(grep -c 'INFO: Organizing:' "$log" || true)
    exit_line=$(grep -o '=== EXIT: [0-9]* ===' "$log" | tail -1 || true)

    if [ -n "$exit_line" ]; then
        phase="finished (exit ${exit_line//[^0-9]/})"
    elif grep -q 'Pushing lossy' "$log"; then
        phase="3/3 copying Opus to the library"
    elif grep -q 'Starting lossy conversion' "$log"; then
        phase="2/3 converting to Opus"
    elif [ "$started" -gt 0 ]; then
        phase="1/3 importing FLAC with beets"
    else
        phase="0/3 preparing (fetching beets DBs)"
    fi

    # Log name is sync-YYYYmmdd-HHMMSS.log; elapsed runs to now, or to the
    # last write once finished.
    start_ts=$(basename "$log" .log | sed -E 's/^sync-([0-9]{4})([0-9]{2})([0-9]{2})-([0-9]{2})([0-9]{2})([0-9]{2})$/\1-\2-\3 \4:\5:\6/')
    start_ts=$(date -d "$start_ts" +%s 2>/dev/null || echo "")
    if [ -n "$exit_line" ]; then now=$(stat -c %Y "$log"); else now=$(date +%s); fi

    echo "Phase:    $phase"
    echo "Albums:   $((done_ok + done_ko))/${total:-?} processed — $done_ok imported, $done_ko failed"
    [ -n "$start_ts" ] && echo "Elapsed:  $(human_duration $((now - start_ts)))"
    # Phase-level problems (conversion/push) don't fail the run: surface them.
    if grep -qE 'finished with errors|ERROR:' "$log"; then
        echo "Problems:"
        grep -E 'finished with errors|ERROR:' "$log" | strip_ansi | sed 's/^/  /'
    fi
    if [ "$done_ko" -gt 0 ]; then
        echo "Failed:"
        grep 'Not imported:' "$log" | strip_ansi | sed -E 's/^WARN: Not imported: ([^—]*) —.*/  - \1/'
    fi
    if grep -q 'have NO Opus copy' "$log"; then
        echo "Without Opus copy:"
        strip_ansi < "$log" | sed -n '/have NO Opus copy/,/Redo them with/p' | sed -n 's/^    - /  - /p'
    fi
}

if [ "${1:-}" = "failed" ]; then
    show_failed
    exit 0
fi

LINES_SHOWN="${1:-15}"
latest="$LOG_DIR/latest.log"

if session_running "$SESSION_AUTO"; then
    echo "Sync: RUNNING"
elif session_running "$SESSION_INTERACTIVE"; then
    echo "Sync: interactive session open (attach: sync.sh interactive)"
else
    echo "Sync: idle"
fi
echo "Inbox:  $(count_albums "$INBOX") album(s) waiting"
echo "Failed: $(count_albums "$FAILED") album(s) (details: status.sh failed)"
# find, not ls: with pipefail a no-match ls fails the pipeline and set -e exits.
lossy_lists=$(find "$FAILED" -maxdepth 1 -name 'lossy-missing-*.list' 2>/dev/null | wc -l | tr -d ' ')
[ "$lossy_lists" -eq 0 ] || echo "Opus:   $lossy_lists list(s) of FLAC albums without Opus copy (status.sh failed)"

if [ -f "$latest" ]; then
    echo
    echo "Last automatic sync: $(basename "$(readlink -f "$latest")")"
    show_progress "$(readlink -f "$latest")"
    echo
    echo "--- last $LINES_SHOWN log lines ---"
    tail -n "$LINES_SHOWN" "$latest" | strip_ansi
fi
