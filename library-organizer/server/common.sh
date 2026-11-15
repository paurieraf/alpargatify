#!/usr/bin/env bash
# shellcheck disable=SC2034  # these settings are used by the scripts that source this file
# Shared settings for the server-side launchers (LXC 101, Docker host, and PVE host).
# Sourced by sync.sh / inbox.sh / status.sh / audit.sh / doctor.sh /
# remove-album.sh / navidrome-snapshot.sh — not meant to be run directly.
#
# Paths are the LXC bind-mounts of the 5TB disk:
#   /mnt/usb-hdd-wd-5tb/musicbucket -> /mnt/musicbucket
#   /mnt/usb-hdd-wd-5tb/downloads   -> /mnt/downloads

SERVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORGANIZER_DIR="$(dirname "$SERVER_DIR")"
SYNC_SCRIPT="$ORGANIZER_DIR/sync-lossless.sh"

MUSICBUCKET="${MUSICBUCKET:-/mnt/musicbucket}"
DOWNLOADS="${DOWNLOADS:-/mnt/downloads}"
INBOX="${INBOX:-$MUSICBUCKET/navidrome_inbox}"
FAILED="${FAILED:-$MUSICBUCKET/navidrome_inbox_failed}"
LOG_DIR="${LOG_DIR:-/var/log/alpargatify}"

# Owner for everything written to the disk: root of the unprivileged LXC,
# i.e. 100000:100000 on the Proxmox host (what Samba/Navidrome expect).
OWNER="${OWNER:-0:0}"

# Maximum parallel jobs for ingestion. Default to 1 because Beets SQLite
# database does not support concurrent writes (Exit 4: PARTIAL IMPORT).
MAX_JOBS="${MAX_JOBS:-1}"

# tmux sessions. Both modes share the same staging dir, so only one may run.
SESSION_AUTO="alp-sync"
SESSION_INTERACTIVE="alp-sync-i"

# Environment handed to sync-lossless.sh. Passed inline through `env` because
# a running tmux server does not inherit the caller's exported variables.
SYNC_ENV=(
    "SMB_BASE=$MUSICBUCKET"
    "SMB_FAILED=$FAILED"
    "STAGING_BASE=${STAGING_BASE:-/var/tmp/alpargatify-staging}"
    "FIX_OWNER=$OWNER"
    "BEETS_UID=${OWNER%%:*}"
    "BEETS_GID=${OWNER##*:}"
    "ALPARGATIFY_PRUNE=no"
    "MAX_JOBS=$MAX_JOBS"
)

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Colours only on a terminal: the iOS "Run Script over SSH" action shows raw text.
if [ ! -t 1 ]; then RED=''; GREEN=''; BLUE=''; YELLOW=''; NC=''; fi

info() { echo -e "${BLUE}INFO:${NC} $1"; }
success() { echo -e "${GREEN}OK:${NC} $1"; }
warn() { echo -e "${YELLOW}WARN:${NC} $1" >&2; }
err() { echo -e "${RED}ERROR:${NC} $1" >&2; exit 1; }

session_running() { tmux has-session -t "=$1" 2>/dev/null; }

# Album folders (direct subdirectories) in <dir>.
count_albums() {
    find "$1" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' '
}

# ---------------------------------------------------------------------------
# Library operations (doctor.sh, remove-album.sh, navidrome-snapshot.sh)
#
# Supports both:
#   1. Running inside LXC 101 (native Docker, remote SSH to Navidrome LXC 111)
#   2. Running on PVE host (pct exec 101 and pct exec 111)
# ---------------------------------------------------------------------------

CT_MUSICBUCKET="${CT_MUSICBUCKET:-/mnt/musicbucket}"

# Working areas outside both library roots, so neither the Navidrome scanner nor
# the audit ever considers them library content.
OPS_DIR="${OPS_DIR:-$MUSICBUCKET/.ops}"
TRASH_DIR="${TRASH_DIR:-$MUSICBUCKET/.trash}"

# Target definitions
NAVIDROME_CT="${NAVIDROME_CT:-111}"
BEETS_CT="${BEETS_CT:-101}"
NAVIDROME_CONFIG="${NAVIDROME_CONFIG:-/etc/navidrome/navidrome.toml}"
NAVIDROME_LIBRARY_ID="${NAVIDROME_LIBRARY_ID:-1}"
BEETS_IMAGE="${BEETS_IMAGE:-local/beets:latest}"
NAVIDROME_HOST="${NAVIDROME_HOST:-10.1.1.111}"
NAVIDROME_SSH_KEY="${NAVIDROME_SSH_KEY:-/root/.ssh/id_navidrome_admin}"

if command -v pct >/dev/null 2>&1; then
    IS_PVE_HOST=1
else
    IS_PVE_HOST=0
fi

navidrome_exec() {
    if [ "$IS_PVE_HOST" -eq 1 ]; then
        pct exec "$NAVIDROME_CT" -- "$@"
    else
        ssh -i "$NAVIDROME_SSH_KEY" -o StrictHostKeyChecking=accept-new -o BatchMode=yes "root@$NAVIDROME_HOST" "$@"
    fi
}

navidrome_cli() {
    navidrome_exec /usr/bin/navidrome -c "$NAVIDROME_CONFIG" "$@"
}

navidrome_pull() {
    local remote_path="$1" local_path="$2"
    if [ "$IS_PVE_HOST" -eq 1 ]; then
        pct pull "$NAVIDROME_CT" "$remote_path" "$local_path"
    else
        scp -i "$NAVIDROME_SSH_KEY" -o StrictHostKeyChecking=accept-new -o BatchMode=yes "root@$NAVIDROME_HOST:$remote_path" "$local_path"
    fi
}

navidrome_push() {
    local local_path="$1" remote_path="$2"
    if [ "$IS_PVE_HOST" -eq 1 ]; then
        pct push "$NAVIDROME_CT" "$local_path" "$remote_path"
    else
        scp -i "$NAVIDROME_SSH_KEY" -o StrictHostKeyChecking=accept-new -o BatchMode=yes "$local_path" "root@$NAVIDROME_HOST:$remote_path"
    fi
}

beets_exec() {
    if [ "$IS_PVE_HOST" -eq 1 ]; then
        pct exec "$BEETS_CT" -- "$@"
    else
        "$@"
    fi
}

# Translate a host path under MUSICBUCKET into the path LXC 101 sees.
# Returns non-zero (and prints nothing) when the path is outside the volume.
ct_path() {
    local p="$1" rel
    if [ "$IS_PVE_HOST" -eq 0 ]; then
        printf '%s\n' "$p"
        return 0
    fi
    case "$p" in
        "$MUSICBUCKET") printf '%s\n' "$CT_MUSICBUCKET" ;;
        "$MUSICBUCKET"/*)
            rel="${p#"$MUSICBUCKET"/}"
            printf '%s/%s\n' "$CT_MUSICBUCKET" "$rel"
            ;;
        *) return 1 ;;
    esac
}

# Fail early rather than mounting a path that only exists on the host.
require_ct_path() {
    local p
    p="$(ct_path "$1")" || err "Cannot translate '$1' to the LXC $BEETS_CT view: not under $MUSICBUCKET"
    if [ "$IS_PVE_HOST" -eq 1 ]; then
        pct exec "$BEETS_CT" -- test -e "$p" \
            || err "Path '$p' does not exist inside LXC $BEETS_CT (host view: '$1')"
    else
        test -e "$p" || err "Path '$p' does not exist (view: '$1')"
    fi
}
