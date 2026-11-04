#!/usr/bin/env bash
# ============================================================================
# server/navidrome-snapshot.sh — verified snapshot of the Navidrome database
# ============================================================================
# Runs on the PVE host. Snapshots the SQLite database of the native Navidrome in
# LXC 111, pulls it onto the 5TB volume, verifies it, and keeps the last two.
# Every destructive step of remove-album.sh needs one of these first (design
# D10), and one is what you restore from when a removal has to be undone.
#
# Usage:
#   navidrome-snapshot.sh [-h|--help] [--keep N] [--no-prune] [--no-ct-copy]
#
# Exit status: 0 snapshot created and verified, 1 could not create or verify it.
#
# Output (grep-able, one key=value per line):
#   snapshot=/mnt/.../.ops/navidrome-20261104T020000Z.db
#   media_file=<rows> albums=<rows> libraries=<rows>
#   ct_backup=<path inside LXC 111>
#   result=ok
#
# Navidrome's own copy is kept inside the container too (two of them, pruned with
# `navidrome backup prune`) because `navidrome backup restore` reads from the
# container's backup directory; the file in .ops is the one that survives a
# container rebuild. Snapshots are ~850 MB each.
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

Take a verified snapshot of the Navidrome database (LXC $NAVIDROME_CT) and keep
the last two in $OPS_DIR.

Options:
  --keep N        number of snapshots to keep (default 2)
  --no-prune      create and verify only; delete nothing
  --no-ct-copy    delete the container-side backup after a verified pull
                  (saves ~850 MB on the container disk; then
                  \`navidrome backup restore\` needs a \`pct push\` first)
  -h, --help      this help

Environment (from common.sh): MUSICBUCKET, CT_MUSICBUCKET, OPS_DIR,
NAVIDROME_CT, NAVIDROME_CONFIG.
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

command -v pct >/dev/null 2>&1 || err "pct not found: run this on the PVE host"
command -v sqlite3 >/dev/null 2>&1 || err "sqlite3 not found on the host (needed to verify the snapshot)"

pct status "$NAVIDROME_CT" >/dev/null 2>&1 || err "LXC $NAVIDROME_CT not found"
[ "$(pct status "$NAVIDROME_CT")" = "status: running" ] \
    || err "LXC $NAVIDROME_CT is not running; start it before snapshotting (a backup needs the live database)"

mkdir -p "$OPS_DIR"
# Keep the working area owned by whoever owns the libraries, so Samba and the
# containers can read it (see OWNER in common.sh).
share_owner="$(stat -c '%u:%g' "$MUSICBUCKET" 2>/dev/null \
    || stat -f '%u:%g' "$MUSICBUCKET" 2>/dev/null || echo "$OWNER")"
chown "$share_owner" "$OPS_DIR" 2>/dev/null || warn "Could not chown $OPS_DIR to $share_owner"

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
dest="$OPS_DIR/navidrome-$stamp.db"
[ -e "$dest" ] && err "Snapshot '$dest' already exists"

# ---------------------------------------------------------------------------
# 1. Create the backup inside the container
# ---------------------------------------------------------------------------
info "Creating Navidrome database backup in LXC $NAVIDROME_CT ($CT_BACKUP_DIR)"
pct exec "$NAVIDROME_CT" -- mkdir -p "$CT_BACKUP_DIR"

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

# logrus prints the value quoted: path="/var/lib/navidrome/backup/x.db"
ct_file="$(sed -n 's/.*[[:space:]]path="\{0,1\}\([^"[:space:]]*\)"\{0,1\}.*/\1/p' "$out" | tail -n 1)"
rm -f "$out"
if [ -z "$ct_file" ] || ! pct exec "$NAVIDROME_CT" -- test -s "$ct_file"; then
    # Older/newer CLI output may not name the file: fall back to the newest one.
    ct_file="$(pct exec "$NAVIDROME_CT" -- sh -c "ls -1t '$CT_BACKUP_DIR'/*.db 2>/dev/null | head -n 1")"
fi
[ -n "$ct_file" ] || err "Could not find the backup file inside LXC $NAVIDROME_CT"
pct exec "$NAVIDROME_CT" -- test -s "$ct_file" || err "Backup file '$ct_file' is empty or missing"
info "Container backup: $ct_file"

# ---------------------------------------------------------------------------
# 2. Pull it onto the volume and verify it
# ---------------------------------------------------------------------------
info "Pulling to $dest"
pct pull "$NAVIDROME_CT" "$ct_file" "$dest.tmp"

# The pulled file keeps Navidrome's write-ahead-log mode, which makes it depend
# on the -wal sidecar that a plain copy leaves behind. Fold the journal into the
# file so the snapshot is one self-contained file `backup restore` can read.
set +e
sqlite3 "$dest.tmp" 'PRAGMA journal_mode=DELETE;' >/dev/null
jr=$?
set -e
if [ "$jr" -ne 0 ]; then
    warn "Could not fold the write-ahead log into '$dest.tmp' (sqlite3 status $jr)"
fi
rm -f "$dest.tmp-shm" "$dest.tmp-wal"

verify() {  # verify <file>; prints "quick_check media_file albums libraries"
    local db="$1"
    # Read-only URI: verification must never modify the snapshot.
    sqlite3 -readonly -separator ' ' "$db" \
        'select (select * from pragma_quick_check), (select count(*) from media_file), (select count(*) from album), (select count(*) from library);'
}

set +e
verified="$(verify "$dest.tmp")"
vr=$?
set -e
if [ "$vr" -ne 0 ] || [ -z "$verified" ]; then
    warn "Snapshot '$dest.tmp' failed verification (sqlite3 status $vr) — keeping the file for inspection"
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
    # Only our own naming pattern is touched, and never the file just created.
    # The names carry a sortable UTC stamp, so reverse lexical order is newest-first.
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
    pct exec "$NAVIDROME_CT" -- rm -f "$ct_file"
fi

echo "snapshot=$dest"
echo "media_file=$files"
echo "albums=$albums"
echo "libraries=$libraries"
echo "ct_backup=$([ "$CT_COPY" -eq 1 ] && echo "$ct_file" || echo "(removed)")"
echo "result=ok"
