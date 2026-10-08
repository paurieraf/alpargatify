#!/usr/bin/env bash
# ============================================================================
# server/inbox.sh — move downloaded albums into navidrome_inbox
# ============================================================================
# Usage:
#   inbox.sh list            Download folders holding FLAC, one per line, as
#                            "<client>/<folder>" (client = slskd | torrents).
#   inbox.sh move NAME...    Send those folders to the inbox.
#   inbox.sh move -          Same, reading one NAME per line from stdin (what the
#                            iOS shortcut uses: names may contain any character).
#
# slskd folders are MOVED (same filesystem: instant). torrent folders are
# COPIED so qBittorrent keeps seeding them.
# ============================================================================

set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

CLIENTS=(slskd torrents)
# Client-internal folders that never hold a finished album.
SKIP_DIRS=(temp incomplete torrent_files)

is_skipped() {
    local name="$1" skip
    for skip in "${SKIP_DIRS[@]}"; do [ "$name" = "$skip" ] && return 0; done
    return 1
}

list_albums() {
    local client dir name
    for client in "${CLIENTS[@]}"; do
        [ -d "$DOWNLOADS/$client" ] || continue
        while IFS= read -r -d '' dir; do
            name=$(basename "$dir")
            is_skipped "$name" && continue
            # Only folders with FLAC somewhere inside (multi-disc included).
            [ -n "$(find "$dir" -type f -iname '*.flac' -print -quit 2>/dev/null)" ] || continue
            echo "$client/$name"
        done < <(find "$DOWNLOADS/$client" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
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
    case " ${CLIENTS[*]} " in
        *" $client "*) ;;
        *) warn "Unknown client '$client' in: $rel"; return 1 ;;
    esac
    src="$DOWNLOADS/$client/$name"
    dest="$INBOX/$name"
    [ -d "$src" ] || { warn "Not found: $src"; return 1; }
    [ -e "$dest" ] && { warn "Already in inbox: $name"; return 1; }

    if [ "$client" = "torrents" ]; then
        cp -R "$src" "$dest" || { rm -rf "$dest"; warn "Copy failed: $name"; return 1; }
        success "Copied (torrent keeps seeding): $name"
    else
        mv "$src" "$dest" || { warn "Move failed: $name"; return 1; }
        success "Moved: $name"
    fi
    chown -R "$OWNER" "$dest" && chmod -R a+rwX "$dest" || warn "Could not fix permissions on $dest"
}

[ -d "$INBOX" ] || err "Inbox not found: $INBOX (is the bind-mount in place?)"

case "${1:-}" in
    list)
        list_albums
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
        sed -n '4,13p' "$0" | sed 's/^# \{0,1\}//'
        exit 1
        ;;
esac
