#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

DEST_DIR=${DEST_DIR:-/data}
DRY_RUN_FLAG=${DRY_RUN:-no}

SENTINEL="$DEST_DIR/.beets_done"

echo "Normalizer starting. Waiting for sentinel $SENTINEL (max 1200s)..."

# Wait for sentinel up to a timeout (1200s = 20 minutes)
timeout=1200
elapsed=0
interval=2
while [ ! -f "$SENTINEL" ]; do
  sleep $interval
  elapsed=$((elapsed + interval))
  if [ "$elapsed" -ge "$timeout" ]; then
    echo "Timeout waiting for sentinel $SENTINEL. Exiting with error." >&2
    exit 2
  fi
done

echo "Sentinel found; running normalization script on $DEST_DIR"

if [ "$DRY_RUN_FLAG" = "yes" ] || [ "$DRY_RUN_FLAG" = "true" ]; then
  python3 /app/normalize_dirs.py --source "$DEST_DIR" --dest "$DEST_DIR" --dry-run
else
  python3 /app/normalize_dirs.py --source "$DEST_DIR" --dest "$DEST_DIR"
fi

echo "Normalization finished."
