#!/usr/bin/env bash
# Shared settings for the server-side launchers (LXC 101, Docker host).
# Sourced by sync.sh / inbox.sh / status.sh — not meant to be run directly.
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
