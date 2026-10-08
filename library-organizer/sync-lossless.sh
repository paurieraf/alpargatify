#!/bin/bash

# ============================================================================
# sync-lossless.sh
# ============================================================================
# Automates the organization of new FLAC files using beets,
# synchronizes the organized library to the SMB share (PVE server),
# and converts the library to Opus format.
#
# NOTE (macOS + SMB): Docker Desktop cannot bind-mount SMB network shares.
# This cuts BOTH ways, because the beets container mounts an import folder and
# an output folder:
#   - output: the container writes to a LOCAL staging directory and we rsync the
#     results to the share afterwards. Only the albums imported in the current
#     run pass through staging (it is wiped each run), so we never re-convert
#     the whole library.
#   - input: an album sitting on the share cannot be mounted either — Docker
#     fails with "error while creating mount source path ...: file exists". So
#     when SOURCE_PATH is on a network mount, each album is copied into local
#     staging first and imported from there (see import_album/is_network_path).
#     One album at a time, so peak local disk stays at roughly one album.
#
# The Opus library mirrors the FLAC one: each newly organized FLAC album is
# converted and imported as-is (wrapper.sh --as-is), keeping the tags beets
# already wrote, so both libraries end up with the same paths and metadata.
# Albums whose Opus copy fails are listed in navidrome_inbox_failed/*.list and
# can be redone later with --lossy-only.
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
# Albums that were not imported (Skip in interactive mode, duplicates, no match,
# errors, quality gate) are parked here instead of being deleted from the inbox,
# each with a "<album>.txt" next to it explaining why.
SMB_FAILED="${SMB_FAILED:-$SMB_BASE/navidrome_inbox_failed}"

# Optional owner (user:group) for everything written to the destinations. Set
# on the server, where the library must belong to the unprivileged-LXC root
# (0:0 inside the LXC == 100000 on the host) and stay world-readable for
# Navidrome. Unset on macOS: the SMB share forces its own owner.
FIX_OWNER="${FIX_OWNER:-}"

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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BEETS_CONFIG="$SCRIPT_DIR/beets/beets-config.yaml"
# The as-is lossy import never prompts, so it always uses the quiet config.
LOSSY_BEETS_CONFIG="$SCRIPT_DIR/beets/beets-config.yaml"
PARALLEL_WRAPPER="$SCRIPT_DIR/parallel-wrapper.sh"
WRAPPER_SCRIPT="$SCRIPT_DIR/wrapper.sh"

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

# Check FLAC format using afinfo (macOS) or metaflac (Linux, package "flac")
# Returns 0: OK (16/44), 1: Warn (24/48), 2: Skip (>24/48)
check_flac_format() {
    local dir="$1"
    local first_flac; first_flac=$(find "$dir" -maxdepth 1 -name "*.flac" -print -quit)
    local sample_rate="" bit_depth=""

    if [ -z "$first_flac" ]; then
        return 0 # No flac files to check, assume OK or handled by beets
    fi

    if command -v afinfo >/dev/null 2>&1; then
        local afinfo_out; afinfo_out=$(afinfo "$first_flac" 2>/dev/null)
        # Example format: "Data format:     2 ch,  44100 Hz, flac (0x00000001) from 16-bit source"
        sample_rate=$(echo "$afinfo_out" | grep "Data format:" | grep -oE "[0-9]+ Hz" | head -1 | awk '{print $1}')
        bit_depth=$(echo "$afinfo_out" | grep "source bit depth:" | grep -oE "I[0-9]+" | head -1 | sed 's/I//')
    elif command -v metaflac >/dev/null 2>&1; then
        sample_rate=$(metaflac --show-sample-rate "$first_flac" 2>/dev/null)
        bit_depth=$(metaflac --show-bps "$first_flac" 2>/dev/null)
    else
        warn "Neither afinfo nor metaflac available; cannot check $(basename "$first_flac"). Proceeding with caution."
        return 1
    fi

    if [ -z "$sample_rate" ] || [ -z "$bit_depth" ]; then
        warn "Could not read sample rate / bit depth of $first_flac. Proceeding with caution."
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
  -L, --lossy-only LIST  Only (re)build the Opus copy of albums already in the FLAC
                         library. LIST: one album folder per line, relative to the
                         FLAC library (e.g. "Artist/Artist - [2001] Album"). The FLAC
                         library and its DB are only read.
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

Albums that are not imported (Skip, duplicate, no match, error, mp3, > 24/48) are
moved to $SMB_FAILED
with a <album>.txt explaining why, instead of being deleted. Albums imported as
FLAC whose Opus copy failed are listed in $SMB_FAILED/lossy-missing-<date>.list
(feed it to --lossy-only). Set FIX_OWNER=user:group to chown everything written.
EOF
    exit 0
}

# --- Argument parsing ---
ORG_MUSIC=false
INTERACTIVE=false
SOURCE_PATH=""
MAX_JOBS=""
LOSSY_ONLY=false
LOSSY_ONLY_LIST=""

if [ "$#" -eq 0 ]; then usage; fi

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -i|--interactive)   INTERACTIVE=true; shift ;;
        -o|--organize-only) ORG_MUSIC=true; shift ;;
        -f|--full-sync)     ORG_MUSIC=true; shift ;;
        -F|--force-high-res) FORCE_HIGH_RES=true; shift ;;
        -j|--max-jobs)      MAX_JOBS="$2"; shift 2 ;;
        -L|--lossy-only)    LOSSY_ONLY=true; LOSSY_ONLY_LIST="$2"; shift 2 ;;
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

if [ "$LOSSY_ONLY" = true ]; then
    if [ "$ORG_MUSIC" = true ] || [ -n "$SOURCE_PATH" ]; then
        error "--lossy-only works on the FLAC library: it takes no -o/-f flag nor SOURCE_PATH."
    fi
    if [ -z "$LOSSY_ONLY_LIST" ] || [ ! -r "$LOSSY_ONLY_LIST" ]; then
        error "Album list not readable: ${LOSSY_ONLY_LIST:-<missing>}"
    fi
fi

# Determine Max Jobs
if [ -z "$MAX_JOBS" ]; then
    MAX_JOBS=4
    # nproc first: Linux also ships sysctl, but without hw.ncpu.
    if command -v nproc >/dev/null 2>&1; then
        MAX_JOBS=$(nproc)
    elif command -v sysctl >/dev/null 2>&1; then
        MAX_JOBS=$(sysctl -n hw.ncpu)
    fi
fi

if [ "$INTERACTIVE" = true ]; then
    BEETS_CONFIG="$SCRIPT_DIR/beets/beets-config-interactive.yaml"
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

# --- Preflight: every tool the run needs, checked before anything is imported ---
# A missing encoder used to surface only after the FLAC import, leaving the
# album in the lossless library with no Opus copy for Navidrome.
preflight_tools() {
    local missing="" tool
    for tool in docker rsync opusenc; do
        command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
    done
    if [ -n "$missing" ]; then
        error "Missing required tool(s):$missing (Linux: apt install docker.io rsync opus-tools flac; macOS: brew install rsync opus-tools)"
    fi
    # A stopped or paused daemon fails every album one by one and parks the
    # whole inbox in SMB_FAILED: catch it before anything is touched.
    if ! docker info >/dev/null 2>&1; then
        error "Docker is installed but its daemon does not answer (stopped, or Docker Desktop paused?). Start it and retry."
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

# Records the DB's fingerprint at fetch time so push_db can tell whether beets
# actually changed it. Kept outside the staging subdirs so rsync never ships it.
db_mark() {
    echo "$STAGING_BASE/$(basename "$1").dbmark"
}

# Content hash, NOT a timestamp: bash compares mtimes at one-second granularity,
# so a DB written in the same second as the fetch would look untouched and its
# push would be skipped, losing the import record.
db_fingerprint() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        # No hasher: fall back to size, and say so — this can miss same-size edits.
        warn "No shasum/sha256sum available; falling back to size comparison for the beets DB."
        wc -c < "$1" | tr -d ' '
    fi
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
    db_fingerprint "$staging_dir/library.db" > "$(db_mark "$staging_dir")"
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
    # Nothing imported (or every album skipped) means beets never wrote to the
    # DB, and writes to the share run at ~2.5 MB/s: skip a pointless 130MB push.
    local mark
    mark="$(db_mark "$1")"
    if [ -f "$mark" ] && [ "$(db_fingerprint "$staged")" = "$(cat "$mark")" ]; then
        info "Beets DB unchanged this run — skipping push to $dest."
        return 0
    fi
    # Land the new DB under a temp name first, then rotate: both mv's are
    # server-side renames on the share (instant), so the only bytes crossing
    # the wire are the new DB itself.
    if ! cp "$staged" "$dest.tmp"; then
        warn "Failed to copy the new beets DB to $dest.tmp (existing DB untouched)."
        rm -f "$dest.tmp"
        return 1
    fi
    [ -f "$dest" ] && mv -f "$dest" "$dest.prev"
    if mv -f "$dest.tmp" "$dest"; then
        fix_owner "$dest"
        success "Beets DB updated: $dest (previous kept as $(basename "$dest").prev)"
    else
        warn "Failed to move the new beets DB into place at $dest."
        return 1
    fi
}

# --- Source localisation (Docker cannot bind-mount SMB paths) ---
# The beets container mounts the import folder, and Docker Desktop refuses a
# mount source on an SMB share ("mkdir /host_mnt/Volumes/...: file exists").
# When the inbox lives on the share, each album is copied to local staging and
# imported from there. Copies are per album, so peak local disk stays bounded.
is_network_path() {
    local src
    src=$(df -P "$1" 2>/dev/null | awk 'NR==2{print $1}')
    case "$src" in
        //*|*:/*) return 0 ;;   # //host/share (SMB) or host:/export (NFS)
        *) return 1 ;;
    esac
}

# True when <dir> still holds audio. beets moves (never copies) imported files,
# so audio left behind after a "successful" run means the album was skipped:
# interactive Skip and duplicate_action=skip both exit 0.
has_audio() {
    [ -n "$(find "$1" -type f \( -iname '*.flac' -o -iname '*.mp3' -o -iname '*.m4a' \
        -o -iname '*.opus' -o -iname '*.ogg' -o -iname '*.wav' -o -iname '*.aiff' \) -print -quit 2>/dev/null)" ]
}

# Apply FIX_OWNER (if set) to <path>, recursively, and make it world-readable.
fix_owner() {
    [ -n "$FIX_OWNER" ] || return 0
    if ! { chown -R "$FIX_OWNER" "$1" && chmod -R a+rX "$1"; }; then
        warn "Could not fix ownership of $1"
    fi
}

# Exit codes finalize_source understands besides wrapper.sh's own (0/1/2).
RC_LEFT_AUDIO=3   # beets exited 0 but the audio is still there
RC_HAS_MP3=10     # folder contains .mp3, never imported
RC_HIGH_RES=11    # above 24-bit/48 kHz without -F

failure_reason() {
    case "$1" in
        2) echo "beets found no confident match (quiet mode skipped it). Retry in interactive mode and choose the match yourself." ;;
        4) echo "beets died halfway through moving the files: part of the album may already be in the library and its DB has rows pointing to /import. Do not retry blindly: run server/audit.sh and fix the album first." ;;
        "$RC_LEFT_AUDIO") echo "beets finished without error but did not import the files: you chose Skip in interactive mode, or the album is a duplicate of one already in the library (duplicate_action: skip). If it is a duplicate you can delete it." ;;
        "$RC_HAS_MP3") echo "The folder contains .mp3 files; only lossless sources are imported." ;;
        "$RC_HIGH_RES") echo "The FLAC exceeds 24-bit/48 kHz. Rerun with -F (--force-high-res) to import it anyway." ;;
        *) echo "The import failed (wrapper/beets exit code $1). See the log below." ;;
    esac
}

# write_failure_report <report.txt> <album_name> <source_dir> <rc> [log_file]
write_failure_report() {
    local report="$1" name="$2" src="$3" rc="$4" log="${5:-}"
    {
        echo "Album:     $name"
        echo "Date:      $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Host:      $(hostname)"
        echo "Mode:      $([ "$INTERACTIVE" = true ] && echo interactive || echo automatic)"
        echo "Source:    $src"
        echo "Exit code: $rc"
        echo
        echo "Reason:"
        echo "  $(failure_reason "$rc")"
        echo
        echo "To retry: move the folder back to the inbox and run the interactive sync."
        if [ -n "$log" ] && [ -f "$log" ]; then
            echo
            echo "--- Last 60 lines of $log ---"
            # Drop ANSI colours/cursor codes and docker build noise.
            tail -n 200 "$log" | sed "s/$(printf '\033')\[[0-9;]*[A-Za-z]//g" | grep -v '^#[0-9]' | tail -n 60
        fi
    } > "$report" 2>/dev/null || warn "Could not write $report"
}

# finalize_source <album_dir> <rc> [log_file]
# rc 0 = imported: delete the source. Anything else = keep the audio by
# parking the folder in SMB_FAILED, plus a <album>.txt with the reason.
finalize_source() {
    local dir="${1%/}" rc="$2" log="${3:-}" name dest
    name=$(basename "$dir")
    if [ "$rc" -eq 0 ]; then
        success "Organized $name successfully. Deleting source."
        rm -rf "$dir"
        return 0
    fi
    warn "Not imported: $name — $(failure_reason "$rc")"
    mkdir -p "$SMB_FAILED"
    dest="$SMB_FAILED/$name"
    [ -e "$dest" ] && dest="$dest.$(date +%Y%m%d-%H%M%S)"
    if mv "$dir" "$dest"; then
        write_failure_report "$dest.txt" "$name" "$dir" "$rc" "$log"
        fix_owner "$dest"
        fix_owner "$dest.txt"
        warn "  -> Moved to $dest (reason in $(basename "$dest").txt)"
    else
        warn "  -> Could not move it to $SMB_FAILED; left in place."
    fi
}

# import_album <album_dir>  — localises when needed, then hands off to wrapper.sh
# Returns wrapper's exit code, or RC_LEFT_AUDIO when beets exited 0 but left the audio behind.
import_album() {
    local src_dir="$1" work_dir="$1" local_copy="" rc=0
    if [ "$SOURCE_IS_REMOTE" = true ]; then
        local_copy="$INBOX_STAGING/$(basename "$src_dir")"
        rm -rf "$local_copy"
        if ! cp -R "$src_dir" "$local_copy"; then
            warn "Could not copy $(basename "$src_dir") to local staging."
            rm -rf "$local_copy"
            return 1
        fi
        work_dir="$local_copy"
    fi
    if [ "$INTERACTIVE" = true ]; then
        bash "$WRAPPER_SCRIPT" --interactive --beets-config "$BEETS_CONFIG" \
            --import-only "$work_dir" "$LOSSLESS_ORGANIZED" || rc=$?
    else
        bash "$WRAPPER_SCRIPT" --beets-config "$BEETS_CONFIG" \
            --import-only "$work_dir" "$LOSSLESS_ORGANIZED" || rc=$?
    fi
    if [ "$rc" -eq 0 ] && has_audio "$work_dir"; then
        rc=$RC_LEFT_AUDIO
    fi
    # beets moved the audio out of the copy; drop whatever is left either way
    # (the original is still on the share and finalize_source decides its fate).
    [ -n "$local_copy" ] && rm -rf "$local_copy"
    return "$rc"
}

# stage_lossless_albums <list> — copies the listed albums (folders relative to
# the FLAC library, one per line) into staging, where the conversion step turns
# them into Opus. The FLAC library is only read. Each copy lands in a side dir
# and is moved in only when complete, so a failed copy is never converted
# (cleanup_staging takes the leftovers).
stage_lossless_albums() {
    local list="$1" rel n=0
    local incoming="$STAGING_BASE/lossy-only-incoming"
    while IFS= read -r rel || [ -n "$rel" ]; do
        rel="${rel%$'\r'}"
        rel="${rel%/}"
        case "$rel" in ''|'#'*) continue ;; esac
        case "/$rel/" in
            //*|*/../*|*/./*) warn "Skipping unsafe path in list: $rel"; continue ;;
        esac
        if [ ! -d "$SMB_LOSSLESS/$rel" ]; then
            warn "Not in the FLAC library, skipping: $rel"; continue
        fi
        if [ -e "$LOSSLESS_ORGANIZED/$rel" ]; then
            warn "Listed twice, skipping: $rel"; continue
        fi
        mkdir -p "$incoming/$(dirname "$rel")" "$LOSSLESS_ORGANIZED/$(dirname "$rel")"
        if cp -R "$SMB_LOSSLESS/$rel" "$incoming/$rel" && mv "$incoming/$rel" "$LOSSLESS_ORGANIZED/$rel"; then
            n=$((n + 1))
            info "Staged for lossy conversion: $rel"
        else
            warn "Could not copy $rel into staging; left out of this run."
        fi
    done < "$list"
    [ "$n" -gt 0 ] || error "Nothing to convert: none of the listed albums is in $SMB_LOSSLESS."
    info "$n album(s) staged for lossy conversion."
}

# Album folders whose Opus copy failed this run (staging paths). Kept outside
# the staging subdirs so rsync never ships it.
LOSSY_FAILED_FILE="$STAGING_BASE/lossy_failed.txt"
LOSSY_FAILURES=0

# Turns LOSSY_FAILED_FILE into a list relative to the FLAC library and keeps it
# in SMB_FAILED (staging is wiped on the next run), ready for --lossy-only.
# .list, not .txt: status.sh reads every *.txt there as a failed-album report.
report_lossy_failures() {
    [ -s "$LOSSY_FAILED_FILE" ] || return 0
    local list
    mkdir -p "$SMB_FAILED"
    list="$SMB_FAILED/lossy-missing-$(date +%Y%m%d-%H%M%S).list"
    sed "s|^$LOSSLESS_ORGANIZED/||" "$LOSSY_FAILED_FILE" | sort -u > "$list"
    fix_owner "$list"
    LOSSY_FAILURES=$(wc -l < "$list" | tr -d ' ')
    warn "$LOSSY_FAILURES album(s) are in the FLAC library but have NO Opus copy:"
    sed 's/^/    - /' "$list"
    warn "Redo them with: $(basename "$0") --lossy-only \"$list\""
}

SOURCE_IS_REMOTE=false
INBOX_STAGING="$STAGING_BASE/inbox"

if [ "$ORG_MUSIC" = true ]; then
    preflight_tools
    preflight_smb
    setup_staging
    mkdir -p "$INBOX_STAGING"
    if is_network_path "$SOURCE_PATH"; then
        SOURCE_IS_REMOTE=true
        info "Source is on a network share: albums are copied to local staging first (Docker cannot mount SMB paths)."
    fi
    fetch_db "$SMB_LOSSLESS_DB" "$LOSSLESS_ORGANIZED"
    fetch_db "$SMB_LOSSY_DB" "$LOSSY_PATH"
elif [ "$LOSSY_ONLY" = true ]; then
    preflight_tools
    preflight_smb
    setup_staging
    fetch_db "$SMB_LOSSY_DB" "$LOSSY_PATH"
    stage_lossless_albums "$LOSSY_ONLY_LIST"
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
            finalize_source "$dir" "$RC_HAS_MP3"
            continue
        fi

        # 2. Check FLAC format before starting background job
        check_res=0
        check_flac_format "$dir" || check_res=$?

        if [ "$check_res" -eq 2 ]; then
            finalize_source "$dir" "$RC_HIGH_RES"
            continue
        fi

        if [ "$INTERACTIVE" = true ]; then
            info "  -> Interactive mode (foreground)"
            rc=0
            import_album "$dir" || rc=$?
            finalize_source "$dir" "$rc"
        else
            info "  -> Log: $log_file"
            (
                rc=0
                import_album "$dir" > "$log_file" 2>&1 || rc=$?
                finalize_source "$dir" "$rc" "$log_file"
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
# With FIX_OWNER, rsync lands files with the right owner and world-readable modes.
RSYNC_OWNER_OPTS=()
if [ -n "$FIX_OWNER" ]; then
    # shellcheck disable=SC2054  # the comma belongs to rsync's --chmod syntax
    RSYNC_OWNER_OPTS=(--chown="$FIX_OWNER" --chmod=Da+rx,Fa+r)
fi

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
        rsync -a ${RSYNC_OWNER_OPTS[@]+"${RSYNC_OWNER_OPTS[@]}"} \
            --exclude='library.db' --exclude='beets-config.yaml' \
            "$LOSSLESS_ORGANIZED/" "$SMB_LOSSLESS/" > "$push_flac_log" 2>&1 &
        push_flac_pid=$!
    fi

    # 2.2 Conversion to Lossy (OPUS): staging LOSSLESS -> staging LOSSY.
    #     The FLAC files already carry beets' final tags, so the Opus copies are
    #     imported as-is (no autotag, no network plugins): same paths and
    #     metadata as the FLAC library, and nothing to ask even in interactive
    #     mode. A failed album is recorded and the loop moves on — the subshell
    #     inherits `set -e`, which used to abort the rest of the batch.
    : > "$LOSSY_FAILED_FILE"
    info "Starting lossy conversion in background..."
    info "  -> Log: $conv_log"
    (
        for item in "$LOSSLESS_ORGANIZED"/*/; do
            [ -d "$item" ] || continue
            item="${item%/}"
            # Check if it has subfolders (collections / artist dirs)
            if [ -n "$(find "$item" -mindepth 1 -maxdepth 1 -type d -print -quit)" ]; then
                info "Processing collection (parallel): $(basename "$item")"
                FAILED_LIST_FILE="$LOSSY_FAILED_FILE" bash "$PARALLEL_WRAPPER" --max-jobs "$MAX_JOBS" \
                    --as-is --beets-config "$LOSSY_BEETS_CONFIG" "$item" "$LOSSY_PATH" \
                    || warn "Lossy conversion had failures in: $(basename "$item")"
            else
                info "Processing album (sequential): $(basename "$item")"
                bash "$WRAPPER_SCRIPT" --as-is --beets-config "$LOSSY_BEETS_CONFIG" "$item" "$LOSSY_PATH" \
                    || { warn "Lossy conversion failed: $(basename "$item")"; echo "$item" >> "$LOSSY_FAILED_FILE"; }
            fi
        done
    ) > "$conv_log" 2>&1 &
    conv_pid=$!

    if wait "$conv_pid"; then
        success "Lossy conversion completed."
    else
        warn "Lossy conversion finished with errors (check $conv_log)."
    fi
    report_lossy_failures

    # Conversion is done, so the lossy DB is final: push it back.
    push_db "$LOSSY_PATH" "$SMB_LOSSY_DB" || true

    # Wait for the FLAC push to SMB
    if [ -n "$push_flac_pid" ]; then
        if wait "$push_flac_pid"; then
            success "FLAC pushed to SMB."
        else
            warn "FLAC push finished with errors (check $push_flac_log)."
        fi
    fi

    # 2.3 Push lossy (staging) to SMB library
    if [ -n "$(find "$LOSSY_PATH" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)" ]; then
        info "Pushing lossy (Opus) to SMB library..."
        if rsync -a ${RSYNC_OWNER_OPTS[@]+"${RSYNC_OWNER_OPTS[@]}"} \
            --exclude='library.db' --exclude='beets-config.yaml' \
            "$LOSSY_PATH/" "$SMB_LOSSY/"; then
            success "Lossy pushed to SMB."
        else
            warn "Lossy push finished with errors."
        fi
    fi

}

# Run tasks if needed, then clean staging (lossy failures were already saved
# to SMB_FAILED by report_lossy_failures)
if [ "$ORG_MUSIC" = true ] || [ "$LOSSY_ONLY" = true ]; then
    run_parallel_tasks
    cleanup_staging
fi

if [ "$LOSSY_FAILURES" -gt 0 ]; then
    error "Finished, but $LOSSY_FAILURES album(s) still lack their Opus copy (listed above)."
fi

success "All tasks finished!"
