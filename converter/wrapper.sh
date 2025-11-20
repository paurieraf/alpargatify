#!/usr/bin/env bash
# wrapper.sh (fixed macOS realpath issue)
#  - Runs your flac-to-aac.sh conversion (step 1)
#  - Then runs the Docker Compose stack (step 2: beets, step 3: normalizer)
#
# Usage:
#   ./wrapper.sh [--force] [--dry-run] [--beets-config /abs/path/to/beets_config.yaml] \
#                            /path/to/source /absolute/path/to/destination
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults
BEETS_CONFIG="$SCRIPT_DIR/docker/beets/beets_config.yaml"
FORCE="no"
DRY_RUN="no"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--force] [--dry-run] [--beets-config /path/to/beets_config.yaml] /path/to/source /path/to/destination

Options:
  --force             pass --force to flac-to-aac.sh (overwrite existing outputs)
  --dry-run           run conversion in dry-run and normalizer in dry-run (no file moves)
  --beets-config PATH path to beets_config.yaml (default: $BEETS_CONFIG)
EOF
}

# Parse args
POSITIONAL=()
while (( "$#" )); do
  case "$1" in
    --force) FORCE="yes"; shift ;;
    --dry-run) DRY_RUN="yes"; shift ;;
    --beets-config) BEETS_CONFIG="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) echo "Unknown option: $1" >&2; usage; exit 2 ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done
set -- "${POSITIONAL[@]:-}"

if [ "${#}" -ne 2 ]; then
  echo "Error: source and destination required." >&2
  usage
  exit 2
fi

SRC="$1"
DEST="$2"

# Sanity checks
if [ ! -d "$SRC" ]; then
  echo "Error: source directory does not exist" >&2
  exit 3
fi
mkdir -p "$DEST"

CONVERTER="$SCRIPT_DIR/flac-to-aac.sh"
if [ ! -x "$CONVERTER" ]; then
  echo "Error: converter script not found or not executable at: $CONVERTER" >&2
  exit 4
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "Error: docker not found in PATH. Docker is required." >&2
  exit 5
fi

# Compose command check (docker compose or docker-compose)
COMPOSE_CMD=""
if docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE_CMD="docker-compose"
else
  echo "Error: neither 'docker compose' nor 'docker-compose' found. Install Docker Compose." >&2
  exit 6
fi

# Confirm beets config exists (resolve absolute path too)
if [ -n "$BEETS_CONFIG" ]; then
  if [ -f "$BEETS_CONFIG" ]; then
    echo "$BEETS_CONFIG exists."
  else
    echo "Warning: beets_config not found at $BEETS_CONFIG. The beets container will run with defaults." >&2
  fi
fi

# Inform user
echo "=== Settings ==="
echo "Script dir:    $SCRIPT_DIR"
echo "Source:        $SRC"
echo "Destination:   $DEST"
echo "Converter:     $CONVERTER"
echo "Beets config:  $BEETS_CONFIG"
echo "Force:         $FORCE"
echo "Dry run:       $DRY_RUN"
echo "Docker compose: $COMPOSE_CMD"
echo "================"
echo

# Step 1: run conversion script
conv_args=()
[ "$FORCE" = "yes" ] && conv_args+=(--force)
[ "$DRY_RUN" = "yes" ] && conv_args+=(--dry-run)
conv_args+=( "$SRC" "$DEST" )

echo "-> STEP 1: running converter"
echo "Running: $CONVERTER ${conv_args[*]}"
if [ "$DRY_RUN" = "yes" ]; then
  echo "(dry-run) running converter in dry-run mode"
  "$CONVERTER" "${conv_args[@]}"
else
  "$CONVERTER" "${conv_args[@]}"
fi
echo "-> STEP 1 finished."
echo

# Step 2 & 3: run Docker Compose stack (must be under docker/ directory located next to script)
COMPOSE_FILE="$SCRIPT_DIR/docker/docker-compose.yml"
if [ ! -f "$COMPOSE_FILE" ]; then
  echo "Error: docker compose file not found at $COMPOSE_FILE" >&2
  exit 7
fi

# Export env vars used by docker-compose
# DEST is absolute path to the album dir you want normalized
export DEST_PATH="$DEST"
# PARENT_OF_DEST_PATH = absolute parent directory (host path to bind)
export PARENT_OF_DEST_PATH="$(cd "$(dirname "$DEST")" && pwd)"
# DEST_SUBPATH = basename of DEST (the child directory inside parent that will be renamed/operated)
export DEST_SUBPATH="$(basename "$DEST")"
# Pass DRY_RUN to normalizer container
export DRY_RUN="$DRY_RUN"

export BEETS_CONFIG="$BEETS_CONFIG"

echo "-> STEP 2 & 3: invoking docker compose (beets -> normalizer)"
pushd "$SCRIPT_DIR/docker" >/dev/null

# Use --abort-on-container-exit so compose stops after the one-shot services finish
if [ "$COMPOSE_CMD" = "docker compose" ]; then
  docker compose -f docker-compose.yml up --build --abort-on-container-exit
  EXIT_CODE=$?
else
  docker-compose -f docker-compose.yml up --build --abort-on-container-exit
  EXIT_CODE=$?
fi

popd >/dev/null

if [ "$EXIT_CODE" -ne 0 ]; then
  echo "Docker compose finished with non-zero exit code: $EXIT_CODE" >&2
  exit $EXIT_CODE
fi

echo "-> STEP 2 & 3 finished. All done."
exit 0
