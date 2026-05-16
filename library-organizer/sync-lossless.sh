#!/bin/bash

# ============================================================================
# sync-lossless.sh
# ============================================================================
# Automates the organization of new FLAC files using beets,
# synchronizes the organized library to an external HDD,
# and converts the library to Opus format in parallel.
# ============================================================================

set -e
echo "DEBUG-RUN: script started with args: $*"
echo "DEBUG-RUN: FORCE_HIGH_RES initial: $FORCE_HIGH_RES"
# --- Configuration paths ---
FORCE_HIGH_RES=false
HDD_PATH="/Volumes/SSD WD Black 4TB Pau/Music/MusicBucket/Navidrome Library FLAC Backup"
LOSSLESS_ORGANIZED="/Volumes/SSD WD Black 4TB Pau/Music/MusicBucket/Navidrome Library FLAC"  # Temp dir is necessary. Otherwise, all opus files are converted to FLAC every time
LOSSY_PATH="/Volumes/SSD WD Black 4TB Pau/Music/MusicBucket/Navidrome Library"
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
  -o, --organize-only    Organize music (lossless and lossy) only.
  -s, --sync-hdd-only    Sync organized lossless music to external HDD only.
  -f, --full-sync        Organize music and sync to HDD (includes conversion to lossy).
  -F, --force-high-res   Process folders even if they exceed quality limits (> 24/48).
  -j, --max-jobs N       Set maximum number of parallel jobs (default: auto).
  -h, --help             Show this help message.

SOURCE_PATH: Required for organization flags. Path to the folder with new music.
EOF
    exit 0
}

# --- Argument parsing ---
ORG_MUSIC=false
SYNC_HDD=false
FULL_SYNC=false
INTERACTIVE=false
SOURCE_PATH=""
MAX_JOBS=""

if [ "$#" -eq 0 ]; then usage; fi

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -i|--interactive)   INTERACTIVE=true; shift ;;
        -o|--organize-only) ORG_MUSIC=true; shift ;;
        -s|--sync-hdd-only) SYNC_HDD=true; shift ;;
        -f|--full-sync)     FULL_SYNC=true; shift ;;
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

# If full sync, set both flags
if [ "$FULL_SYNC" = true ]; then
    ORG_MUSIC=true
    SYNC_HDD=true
fi

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

# --- 1. Music Organization (Beets) ---
if [ "$ORG_MUSIC" = true ]; then
    info "Starting music organization from $SOURCE_PATH..."
    info "Max parallel jobs: $MAX_JOBS"
    echo "DEBUG-RUN: FORCE_HIGH_RES is $FORCE_HIGH_RES"

    if [ ! -x "$WRAPPER_SCRIPT" ]; then
        error "Wrapper script not found or not executable at $WRAPPER_SCRIPT"
    fi

    # Function to run the job (exported not needed if we use simple background loop)
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
fi

# --- 2. Parallel Actions (HDD Sync and Lossy Conversion) ---
run_parallel_tasks() {
    local sync_pid=""
    local conv_pid=""
    local sync_log="/tmp/sync_hdd.log"
    local conv_log="/tmp/lossy_conv.log"

    # 2.1 Sync to HDD
    if [ "$SYNC_HDD" = true ]; then
        if [ ! -d "$HDD_PATH" ]; then
            warn "External HDD not found at $HDD_PATH. Skipping HDD sync."
        else
            info "Starting HDD sync in background..."
            info "  -> Log: $sync_log"
            rsync -av --progress --ignore-existing \
                --exclude='library.db' \
                --exclude='beets-config.yaml' \
                "$LOSSLESS_ORGANIZED/" "$HDD_PATH/" > "$sync_log" 2>&1 &
            sync_pid=$!
        fi
    fi

    # 2.2 Conversion to Lossy (OPUS)
    # This also runs if we are just organizing music (user: "en lossless y lossy")
    if [ "$ORG_MUSIC" = true ]; then
        if [ "$INTERACTIVE" = true ]; then
            info "Starting lossy conversion in foreground (interactive)..."
            for item in "$LOSSLESS_ORGANIZED"/*/; do
                [ -d "$item" ] || continue
                # Check if it has subfolders (collections)
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
                    # Check if it has subfolders (collections)
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

    # Wait for both to finish
    if [ -n "$sync_pid" ]; then
        wait "$sync_pid" && success "HDD Sync completed." || warn "HDD Sync finished with errors (check $sync_log)."
    fi
    if [ -n "$conv_pid" ] && [ "$INTERACTIVE" = false ]; then
        wait "$conv_pid" && success "Lossy conversion completed." || warn "Lossy conversion finished with errors (check $conv_log)."
    fi
}

# Run parallel tasks if needed
if [ "$SYNC_HDD" = true ] || [ "$ORG_MUSIC" = true ]; then
    # We only run parallel actions if something needs to be done.
    # Note: If only --sync-hdd-only was passed, ORG_MUSIC is false, so it just syncs.
    run_parallel_tasks
fi

success "All tasks finished!"


