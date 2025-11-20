#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

DEST_DIR=${DEST_DIR:-/data}
DRY_RUN_FLAG=${DRY_RUN:-no}

if [ "$DRY_RUN_FLAG" = "yes" ] || [ "$DRY_RUN_FLAG" = "true" ]; then
  python3 /app/normalize_dirs.py --source "$DEST_DIR" --dest "$DEST_DIR" --dry-run
else
  python3 /app/normalize_dirs.py --source "$DEST_DIR" --dest "$DEST_DIR"
fi

echo "Normalization finished."
