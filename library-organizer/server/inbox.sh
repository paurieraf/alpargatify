#!/usr/bin/env bash
# ============================================================================
# server/inbox.sh — move downloaded albums into navidrome_inbox
# ============================================================================
# Usage:
#   inbox.sh list            Download folders holding FLAC, one per line, as
#                            "<source>/<folder>" (source = slskd | torrents).
#   inbox.sh list failed     Albums in navidrome_inbox_failed/, as "failed/<folder>".
#   inbox.sh move NAME...    Send those folders to the inbox.
#   inbox.sh move -          Same, reading one NAME per line from stdin (what the
#                            iOS shortcut uses: names may contain any character).
#
# slskd folders are MOVED (same filesystem: instant). torrent folders are
# COPIED so qBittorrent keeps seeding them. failed folders are moved back and
# their <folder>.txt report is deleted (retry them with `sync.sh interactive`).
# ============================================================================

set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

CLIENTS=(slskd torrents)

# source name -> directory
source_dir() {
    case "$1" in
        slskd|torrents) echo "$DOWNLOADS/$1" ;;
        failed) echo "$FAILED" ;;
        *) return 1 ;;
    esac
}
# Client-internal folders that never hold a finished album.
SKIP_DIRS=(temp incomplete torrent_files)

is_skipped() {
    local name="$1" skip
    for skip in "${SKIP_DIRS[@]}"; do [ "$name" = "$skip" ] && return 0; done
    return 1
}

list_albums() {
    local client dir name
    for client in "$@"; do
        [ -d "$(source_dir "$client")" ] || continue
        while IFS= read -r -d '' dir; do
            name=$(basename "$dir")
            is_skipped "$name" && continue
            # Only folders with FLAC somewhere inside (multi-disc included).
            [ -n "$(find "$dir" -type f -iname '*.flac' -print -quit 2>/dev/null)" ] || continue
            echo "$client/$name"
        done < <(find "$(source_dir "$client")" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
    done
}

move_album() {
    local rel="$1" client name src dest
    client="${rel%%/*}"
    name="${rel#*/}"
    # Exactly "<client>/<folder>": no traversal, no nested paths.
    if [ "$client" = "$rel" ] || [ -z "$name" ] || [[ "$name" == */* ]] || [ "$name" = ".." ] || [ "$name" = "." ]; then
        warn "Invalid name: $rel"
        return 1
    fi
    if ! src="$(source_dir "$client")/$name"; then
        warn "Unknown source '$client' in: $rel"
        return 1
    fi
    dest="$INBOX/$name"
    [ -d "$src" ] || { warn "Not found: $src"; return 1; }
    [ -e "$dest" ] && { warn "Already in inbox: $name"; return 1; }

    if [ "$client" = "torrents" ]; then
        cp -R "$src" "$dest" || { rm -rf "$dest"; warn "Copy failed: $name"; return 1; }
        success "Copied (torrent keeps seeding): $name"
    elif [ "$client" = "failed" ]; then
        mv "$src" "$dest" || { warn "Move failed: $name"; return 1; }
        rm -f "$src.txt"
        success "Back in inbox: $name"
    else
        mv "$src" "$dest" || { warn "Move failed: $name"; return 1; }
        success "Moved: $name"
    fi
    chown -R "$OWNER" "$dest" && chmod -R a+rwX "$dest" || warn "Could not fix permissions on $dest"
}

[ -d "$INBOX" ] || err "Inbox not found: $INBOX (is the bind-mount in place?)"

case "${1:-}" in
    list)
        if [ "${2:-}" = "failed" ]; then
            list_albums failed
        else
            list_albums "${CLIENTS[@]}"
        fi
        ;;
    move)
        shift
        names=()
        if [ "${1:-}" = "-" ]; then
            while IFS= read -r line; do
                line="${line%$'\r'}"
                [ -n "$line" ] && names+=("$line")
            done
        else
            names=("$@")
        fi
        [ "${#names[@]}" -gt 0 ] || err "Nothing to move."
        failed=0
        for rel in "${names[@]}"; do
            move_album "$rel" || failed=$((failed + 1))
        done
        info "Inbox now holds $(count_albums "$INBOX") album(s)."
        [ "$failed" -eq 0 ] || err "$failed folder(s) could not be moved."
        ;;
    *)
        sed -n '4,16p' "$0" | sed 's/^# \{0,1\}//'
        exit 1
        ;;
esac
