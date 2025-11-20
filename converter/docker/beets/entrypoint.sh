#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Expected: /data mounted (destination music dir), /config.yaml mounted (beets config)
CONFIG=${BEETS_CONFIG_PATH:-/config.yaml}
DATA_DIR=/data

if [ ! -d "$DATA_DIR" ]; then
  echo "ERROR: /data not mounted or not a directory" >&2
  exit 2
fi

if [ ! -f "$CONFIG" ]; then
  echo "WARNING: beets config not found at $CONFIG; running beets with defaults"
fi

# Run beets import in-place; import will write tags back to files (beets_config.yaml should have write: yes, copy: no)
echo "Running beets import on $DATA_DIR with config $CONFIG"
if [ -f "$CONFIG" ]; then
  beet -c "$CONFIG" import -q "$DATA_DIR" || true
  # ensure tags written
  beet -c "$CONFIG" write -q || true
else
  beet import -q "$DATA_DIR" || true
  beet write -q || true
fi

# Optionally, perform other beets commands (fetchart, embedart) depending on plugins
# Touch sentinel for the normalizer service to pick up
touch "$DATA_DIR/.beets_done"
echo "Beets step finished; sentinel created at $DATA_DIR/.beets_done"
