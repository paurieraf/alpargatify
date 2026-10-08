#!/usr/bin/env bash
# ============================================================================
# server/audit.sh — read-only health check of both libraries
# ============================================================================
# Usage:
#   audit.sh [ARGS...]    Runs audit-library.py on navidrome_library_flac and
#                         navidrome_library. Extra ARGS go to the script, e.g.
#                           audit.sh --list
#                           audit.sh --emit-missing-lossy /root/missing.list
#                         then rebuild those Opus copies with: sync.sh lossy FILE
# Exit status: 0 = clean, 1 = problems found ([!!] lines), 2 = error.
# Uses the host's python3 (>= 3.8), or the local/beets image if there is none.
# ============================================================================

set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

AUDIT="$ORGANIZER_DIR/audit-library.py"

# Libraries are mounted read-only in the container; only the folder of an
# --emit-missing-lossy file is writable (and its path made absolute).
MOUNTS=(-v "$MUSICBUCKET:$MUSICBUCKET:ro" -v "$ORGANIZER_DIR:/alpargatify:ro")
EXTRA=()
while [ "$#" -gt 0 ]; do
    if [ "$1" = "--emit-missing-lossy" ] && [ "$#" -ge 2 ]; then
        out_dir=$(cd "$(dirname "$2")" && pwd) || err "No such folder for $2"
        EXTRA+=("$1" "$out_dir/$(basename "$2")")
        MOUNTS+=(-v "$out_dir:$out_dir")
        shift 2
    else
        EXTRA+=("$1")
        shift
    fi
done
ARGS=(--lossless "$MUSICBUCKET/navidrome_library_flac" --lossy "$MUSICBUCKET/navidrome_library"
      ${EXTRA[@]+"${EXTRA[@]}"})

if command -v python3 >/dev/null 2>&1 && python3 -c 'import sys; sys.exit(sys.version_info < (3, 8))'; then
    exec python3 "$AUDIT" "${ARGS[@]}"
fi

command -v docker >/dev/null 2>&1 || err "Need python3 >= 3.8 or docker to run the audit."
docker image inspect local/beets:latest >/dev/null 2>&1 \
    || err "No python3 and no local/beets image yet: run one sync first (it builds the image)."
exec docker run --rm --user 0:0 "${MOUNTS[@]}" --entrypoint python3 \
    local/beets:latest /alpargatify/audit-library.py "${ARGS[@]}"
