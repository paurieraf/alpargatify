#!/bin/bash

# ============================================================================
# sync-lossless.sh
# ============================================================================
# Automates the organization of new FLAC files using beets,
# synchronizes the organized library to the SMB share (PVE server),
# and converts the library to Opus format.
#
# NOTE (macOS + SMB): Docker Desktop cannot bind-mount SMB network shares.
# The beets container therefore writes to a LOCAL staging directory, and we
# rsync the results to the SMB share afterwards. Only the albums imported in
# the current run pass through staging (it is wiped each run), so we never
# re-convert the whole library.
# ============================================================================

set -e
echo "DEBUG-RUN: script started with args: $*"
echo "DEBUG-RUN: FORCE_HIGH_RES initial: ${FORCE_HIGH_RES:-}"

FORCE_HIGH_RES=false

# --- Final destinations (SMB share, PVE server) ---
# Single tree per format: navidrome_library is what Navidrome serves (LXC 111
# bind-mounts it), navidrome_library_flac is the lossless archive. There is no
# second on-disk FLAC copy — a backup on the same disk is not a backup; the
# off-disk copy is handled by the host's rclone jobs.
SMB_BASE="${SMB_BASE:-/Volumes/usb-hdd-wd-5tb/musicbucket}"
SMB_LOSSLESS="${SMB_LOSSLESS:-$SMB_BASE/navidrome_library_flac}"
SMB_LOSSY="${SMB_LOSSY:-$SMB_BASE/navidrome_library}"

# Each library keeps its own beets DB next to its content. Since beets runs in a
# container against the local staging dir, the DB has to be pulled in before the
# import and pushed back after, or every run would start from an empty library
# and lose duplicate detection. Paths inside these DBs are relative, so moving
# them between the share and staging is safe.
SMB_LOSSLESS_DB="$SMB_LOSSLESS/library.db"
SMB_LOSSY_DB="$SMB_LOSSY/library.db"

# --- Local staging (beets writes here; Docker on macOS can't mount SMB) ---
STAGING_BASE="${STAGING_BASE:-$HOME/.alpargatify-staging}"
LOSSLESS_ORGANIZED="$STAGING_BASE/flac"   # beets imports new FLAC here (local)
LOSSY_PATH="$STAGING_BASE/lossy"          # beets converts to Opus here (local)

BEETS_CONFIG="$HOME/dev/workspace/alpargatify/library-organizer/beets/beets-config.yaml"
PARALLEL_WRAPPER="$HOME/dev/workspace/alpargatify/library-organizer/parallel-wrapper.sh"
WRAPPER_SCRIPT="$(dirname "$PARALLEL_WRAPPER")/wrapper.sh"

# --- Colors for output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# --- Helper functions ---
info() { echo -e "${BLUE}INFO:${NC} $1"; }
success() { echo -e "${GREEN}SUCCESS:${NC} $1"; }
warn() { echo -e "${YELLOW}WARN:${NC} $1"; }
error() { echo -e "${RED}ERROR:${NC} $1"; exit 1; }

# Check FLAC format using afinfo
# Returns 0: OK (16/44), 1: Warn (24/48), 2: Skip (>24/48)
check_flac_format() {
    local dir="$1"
    local first_flac=$(find "$dir" -maxdepth 1 -name "*.flac" -print -quit)

    if [ -z "$first_flac" ]; then
        return 0 # No flac files to check, assume OK or handled by beets
    fi

    local afinfo_out=$(afinfo "$first_flac" 2>/dev/null)
    if [ -z "$afinfo_out" ]; then
        warn "Could not run afinfo on $first_flac. Proceeding with caution."
        return 1
    fi

    # Extract sample rate and bit depth
    # Example format: "Data format:     2 ch,  44100 Hz, flac (0x00000001) from 16-bit source"
    local sample_rate=$(echo "$afinfo_out" | grep "Data format:" | grep -oE "[0-9]+ Hz" | head -1 | awk '{print $1}')
    local bit_depth=$(echo "$afinfo_out" | grep "source bit depth:" | grep -oE "I[0-9]+" | head -1 | sed 's/I//')

    if [ -z "$sample_rate" ] || [ -z "$bit_depth" ]; then
        warn "Could not parse afinfo output for $first_flac. Proceeding with caution."
        return 1
    fi

    if [ "$bit_depth" -eq 16 ] && [ "$sample_rate" -eq 44100 ]; then
        return 0
    elif [ "$bit_depth" -le 24 ] && [ "$sample_rate" -le 48000 ]; then
        warn "Found higher quality file (${bit_depth}bit / ${sample_rate}Hz): $(basename "$first_flac")"
        return 1
    else
        warn "File exceeds 24-bit/48kHz ($bit_depth bit / $sample_rate Hz): $(basename "$first_flac")."
        if [ "$FORCE_HIGH_RES" = true ]; then
             warn "Force flag is set. Proceeding despite high resolution."
             return 1
        else
             warn "Skipping folder: $(basename "$dir")"
             return 2
        fi
    fi
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [FLAGS] [SOURCE_PATH]

Flags:
  -i, --interactive      Run the process interactively (prompts for beets tag matching).
  -o, --organize-only    Organize music (lossless and lossy) and push to the SMB share.
  -f, --full-sync        Alias of --organize-only (kept for muscle memory).
  -F, --force-high-res   Process folders even if they exceed quality limits (> 24/48).
  -j, --max-jobs N       Set maximum number of parallel jobs (default: auto).
  -h, --help             Show this help message.

SOURCE_PATH: Required for organization flags. Path to the folder with new music
             (a parent/inbox folder containing album subfolders).

Destinations (override with SMB_BASE / SMB_LOSSLESS / SMB_LOSSY):
  Lossless : $SMB_LOSSLESS
  Lossy    : $SMB_LOSSY
Beets DBs (copied into staging before import, pushed back after; previous kept as *.prev):
  $SMB_LOSSLESS_DB
  $SMB_LOSSY_DB
Local staging (auto, wiped each run): $STAGING_BASE
EOF
    exit 0
}

# --- Argument parsing ---
ORG_MUSIC=false
INTERACTIVE=false
SOURCE_PATH=""
MAX_JOBS=""

if [ "$#" -eq 0 ]; then usage; fi

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -i|--interactive)   INTERACTIVE=true; shift ;;
        -o|--organize-only) ORG_MUSIC=true; shift ;;
        -f|--full-sync)     ORG_MUSIC=true; shift ;;
        -F|--force-high-res) FORCE_HIGH_RES=true; shift ;;
        -j|--max-jobs)      MAX_JOBS="$2"; shift 2 ;;
        -h|--help)          usage ;;
        *)
            if [ -z "$SOURCE_PATH" ]; then
                SOURCE_PATH="$1"
                shift
            else
                error "Unknown argument: $1"
            fi
            ;;
    esac
done

# Validation
if [ "$ORG_MUSIC" = true ] && [ -z "$SOURCE_PATH" ]; then
    error "Organization requires a SOURCE_PATH."
fi

if [ "$ORG_MUSIC" = true ] && [ ! -d "$SOURCE_PATH" ]; then
    error "Source path does not exist: $SOURCE_PATH"
fi

# Determine Max Jobs
if [ -z "$MAX_JOBS" ]; then
    MAX_JOBS=4
    if command -v sysctl >/dev/null 2>&1; then
        MAX_JOBS=$(sysctl -n hw.ncpu)
    elif command -v nproc >/dev/null 2>&1; then
        MAX_JOBS=$(nproc)
    fi
fi

if [ "$INTERACTIVE" = true ]; then
    BEETS_CONFIG="$HOME/dev/workspace/alpargatify/library-organizer/beets/beets-config-interactive.yaml"
fi

# --- Preflight: SMB share must be mounted before we start importing ---
preflight_smb() {
    local missing=""
    [ -d "$SMB_LOSSLESS" ] || missing="$missing\n  - $SMB_LOSSLESS"
    [ -d "$SMB_LOSSY" ]    || missing="$missing\n  - $SMB_LOSSY"
    if [ -n "$missing" ]; then
        error "SMB destination(s) not reachable. Mount the share first, then retry:$missing"
    fi
}

# --- Staging setup (local, wiped each run) ---
setup_staging() {
    info "Preparing local staging: $STAGING_BASE"
    rm -rf "$STAGING_BASE"
    mkdir -p "$LOSSLESS_ORGANIZED" "$LOSSY_PATH"
}

cleanup_staging() {
    if [ -d "$STAGING_BASE" ]; then
        info "Cleaning local staging: $STAGING_BASE"
        rm -rf "$STAGING_BASE"
    fi
}

# --- Beets library DB round-trip (share <-> staging) ---

# Cheap sanity check: a beets DB must start with the SQLite magic string.
is_sqlite() {
    [ -s "$1" ] && [ "$(head -c 15 "$1" 2>/dev/null)" = "SQLite format 3" ]
}

# fetch_db <share_db> <staging_dir>
fetch_db() {
    local src="$1" staging_dir="$2"
    if [ ! -f "$src" ]; then
        warn "No beets DB at $src — starting a fresh one (no duplicate detection this run)."
        return 0
    fi
    if ! is_sqlite "$src"; then
        error "Beets DB at $src is not a valid SQLite file. Move it aside before running."
    fi
    info "Fetching beets DB: $src ($(du -h "$src" 2>/dev/null | cut -f1))"
    cp "$src" "$staging_dir/library.db" || error "Could not copy $src into staging."
}

# push_db <staging_dir> <share_db>
push_db() {
    local staged="$1/library.db" dest="$2"
    if [ ! -f "$staged" ]; then
        warn "No beets DB in staging ($staged) — nothing to push back to $dest."
        return 0
    fi
    if ! is_sqlite "$staged"; then
        warn "Staged beets DB $staged looks corrupt — NOT pushing it to $dest."
        return 1
    fi
    # Keep one generation back, and land the new DB via a temp name so an
    # interrupted copy over SMB never leaves a half-written library.db.
    if [ -f "$dest" ]; then
        cp "$dest" "$dest.prev" || warn "Could not snapshot previous DB to $dest.prev"
    fi
    if cp "$staged" "$dest.tmp" && mv -f "$dest.tmp" "$dest"; then
        success "Beets DB updated: $dest"
    else
        warn "Failed to update beets DB at $dest (previous copy kept)."
        rm -f "$dest.tmp"
        return 1
    fi
}

if [ "$ORG_MUSIC" = true ]; then
    preflight_smb
    setup_staging
    fetch_db "$SMB_LOSSLESS_DB" "$LOSSLESS_ORGANIZED"
    fetch_db "$SMB_LOSSY_DB" "$LOSSY_PATH"
fi

# --- 1. Music Organization (Beets) into local staging ---
if [ "$ORG_MUSIC" = true ]; then
    info "Starting music organization from $SOURCE_PATH..."
    info "Max parallel jobs: $MAX_JOBS"
    info "Staging (lossless): $LOSSLESS_ORGANIZED"
    echo "DEBUG-RUN: FORCE_HIGH_RES is $FORCE_HIGH_RES"

    if [ ! -x "$WRAPPER_SCRIPT" ]; then
        error "Wrapper script not found or not executable at $WRAPPER_SCRIPT"
    fi

    # We iterate and run in background
    RUNNING_JOBS=()

    for dir in "$SOURCE_PATH"/*/; do
        [ -d "$dir" ] || continue
        folder_name=$(basename "$dir")
        log_file="/tmp/import_${folder_name// /_}.log"

        # Limit parallelism using PID array
        while [ "${#RUNNING_JOBS[@]}" -ge "$MAX_JOBS" ]; do
            # Check for completed jobs and remove them from running list
            new_running=()
            for pid in "${RUNNING_JOBS[@]}"; do
                if kill -0 "$pid" 2>/dev/null; then
                    # Job still running
                    new_running+=("$pid")
                fi
            done
            RUNNING_JOBS=("${new_running[@]}")

            # Brief sleep to avoid busy waiting
            sleep 0.5
        done

        info "Organizing: $folder_name"

        # 1. Check for MP3s
        if find "$dir" -maxdepth 1 -name "*.mp3" -print -quit | grep -q .; then
            warn "Found .mp3 files in $(basename "$dir"). Skipping folder."
            continue
        fi

        # 2. Check FLAC format before starting background job
        check_res=0
        check_flac_format "$dir" || check_res=$?

        if [ "$check_res" -eq 2 ]; then
            continue
        fi

        if [ "$INTERACTIVE" = true ]; then
            info "  -> Interactive mode (foreground)"
            if bash "$WRAPPER_SCRIPT" --interactive --beets-config "$BEETS_CONFIG" --import-only "$dir" "$LOSSLESS_ORGANIZED"; then
                success "Organized $folder_name successfully. Deleting source."
                rm -rf "$dir"
            else
                warn "Failed to organize $folder_name."
            fi
        else
            info "  -> Log: $log_file"
            (
                if bash "$WRAPPER_SCRIPT" --beets-config "$BEETS_CONFIG" --import-only "$dir" "$LOSSLESS_ORGANIZED" > "$log_file" 2>&1; then
                    success "Organized $folder_name successfully. Deleting source."
                    rm -rf "$dir"
                else
                    warn "Failed to organize $folder_name. Check log: $log_file"
                fi
            ) &
            RUNNING_JOBS+=($!)
        fi
    done

    if [ "$INTERACTIVE" = false ]; then
        wait
    fi
    info "Organization phase completed."

    # FLAC imports are done, so the lossless DB is final: push it back now.
    push_db "$LOSSLESS_ORGANIZED" "$SMB_LOSSLESS_DB" || true
fi

# --- 2. Convert to lossy (local staging) + push everything to SMB ---
run_parallel_tasks() {
    local conv_log="/tmp/lossy_conv.log"
    local push_flac_log="/tmp/push_flac.log"
    local push_flac_pid=""

    # 2.1 Push newly organized FLAC (staging) to SMB library, in background.
    #     library.db is beets-internal and staging-only; never push it.
    # -type d: library.db always sits in staging now, so only albums count as work.
    if [ "$ORG_MUSIC" = true ] && [ -n "$(find "$LOSSLESS_ORGANIZED" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)" ]; then
        info "Pushing organized FLAC to SMB library in background..."
        info "  -> Log: $push_flac_log"
        rsync -a --exclude='library.db' --exclude='beets-config.yaml' \
            "$LOSSLESS_ORGANIZED/" "$SMB_LOSSLESS/" > "$push_flac_log" 2>&1 &
        push_flac_pid=$!
    fi

    # 2.2 Conversion to Lossy (OPUS): staging LOSSLESS -> staging LOSSY
    if [ "$ORG_MUSIC" = true ]; then
        if [ "$INTERACTIVE" = true ]; then
            info "Starting lossy conversion in foreground (interactive)..."
            for item in "$LOSSLESS_ORGANIZED"/*/; do
                [ -d "$item" ] || continue
                # Check if it has subfolders (collections / artist dirs)
                if [ -n "$(find "$item" -mindepth 1 -maxdepth 1 -type d -print -quit)" ]; then
                    info "Processing collection (sequential for interactive): $(basename "$item")"
                    for subitem in "$item"/*/; do
                        [ -d "$subitem" ] || continue
                        bash "$WRAPPER_SCRIPT" --interactive --beets-config "$BEETS_CONFIG" "$subitem" "$LOSSY_PATH"
                    done
                else
                    info "Processing album (interactive): $(basename "$item")"
                    bash "$WRAPPER_SCRIPT" --interactive --beets-config "$BEETS_CONFIG" "$item" "$LOSSY_PATH"
                fi
            done
        else
            info "Starting lossy conversion in background..."
            info "  -> Log: $conv_log"
            (
                for item in "$LOSSLESS_ORGANIZED"/*/; do
                    [ -d "$item" ] || continue
                    # Check if it has subfolders (collections / artist dirs)
                    if [ -n "$(find "$item" -mindepth 1 -maxdepth 1 -type d -print -quit)" ]; then
                        info "Processing collection (parallel): $(basename "$item")"
                        bash "$PARALLEL_WRAPPER" --max-jobs "$MAX_JOBS" "$item" "$LOSSY_PATH"
                    else
                        info "Processing album (sequential): $(basename "$item")"
                        bash "$WRAPPER_SCRIPT" --beets-config "$BEETS_CONFIG" "$item" "$LOSSY_PATH"
                    fi
                done
            ) > "$conv_log" 2>&1 &
            conv_pid=$!
        fi
    fi

    # Wait for conversion (background mode)
    if [ "$INTERACTIVE" = false ] && [ -n "${conv_pid:-}" ]; then
        wait "$conv_pid" && success "Lossy conversion completed." || warn "Lossy conversion finished with errors (check $conv_log)."
    fi

    # Conversion is done, so the lossy DB is final: push it back.
    if [ "$ORG_MUSIC" = true ]; then
        push_db "$LOSSY_PATH" "$SMB_LOSSY_DB" || true
    fi

    # Wait for the FLAC push to SMB
    if [ -n "$push_flac_pid" ]; then
        wait "$push_flac_pid" && success "FLAC pushed to SMB." || warn "FLAC push finished with errors (check $push_flac_log)."
    fi

    # 2.3 Push lossy (staging) to SMB library
    if [ "$ORG_MUSIC" = true ] && [ -n "$(find "$LOSSY_PATH" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)" ]; then
        info "Pushing lossy (Opus) to SMB library..."
        rsync -a --exclude='library.db' --exclude='beets-config.yaml' \
            "$LOSSY_PATH/" "$SMB_LOSSY/" && success "Lossy pushed to SMB." \
            || warn "Lossy push finished with errors."
    fi

}

# Run tasks if needed
if [ "$ORG_MUSIC" = true ]; then
    run_parallel_tasks
fi

# Clean staging on success
if [ "$ORG_MUSIC" = true ]; then
    cleanup_staging
fi

success "All tasks finished!"
