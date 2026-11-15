#!/usr/bin/env bash
# ============================================================================
# server/navidrome-snapshot.sh — verified snapshot of Navidrome database
# ============================================================================
# Runs on LXC 101 (or on the PVE host).
# Takes a verified snapshot of the live Navidrome database and stores it in
# $OPS_DIR (/mnt/musicbucket/.ops).
#
# Usage:
#   navidrome-snapshot.sh [-h|--help] [--keep N] [--no-prune] [--no-ct-copy]
# ============================================================================

set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

KEEP=2
DO_PRUNE=1
CT_COPY=1
# Where `navidrome backup create` writes inside LXC 111.
CT_BACKUP_DIR="${CT_BACKUP_DIR:-/var/lib/navidrome/backup}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Take a verified snapshot of the Navidrome database and keep the last two in $OPS_DIR.

Options:
  --keep N        number of snapshots to keep (default 2)
  --no-prune      create and verify only; delete nothing
  --no-ct-copy    delete the container-side backup after a verified pull
  -h, --help      this help
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --keep)
            [ "$#" -ge 2 ] || err "--keep needs a number"
            KEEP="$2"
            shift 2
            ;;
        --no-prune) DO_PRUNE=0; shift ;;
        --no-ct-copy) CT_COPY=0; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; err "Unknown option: $1" ;;
    esac
done
case "$KEEP" in
    ''|*[!0-9]*) err "--keep must be a positive integer, got '$KEEP'" ;;
esac
[ "$KEEP" -ge 1 ] || err "--keep must be at least 1"

if [ "$IS_PVE_HOST" -eq 1 ]; then
    pct status "$NAVIDROME_CT" >/dev/null 2>&1 || err "LXC $NAVIDROME_CT not found"
    [ "$(pct status "$NAVIDROME_CT")" = "status: running" ] \
        || err "LXC $NAVIDROME_CT is not running; start it before snapshotting"
else
    [ -f "$NAVIDROME_SSH_KEY" ] || err "SSH key '$NAVIDROME_SSH_KEY' not found (run setup first)"
    navidrome_exec true 2>/dev/null || err "Cannot connect to Navidrome at $NAVIDROME_HOST via SSH"
fi

mkdir -p "$OPS_DIR"
share_owner="$(stat -c '%u:%g' "$MUSICBUCKET" 2>/dev/null \
    || stat -f '%u:%g' "$MUSICBUCKET" 2>/dev/null || echo "$OWNER")"
chown "$share_owner" "$OPS_DIR" 2>/dev/null || warn "Could not chown $OPS_DIR to $share_owner"

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
dest="$OPS_DIR/navidrome-$stamp.db"
[ -e "$dest" ] && err "Snapshot '$dest' already exists"

# ---------------------------------------------------------------------------
# 1. Create the backup inside Navidrome
# ---------------------------------------------------------------------------
info "Creating Navidrome database backup in LXC $NAVIDROME_CT ($CT_BACKUP_DIR)"
navidrome_exec mkdir -p "$CT_BACKUP_DIR"

out="$OPS_DIR/.create-$stamp.log"
set +e
navidrome_cli -n backup create -d "$CT_BACKUP_DIR" >"$out" 2>&1
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
    warn "navidrome backup create failed (status $rc):"
    sed 's/^/    /' "$out" >&2
    rm -f "$out"
    err "No snapshot taken"
fi

ct_file="$(sed -n 's/.*[[:space:]]path="\{0,1\}\([^"[:space:]]*\)"\{0,1\}.*/\1/p' "$out" | tail -n 1)"
rm -f "$out"
if [ -z "$ct_file" ] || ! navidrome_exec test -s "$ct_file"; then
    ct_file="$(navidrome_exec sh -c "ls -1t '$CT_BACKUP_DIR'/*.db 2>/dev/null | head -n 1")"
fi
[ -n "$ct_file" ] || err "Could not find the backup file inside LXC $NAVIDROME_CT"
navidrome_exec test -s "$ct_file" || err "Backup file '$ct_file' is empty or missing"
info "Container backup: $ct_file"

# ---------------------------------------------------------------------------
# 2. Pull it onto the volume and verify it
# ---------------------------------------------------------------------------
info "Pulling to $dest"
navidrome_pull "$ct_file" "$dest.tmp"

# Helper for sqlite commands
run_sqlite() {
    local db="$1" query="$2"
    if command -v sqlite3 >/dev/null 2>&1; then
        sqlite3 "$db" "$query"
    else
        python3 -c "
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
c = conn.cursor()
for r in c.execute(sys.argv[2]):
    print(' '.join(str(x) for x in r))
" "$db" "$query"
    fi
}

# Fold WAL mode into rollback journal
set +e
run_sqlite "$dest.tmp" 'PRAGMA journal_mode=DELETE;' >/dev/null 2>&1
set -e
rm -f "$dest.tmp-shm" "$dest.tmp-wal"

verify() {
    local db="$1"
    if command -v sqlite3 >/dev/null 2>&1; then
        sqlite3 -readonly -separator ' ' "$db" \
            'select (select * from pragma_quick_check), (select count(*) from media_file), (select count(*) from album), (select count(*) from library);'
    else
        python3 -c "
import sqlite3, sys
conn = sqlite3.connect(f'file:{sys.argv[1]}?mode=ro', uri=True)
c = conn.cursor()
q = c.execute('select (select * from pragma_quick_check), (select count(*) from media_file), (select count(*) from album), (select count(*) from library)').fetchone()
print(' '.join(str(x) for x in q))
" "$db"
    fi
}

set +e
verified="$(verify "$dest.tmp")"
vr=$?
set -e
if [ "$vr" -ne 0 ] || [ -z "$verified" ]; then
    warn "Snapshot '$dest.tmp' failed verification — keeping the file for inspection"
    err "Snapshot not usable; remove it or investigate before relying on it"
fi
read -r qcheck files albums libraries <<<"$verified"
if [ "$qcheck" != "ok" ]; then
    warn "pragma quick_check on '$dest.tmp' says: $qcheck"
    err "Snapshot is corrupt: do not prune anything and do not continue"
fi
if [ -z "$files" ] || [ "$files" -lt 1 ]; then
    warn "Snapshot '$dest.tmp' holds $files media_file rows, which cannot be a copy of a working library"
    err "Refusing to accept an empty snapshot"
fi
chown "$share_owner" "$dest.tmp" 2>/dev/null || warn "Could not chown $dest to $share_owner"
mv "$dest.tmp" "$dest"
success "Verified snapshot: $dest ($files media files, $albums albums, $libraries libraries)"

# ---------------------------------------------------------------------------
# 3. Keep the last $KEEP on both sides
# ---------------------------------------------------------------------------
if [ "$DO_PRUNE" -eq 1 ]; then
    info "Pruning container backups to $KEEP"
    set +e
    navidrome_cli -n backup prune -d "$CT_BACKUP_DIR" -k "$KEEP" -f 2>&1 | sed 's/^/    /'
    pr=$?
    set -e
    [ "$pr" -eq 0 ] || warn "navidrome backup prune exited with status $pr; check $CT_BACKUP_DIR"

    info "Pruning $OPS_DIR to $KEEP snapshot(s)"
    mapfile -t olds < <(
        find "$OPS_DIR" -maxdepth 1 -type f -name 'navidrome-*.db' -print 2>/dev/null \
            | sort -r | tail -n "+$((KEEP + 1))"
    )
    for f in ${olds[@]+"${olds[@]}"}; do
        if [ "$f" = "$dest" ]; then
            continue
        fi
        info "  removing $f"
        rm -f "$f" "$f-shm" "$f-wal"
    done
fi

if [ "$CT_COPY" -eq 0 ]; then
    info "Removing the container-side copy ($ct_file)"
    navidrome_exec rm -f "$ct_file"
fi

echo "snapshot=$dest"
echo "media_file=$files"
echo "albums=$albums"
echo "libraries=$libraries"
echo "ct_backup=$([ "$CT_COPY" -eq 1 ] && echo "$ct_file" || echo "(removed)")"
echo "result=ok"
