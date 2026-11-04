#!/usr/bin/env bash
# ============================================================================
# server/remove-album.sh — guarded decommission of one release
# ============================================================================
# Runs on the PVE host. Takes one release out of every store that knows it —
# both library trees, both beets databases and the Navidrome library — in the
# order fixed by design D11 (database rows first, files second), and stops at the
# first stage that fails, saying what already happened.
#
# The purge is library-wide even when the scan is targeted, so it only runs after
# the gate proved that both the baseline and the post-rescan missing sets are
# subsets of the removed release's own files (design D8). The persistent
# configuration keeps `PurgeMissing = "never"`; only the process that runs the
# purging scan sees the override.
#
# Exit status: 0 removed and verified, 1 findings/leftovers, 2 usage error,
#              3 unknown release, 4 aborted by a guard (see design D12).
# ============================================================================

set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAPSHOT_SCRIPT="$SCRIPT_DIR/navidrome-snapshot.sh"
VERSION="album-doctor-and-removal / removal section"

LOSSLESS_ROOT="${LOSSLESS_ROOT:-$MUSICBUCKET/navidrome_library_flac}"
LOSSY_ROOT="${LOSSY_ROOT:-$MUSICBUCKET/navidrome_library}"
BEETS_TOOLS_CT="${BEETS_TOOLS_CT:-/opt/alpargatify/library-organizer/beets}"
ND_DB_CT="${ND_DB_CT:-/var/lib/navidrome/navidrome.db}"
PURGE_MODE="auto"
DRY_RUN=0
ASSUME_YES=0
KEEP_TRASH=0
JSON=0
RELEASE=""
KEEP_SNAPSHOTS=2

COMPLETED=()
CLEANUP_FILES=()
RESTORED=()
TRASH_RUN_DIR=""
CUR_STAGE="startup"
STAGE_NUM=0
LOSSLESS_ALBUM=""
LOSSY_ALBUM=""
LOSSLESS_ITEMS=""
LOSSY_ITEMS=""
LOSSLESS_ORPHANS=""
LOSSY_ORPHANS=""
BASE_INV=""
AFTER_INV=""
ALLOWED_INV=""
SNAP_PATH=""
SNAP_CT_NAME=""
CT_BACKUP_DIR="/var/lib/navidrome/backup"
ROWS_REMOVED=0
PURGE_RAN=0
PURGE_MODE_EFFECTIVE=""
EXPECTED_COUNT=""
STAMP=""

REPORT_FILE="$(mktemp "${TMPDIR:-/tmp}/remove-album.XXXXXX")"
CLEANUP_FILES+=("$REPORT_FILE")

# --json has to be known before anything can fail, so the human stream is moved
# to stderr up front and stdout is kept on fd 3 for the single JSON document.
for _arg in "$@"; do
    [ "$_arg" = "--json" ] && JSON=1
done
unset _arg
if [ "$JSON" -eq 1 ]; then
    exec 3>&1 1>&2
fi

usage() {
    cat <<EOF
Usage:
  $(basename "$0") --release "Artist/Album" [OPTIONS]
  $(basename "$0") gate --allowed-json FILE (--baseline FILE | --after FILE) [...]

Remove one release from both library trees, both beets databases and the
Navidrome library, in the order fixed by design D11 (rows first, files second).

Options:
  --release "Artist/Album"   release folder, relative to the library roots
  --lossless-root DIR        default: \$MUSICBUCKET/navidrome_library_flac
  --lossy-root DIR           default: \$MUSICBUCKET/navidrome_library
  --purge auto|api|none      auto (default): one targeted scan with
                             ND_SCANNER_PURGEMISSING=always, only after a passing
                             gate; api: per-id DELETE /api/missing (needs
                             ND_API_URL, ND_API_USER, ND_API_PASSWORD); none:
                             leave the rows to Navidrome
  --dry-run                  print every intended action, change nothing
  --yes, -y                  do not ask for confirmation
  --keep-trash               on abort, keep the files in trash even when the
                             move is still the only change (default: move them
                             back while no row has been touched yet; never
                             afterwards, the report prints the commands)
  --beets-tools-dir DIR      folder inside LXC \$BEETS_CT holding rm_album.py
                             (default /opt/alpargatify/library-organizer/beets)
  --keep N                   snapshots to keep (default 2)
  --json                     print exactly one JSON document
  -h, --help                 this help

Stages: preflight, snapshot, baseline-missing, gate-baseline, beets-rows,
trash, targeted-scan, gate-after, purge, verify.

  gate ...                   standalone purge-gate verdict on inventories:
                             --allowed-json FILE with the release's own rows,
                             --allowed-db SNAPSHOT PREFIX, or --allowed-prefix P
                             plus --baseline FILE and/or --after FILE.
                             Both Navidrome "missing list" JSON and fixture
                             arrays are accepted; a leading banner is skipped.
                             Exit 0 pass, 4 unrelated entry found, 2 usage.

Exit status: 0 removed and verified, 1 findings/leftovers, 2 usage error,
3 unknown release, 4 aborted by a guard.

Environment (from common.sh): MUSICBUCKET, CT_MUSICBUCKET, OPS_DIR, TRASH_DIR,
NAVIDROME_CT, BEETS_CT, BEETS_IMAGE, NAVIDROME_CONFIG, NAVIDROME_LIBRARY_ID.
EOF
}

# ---------------------------------------------------------------------------
# Output: `kv` is the machine-readable report (one key=value per line, or folded
# into the single JSON document with --json). Human lines go to stderr in JSON
# mode, so stdout stays exactly one document.
# ---------------------------------------------------------------------------
kv() {
    if [ "$JSON" -eq 1 ]; then
        printf '%s=%s\n' "$1" "$2" >>"$REPORT_FILE"
    else
        printf '%s=%s\n' "$1" "$2"
    fi
}

DUMPED=0

# The single JSON document, written to the real stdout (fd 3), never mixed with
# human output.
dump_json() {
    [ "$JSON" -eq 1 ] || return 0
    [ "$DUMPED" -eq 0 ] || return 0
    DUMPED=1
    python3 - "$REPORT_FILE" >&3 <<'PY'
import json, sys
data = {}
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    line = line.rstrip("\n")
    if "=" not in line:
        continue
    key, _, value = line.partition("=")
    if key in ("surplus", "restore", "completed_stage", "leftover"):
        data.setdefault(key + "s", []).append(value)
        continue
    data[key] = value
print(json.dumps(data, indent=2, sort_keys=True))
PY
}

finish() {  # finish <status>
    local code="$1"
    trap - EXIT ERR
    dump_json
    rm -f "${CLEANUP_FILES[@]+"${CLEANUP_FILES[@]}"}" || true
    exit "$code"
}

die() {  # die <status> <message...>
    local code="$1"
    shift
    warn "$*"
    abort_report "$CUR_STAGE" "$code"
}

# Invoked by the EXIT and ERR traps, so shellcheck cannot see the call.
# shellcheck disable=SC2329  # traps
cleanup_on_exit() {
    local rc=$?
    trap - EXIT
    dump_json
    rm -f "${CLEANUP_FILES[@]+"${CLEANUP_FILES[@]}"}" 2>/dev/null || true
    exit "$rc"
}
trap cleanup_on_exit EXIT

# shellcheck disable=SC2329  # trap
on_err() {  # ERR trap: an unchecked failure inside a stage
    local rc=$?
    warn "Unexpected failure in stage '$CUR_STAGE' (status $rc) at ${BASH_SOURCE[0]}:${LINENO}"
    abort_report "$CUR_STAGE" "$([ "$rc" -eq 0 ] && echo 1 || echo "$rc")"
}
set -E
trap on_err ERR

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
slugify() {
    printf '%s' "$1" \
        | tr '[:upper:]' '[:lower:]' \
        | tr -c 'a-z0-9' '-' \
        | sed 's/-\{2,\}/-/g; s/^-//; s/-$//' \
        | cut -c1-48
}

tree_files() {  # tree_files <dir> — number of regular files below it
    [ -d "$1" ] || { echo 0; return 0; }
    find "$1" -type f 2>/dev/null | wc -l | tr -d ' '
}

tree_audio_files() {  # tree_audio_files <dir>: rows are compared against audio only
    [ -d "$1" ] || { echo 0; return 0; }
    find "$1" -type f \
        \( -iname '*.flac' -o -iname '*.mp3' -o -iname '*.opus' -o -iname '*.m4a' \
            -o -iname '*.ogg' -o -iname '*.wav' -o -iname '*.ape' -o -iname '*.wv' \
            -o -iname '*.aiff' -o -iname '*.dsf' -o -iname '*.dff' \) 2>/dev/null \
        | wc -l | tr -d ' '
}

tree_bytes() {  # tree_bytes <dir>
    [ -d "$1" ] || { echo 0; return 0; }
    find "$1" -type f -printf '%s\n' 2>/dev/null | awk '{s+=$1} END {printf "%d", s+0}'
}

share_owner() {
    stat -c '%u:%g' "$1" 2>/dev/null || stat -f '%u:%g' "$1" 2>/dev/null || echo "$OWNER"
}

kv_of() {  # kv_of <file> <key>
    sed -n "s/^$2=//p" "$1" | tail -n 1
}

# Read-only SQL against the live Navidrome database, from inside its container.
# python3 is always there; the sqlite3 CLI is not installed.
ND_QUERY_PY='
import sqlite3, sys
con = sqlite3.connect("file:" + sys.argv[1] + "?mode=ro", uri=True, timeout=10)
con.row_factory = sqlite3.Row
for row in con.execute(sys.argv[2], sys.argv[3:]):
    print("|".join("" if v is None else str(v) for v in row))
'

nd_query() {  # nd_query <sql> [params...]
    local sql="$1"
    shift
    pct exec "$NAVIDROME_CT" -- python3 -c "$ND_QUERY_PY" "$ND_DB_CT" "$sql" "$@"
}

nd_release_rows() {  # nd_release_rows <release>
    nd_query "select count(*) from media_file where path = ? or path like ? || '/%'" "$1" "$1"
}

# Navidrome prints a banner before the JSON array; keep everything from the first
# '[' and store the parsed array. Echoes the entry count.
nd_missing_inventory() {  # nd_missing_inventory <target.json>
    local target="$1"
    local raw="$target.raw"
    local rc=0
    CLEANUP_FILES+=("$raw")
    navidrome_cli missing list -f json >"$raw" 2>"$raw.err" || rc=$?
    CLEANUP_FILES+=("$raw.err")
    if [ "$rc" -ne 0 ]; then
        warn "navidrome missing list failed (status $rc):"
        sed 's/^/    /' "$raw.err" >&2 || true
        return 1
    fi
    python3 - "$raw" "$target" <<'PY'
import json, sys
raw = open(sys.argv[1], encoding="utf-8", errors="replace").read()
start = raw.find("[")
if start < 0:
    sys.stderr.write("no JSON array in the missing-list output\n")
    raise SystemExit(1)
try:
    data, _ = json.JSONDecoder().raw_decode(raw[start:])
except ValueError as exc:
    sys.stderr.write("unparsable missing-list JSON: %s\n" % exc)
    raise SystemExit(1)
if not isinstance(data, list):
    sys.stderr.write("missing-list JSON is not an array\n")
    raise SystemExit(1)
json.dump(data, open(sys.argv[2], "w"), indent=2, sort_keys=True)
print(len(data))
PY
}

config_value() {  # config_value <key> — from the persistent Navidrome config
    pct exec "$NAVIDROME_CT" -- sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$NAVIDROME_CONFIG" \
        | tr -d '"' | tail -n 1
}

navidrome_targeted_scan() {  # <always|never> <release>
    pct exec "$NAVIDROME_CT" -- env "ND_SCANNER_PURGEMISSING=$1" \
        /usr/bin/navidrome -c "$NAVIDROME_CONFIG" scan -t "$NAVIDROME_LIBRARY_ID:$2"
}

# ---------------------------------------------------------------------------
# The purge gate (design D8): set arithmetic over missing-file inventories
# ---------------------------------------------------------------------------
gate_py() {  # gate_py <gate arguments>
    python3 - "$@" <<'PY'
import json, os, sqlite3, sys

def parse(argv):
    args = list(argv)
    opts = {}
    while args:
        flag = args.pop(0)
        if flag in ("--allowed-json", "--baseline", "--after"):
            opts[flag] = args.pop(0)
        elif flag == "--allowed-db":
            opts[flag] = (args.pop(0), args.pop(0))
        elif flag == "--allowed-prefix":
            opts[flag] = args.pop(0)
        else:
            sys.stderr.write("gate: unknown argument %s\n" % flag)
            raise SystemExit(2)
    return opts

def load_json(path):
    try:
        raw = open(path, encoding="utf-8", errors="replace").read()
    except OSError as exc:
        sys.stderr.write("gate: cannot read %s: %s\n" % (path, exc))
        raise SystemExit(2)
    start = raw.find("[")
    if start < 0:
        sys.stderr.write("gate: no JSON array in %s\n" % path)
        raise SystemExit(2)
    try:
        data, _ = json.JSONDecoder().raw_decode(raw[start:])
    except ValueError as exc:
        sys.stderr.write("gate: unparsable JSON in %s: %s\n" % (path, exc))
        raise SystemExit(2)
    if not isinstance(data, list):
        sys.stderr.write("gate: %s does not hold a JSON array\n" % path)
        raise SystemExit(2)
    return data

def eid(entry):
    for key in ("id", "ID", "mediaFileId"):
        if entry.get(key):
            return str(entry[key])
    return ""

def epath(entry):
    for key in ("path", "Path"):
        if entry.get(key):
            return str(entry[key])
    return ""

def under(path, prefix):
    path, prefix = path.lstrip("/"), prefix.strip("/")
    return bool(prefix) and (path == prefix
                             or path.startswith(prefix + "/")
                             or ("/" + prefix + "/") in ("/" + path))

def allowed_from_db(db, prefix):
    if not os.path.exists(db):
        sys.stderr.write("gate: no snapshot at %s\n" % db)
        raise SystemExit(2)
    con = sqlite3.connect("file:%s?mode=ro" % db, uri=True)
    rows = con.execute(
        "select id, path from media_file where path = ? or path like ? || '/%'", (prefix, prefix)
    ).fetchall()
    return [{"id": r[0], "path": r[1]} for r in rows]

def main(argv):
    opts = parse(argv)
    prefix = opts.get("--allowed-prefix", "")
    if "--allowed-json" in opts:
        allowed = load_json(opts["--allowed-json"])
    elif "--allowed-db" in opts:
        allowed = allowed_from_db(*opts["--allowed-db"])
    elif "--allowed-prefix" in opts:
        allowed = [{"path": prefix}]
    else:
        sys.stderr.write("gate: one of --allowed-json/--allowed-db/--allowed-prefix is required\n")
        return 2
    if "--baseline" not in opts and "--after" not in opts:
        sys.stderr.write("gate: one of --baseline/--after is required\n")
        return 2

    allowed_ids = {eid(e) for e in allowed if eid(e)}
    allowed_paths = [epath(e) for e in allowed if epath(e)]
    if not prefix and allowed_paths:
        # Derive the tightest common folder of the release's own rows, so a
        # sibling file inside the same release belongs even without an explicit
        # --allowed-prefix.
        try:
            common = os.path.commonpath(allowed_paths)
        except ValueError:
            common = ""
        if common and common in allowed_paths:
            # A single row: keep its own folder, so siblings still belong.
            common = os.path.dirname(common)
        if common and common not in (".", "/"):
            prefix = common

    def belongs(entry):
        ident, path = eid(entry), epath(entry)
        if ident and ident in allowed_ids:
            return True
        if prefix and path and under(path, prefix):
            return True
        return any(path and ap and (under(path, ap) or under(ap, path)) for ap in allowed_paths)

    sets = []
    if "--baseline" in opts:
        sets.append(("baseline", load_json(opts["--baseline"])))
    if "--after" in opts:
        sets.append(("after", load_json(opts["--after"])))

    surplus = []
    for name, entries in sets:
        for entry in entries:
            if not belongs(entry):
                surplus.append((name, eid(entry), epath(entry)))
        print("gate_set=%s count=%d" % (name, len(entries)))
    print("gate_allowed=%d" % len(allowed))

    if surplus:
        print("gate=abort")
        for name, ident, path in surplus:
            print("surplus=%s id=%s path=%s" % (name, ident or "?", path or "?"))
            sys.stderr.write("gate: the %s set holds an unrelated entry: %s %s\n" % (name, ident or "?", path or "?"))
        return 4
    print("gate=pass")
    return 0

sys.exit(main(sys.argv[1:]))
PY
}

# ---------------------------------------------------------------------------
# beets side (design D6): rm_album.py inside the existing image, tree at /data
# ---------------------------------------------------------------------------
beets_rm() {  # beets_rm <host tree root> <args...>
    local tree="$1"
    shift
    local ct_tree
    ct_tree="$(ct_path "$tree")" || die 4 "Cannot translate '$tree' to the LXC $BEETS_CT view"
    pct exec "$BEETS_CT" -- test -f "$ct_tree/library.db" \
        || die 3 "No beets database at '$ct_tree/library.db' inside LXC $BEETS_CT"
    pct exec "$BEETS_CT" -- test -f "$BEETS_TOOLS_CT/rm_album.py" \
        || die 4 "rm_album.py is not deployed to '$BEETS_TOOLS_CT' in LXC $BEETS_CT (git pull there first)"
    pct exec "$BEETS_CT" -- docker run --rm --user 0:0 \
        -v "$ct_tree:/data" -v "$BEETS_TOOLS_CT:/alpargatify/beets:ro" \
        --entrypoint python3 "$BEETS_IMAGE" /alpargatify/beets/rm_album.py --library /data "$@"
}

beets_check() {  # beets_check <tree> <release> <capture file> — read-only
    local rc=0
    beets_rm "$1" --path "$2" --check >"$3" 2>&1 || rc=$?
    return "$rc"
}

beets_backup_db() {  # beets_backup_db <tree>: library.db -> library.db.prev
    local ct_tree
    ct_tree="$(ct_path "$1")" || return 1
    pct exec "$BEETS_CT" -- sh -c \
        "cp -p '$ct_tree/library.db' '$ct_tree/library.db.prev.tmp' && mv -f '$ct_tree/library.db.prev.tmp' '$ct_tree/library.db.prev'"
}

# ---------------------------------------------------------------------------
# Stages
# ---------------------------------------------------------------------------
stage_preflight() {
    info "Version: $VERSION"
    info "Release: $RELEASE"
    kv tool "remove-album"
    kv version "$VERSION"
    kv stamp "$STAMP"
    kv release "$RELEASE"
    kv lossless_root "$LOSSLESS_ROOT"
    kv lossy_root "$LOSSY_ROOT"
    kv dry_run "$DRY_RUN"
    kv purge "$PURGE_MODE"

    # MUSICBUCKET defaults to the *container* view (/mnt/musicbucket) in
    # common.sh; on the PVE host the volume is /mnt/usb-hdd-wd-5tb/musicbucket.
    if [ "$MUSICBUCKET" = "$CT_MUSICBUCKET" ] && [ ! -d "$MUSICBUCKET" ]; then
        die 4 "MUSICBUCKET is still the container view ('$MUSICBUCKET'), which does not exist on this host; export MUSICBUCKET=/mnt/usb-hdd-wd-5tb/musicbucket first"
    fi
    local hint=""
    if [ ! -d "$MUSICBUCKET" ]; then
        hint=" (MUSICBUCKET must be the host view of the volume; on the PVE host: export MUSICBUCKET=/mnt/usb-hdd-wd-5tb/musicbucket)"
    fi
    [ -d "$LOSSLESS_ROOT" ] || die 4 "Lossless library root '$LOSSLESS_ROOT' does not exist$hint"
    [ -d "$LOSSY_ROOT" ] || die 4 "Lossy library root '$LOSSY_ROOT' does not exist$hint"
    command -v pct >/dev/null 2>&1 || die 4 "pct not found: run this on the PVE host"

    # Invariants of the live stack: no scan may purge on its own, and a restart
    # must not run the scan we gate by hand.
    local cfg_purge cfg_scan
    cfg_purge="$(config_value PurgeMissing)"
    cfg_scan="$(config_value ScanOnStartup)"
    kv purge_policy "$cfg_purge"
    kv scan_on_startup "$cfg_scan"
    [ "$cfg_purge" = "never" ] \
        || die 4 "Persistent PurgeMissing is '$cfg_purge', not 'never' — every scan would purge unguarded"
    [ "$cfg_scan" = "false" ] \
        || die 4 "Persistent ScanOnStartup is '$cfg_scan' — a restart could scan and purge while we are not looking"

    if [ "$PURGE_MODE" = "api" ]; then
        if [ -z "${ND_API_URL:-}" ] || [ -z "${ND_API_USER:-}" ] || [ -z "${ND_API_PASSWORD:-}" ]; then
            die 4 "--purge api needs ND_API_URL, ND_API_USER and ND_API_PASSWORD (the server holds no Navidrome credentials)"
        fi
    fi

    local ldir="$LOSSLESS_ROOT/$RELEASE" ydir="$LOSSY_ROOT/$RELEASE"
    local l_exists=0 y_exists=0
    if [ -d "$ldir" ]; then l_exists=1; fi
    if [ -d "$ydir" ]; then y_exists=1; fi
    local l_files y_files l_audio y_audio nd_rows
    l_files="$(tree_files "$ldir")"
    y_files="$(tree_files "$ydir")"
    l_audio="$(tree_audio_files "$ldir")"
    y_audio="$(tree_audio_files "$ydir")"
    nd_rows="$(nd_release_rows "$RELEASE")"
    kv lossless_files "$l_files"
    kv lossless_audio "$l_audio"
    kv lossless_bytes "$(tree_bytes "$ldir")"
    kv lossy_files "$y_files"
    kv lossy_audio "$y_audio"
    kv lossy_bytes "$(tree_bytes "$ydir")"
    kv navidrome_rows "$nd_rows"

    # Album identity, read-only, from both databases.
    local lrep="$OPS_DIR/.preflight-lossless-$STAMP.txt"
    local yrep="$OPS_DIR/.preflight-lossy-$STAMP.txt"
    CLEANUP_FILES+=("$lrep" "$yrep")
    local lrc=0 yrc=0
    beets_check "$LOSSLESS_ROOT" "$RELEASE" "$lrep" || lrc=$?
    beets_check "$LOSSY_ROOT" "$RELEASE" "$yrep" || yrc=$?
    LOSSLESS_ALBUM="$(kv_of "$lrep" album_id)"
    LOSSLESS_ITEMS="$(kv_of "$lrep" items)"
    LOSSLESS_ORPHANS="$(kv_of "$lrep" orphan_items)"
    LOSSY_ALBUM="$(kv_of "$yrep" album_id)"
    LOSSY_ITEMS="$(kv_of "$yrep" items)"
    LOSSY_ORPHANS="$(kv_of "$yrep" orphan_items)"
    local lmb ymb
    lmb="$(kv_of "$lrep" mb_albumid)"
    ymb="$(kv_of "$yrep" mb_albumid)"
    kv lossless_album_id "${LOSSLESS_ALBUM:-none}"
    kv lossless_items "${LOSSLESS_ITEMS:-0}"
    kv lossless_orphan_rows "${LOSSLESS_ORPHANS:-0}"
    kv lossy_album_id "${LOSSY_ALBUM:-none}"
    kv lossy_items "${LOSSY_ITEMS:-0}"
    kv lossy_orphan_rows "${LOSSY_ORPHANS:-0}"
    kv mb_albumid "${lmb:-${ymb:-}}"

    if [ "$lrc" -eq 4 ]; then
        die 4 "The lossless database refuses this identity ($(kv_of "$lrep" reason)); see $lrep"
    fi
    if [ "$yrc" -eq 4 ]; then
        die 4 "The lossy database refuses this identity ($(kv_of "$yrep" reason)); see $yrep"
    fi
    if [ "$lrc" -ne 0 ] && [ "$lrc" -ne 3 ]; then
        die 4 "Reading the lossless database failed (status $lrc); see $lrep"
    fi
    if [ "$yrc" -ne 0 ] && [ "$yrc" -ne 3 ]; then
        die 4 "Reading the lossy database failed (status $yrc); see $yrep"
    fi

    if [ "$l_exists" -eq 0 ] && [ "$y_exists" -eq 0 ] \
        && [ -z "$LOSSLESS_ALBUM" ] && [ -z "$LOSSY_ALBUM" ] && [ "$nd_rows" = "0" ]; then
        kv result "unknown-release"
        die 3 "Release '$RELEASE' is in no store: neither tree, neither beets database, Navidrome"
    fi

    if [ -n "$lmb" ] && [ -n "$ymb" ] && [ "$lmb" != "$ymb" ]; then
        die 4 "The two databases disagree about this release: lossless mb_albumid=$lmb, lossy mb_albumid=$ymb"
    fi

    # Asymmetry is reported, never fatal (spec: one database may lack a release).
    local asymmetric=no
    if [ -z "$LOSSLESS_ALBUM" ] || [ -z "$LOSSY_ALBUM" ]; then
        asymmetric=yes
        warn "Asymmetry: lossless album=${LOSSLESS_ALBUM:-none}, lossy album=${LOSSY_ALBUM:-none} — removing only what exists"
    fi
    if [ "$l_exists" -ne "$y_exists" ]; then
        asymmetric=yes
        warn "Asymmetry: the release folder exists in lossless=$l_exists lossy=$y_exists"
    fi
    kv asymmetry "$asymmetric"
    if [ -n "$LOSSLESS_ALBUM" ] && [ "${LOSSLESS_ITEMS:-0}" != "$l_audio" ]; then
        kv lossless_rows_vs_tracks "${LOSSLESS_ITEMS}/${l_audio}"
        warn "Lossless: $LOSSLESS_ITEMS rows against $l_audio audio files on disk"
    fi
    if [ -n "$LOSSY_ALBUM" ] && [ "${LOSSY_ITEMS:-0}" != "$y_audio" ]; then
        kv lossy_rows_vs_tracks "${LOSSY_ITEMS}/${y_audio}"
        warn "Lossy: $LOSSY_ITEMS rows against $y_audio audio files on disk (${LOSSY_ORPHANS:-0} rows carry a path outside the release)"
    fi

    if [ "$DRY_RUN" -eq 0 ] && [ "$ASSUME_YES" -eq 0 ]; then
        [ -t 0 ] || die 4 "Refusing to run unattended without --yes"
        echo
        warn "This removes '$RELEASE' from:"
        echo "    tree    $LOSSLESS_ROOT  (album ${LOSSLESS_ALBUM:-none}, ${LOSSLESS_ITEMS:-0} rows, $l_files files)"
        echo "    tree    $LOSSY_ROOT  (album ${LOSSY_ALBUM:-none}, ${LOSSY_ITEMS:-0} rows, $y_files files)"
        echo "    library Navidrome  ($nd_rows rows; purge mode: $PURGE_MODE)"
        echo "Files go to $TRASH_DIR and can be moved back; rows and Navidrome entries do not come back with a move."
        printf 'Type the release name to confirm: '
        local answer
        read -r answer
        [ "$answer" = "$RELEASE" ] || die 4 "Confirmation did not match; nothing was done"
    fi
    return 0
}

stage_snapshot() {
    if [ "$DRY_RUN" -eq 1 ]; then
        info "DRY RUN: would run $SNAPSHOT_SCRIPT --keep $KEEP_SNAPSHOTS"
        kv snapshot "dry-run"
        return 0
    fi
    local out="$OPS_DIR/.snapshot-$STAMP.txt"
    CLEANUP_FILES+=("$out")
    local rc=0
    "$SNAPSHOT_SCRIPT" --keep "$KEEP_SNAPSHOTS" >"$out" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
        warn "Snapshot failed (status $rc):"
        sed 's/^/    /' "$out" >&2 || true
        die 4 "No verified snapshot, so nothing was touched"
    fi
    SNAP_PATH="$(kv_of "$out" snapshot)"
    [ -n "$SNAP_PATH" ] || die 4 "The snapshot script did not report a snapshot path"
    # `backup restore -b` runs inside the CT and resolves relative to Backup.Path,
    # so the recipe has to name the file the CT will see, not the host path.
    SNAP_CT_NAME="navidrome_backup_$(basename "$SNAP_PATH" | sed 's/^navidrome-//')"
    kv snapshot "$SNAP_PATH"
    kv snapshot_media_file "$(kv_of "$out" media_file)"
    success "Verified snapshot: $SNAP_PATH"
    return 0
}

stage_baseline() {
    if [ "$DRY_RUN" -eq 1 ]; then
        info "DRY RUN: would capture the missing baseline and the allowed set"
        kv baseline_missing "dry-run"
        kv gate_allowed "dry-run"
        BASE_INV="/dev/null"
        ALLOWED_INV="/dev/null"
        return 0
    fi
    BASE_INV="$OPS_DIR/.missing-baseline-$STAMP.json"
    # nd_missing_inventory is called in a command substitution, so a subshell does
    # its CLEANUP_FILES bookkeeping: register its side files here instead.
    CLEANUP_FILES+=("$BASE_INV" "$BASE_INV.raw" "$BASE_INV.raw.err")
    local count
    if ! count="$(nd_missing_inventory "$BASE_INV")"; then
        die 4 "Could not capture the baseline missing set — the purge gate needs it, so nothing was touched"
    fi
    kv baseline_missing "$count"
    success "Baseline missing set: $count file(s)"

    ALLOWED_INV="$OPS_DIR/.gate-allowed-$STAMP.json"
    local rows="$OPS_DIR/.allowed-rows-$STAMP.txt"
    CLEANUP_FILES+=("$ALLOWED_INV" "$rows")
    nd_query "select id, path from media_file where path = ? or path like ? || '/%'" "$RELEASE" "$RELEASE" >"$rows"
    local nallowed
    nallowed="$(python3 - "$rows" "$ALLOWED_INV" <<'PY'
import json, sys
rows = []
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    line = line.rstrip("\n")
    if not line:
        continue
    ident, _, path = line.partition("|")
    rows.append({"id": ident, "path": path})
json.dump(rows, open(sys.argv[2], "w"), indent=2, sort_keys=True)
print(len(rows))
PY
)"
    EXPECTED_COUNT="$nallowed"
    kv gate_allowed "$nallowed"
    success "Allowed set (the release's own rows): $nallowed"
    return 0
}

stage_gate_baseline() {
    if [ "$DRY_RUN" -eq 1 ]; then
        info "DRY RUN: the gate would compare the baseline with the release's own row ids"
        kv gate_baseline "dry-run"
        return 0
    fi
    local out="$OPS_DIR/.gate1-$STAMP.txt"
    CLEANUP_FILES+=("$out")
    local rc=0
    gate_py --allowed-json "$ALLOWED_INV" --allowed-prefix "$RELEASE" --baseline "$BASE_INV" >"$out" 2>&1 || rc=$?
    if [ "$rc" -eq 4 ]; then
        grep -E '^(gate_set|surplus)=' "$out" | sed 's/^/    /' >&2 || true
        kv gate_baseline "abort"
        die 4 "Purge gate: the baseline missing set already holds files that do not belong to '$RELEASE'; no purge will run"
    fi
    if [ "$rc" -ne 0 ]; then
        warn "Gate error:"
        sed 's/^/    /' "$out" >&2 || true
        die 4 "The purge gate could not be evaluated (status $rc)"
    fi
    grep -E '^gate_set=' "$out" | sed 's/^/    /' >&2 || true
    kv gate_baseline "pass"
    return 0
}

stage_rows() {
    if [ "$DRY_RUN" -eq 1 ]; then
        info "DRY RUN: would remove beets rows (rows first, D11)"
        if [ -n "$LOSSLESS_ALBUM" ]; then
            info "    pct exec $BEETS_CT -- docker run --rm --user 0:0 -v $(ct_path "$LOSSLESS_ROOT"):/data ... rm_album.py --library /data --album-id $LOSSLESS_ALBUM --expect-album-id $LOSSLESS_ALBUM"
        fi
        if [ -n "$LOSSY_ALBUM" ]; then
            info "    pct exec $BEETS_CT -- docker run --rm --user 0:0 -v $(ct_path "$LOSSY_ROOT"):/data ... rm_album.py --library /data --album-id $LOSSY_ALBUM --expect-album-id $LOSSY_ALBUM"
        fi
        kv rows_lossless "dry-run"
        kv rows_lossy "dry-run"
        return 0
    fi
    local pair label tree album rep rc
    for pair in "lossless:$LOSSLESS_ROOT:$LOSSLESS_ALBUM" "lossy:$LOSSY_ROOT:$LOSSY_ALBUM"; do
        IFS=: read -r label tree album <<<"$pair"
        if [ -z "$album" ]; then
            info "$label: this database holds no album for the release — skipped (asymmetry)"
            kv "rows_$label" "absent"
            continue
        fi
        info "$label: removing album $album from $(ct_path "$tree")/library.db"
        beets_backup_db "$tree" || die 4 "$label: could not keep library.db.prev — nothing was removed"
        rep="$OPS_DIR/.rm-$label-$STAMP.txt"
        CLEANUP_FILES+=("$rep")
        rc=0
        beets_rm "$tree" --album-id "$album" --expect-album-id "$album" >"$rep" 2>&1 || rc=$?
        if [ "$rc" -ne 0 ]; then
            warn "$label: row removal failed (status $rc):"
            sed 's/^/    /' "$rep" >&2 || true
            kv "rows_$label" "failed"
            die 1 "$label rows were not removed and the files were not moved (see $rep)"
        fi
        kv "rows_$label" "removed"
        kv "rows_${label}_items" "$(kv_of "$rep" removed_items)"
        ROWS_REMOVED=1
        success "$label: $(kv_of "$rep" removed_items) rows removed (album $album)"
    done
    return 0
}

restore_moved() {  # restore_moved <src|dst>...
    local entry src dst
    for entry in "$@"; do
        [ -n "$entry" ] || continue
        src="${entry%%|*}"
        dst="${entry#*|}"
        if [ -e "$dst" ] && [ ! -e "$src" ]; then
            mkdir -p "$(dirname "$src")"
            if mv "$dst" "$src"; then
                warn "Rolled back: $dst -> $src"
                RESTORED+=("$src")
            else
                warn "Could not move '$dst' back to '$src' — restore it by hand"
            fi
        fi
    done
}

stage_trash() {
    TRASH_RUN_DIR="$TRASH_DIR/$STAMP-$(slugify "$ARTIST")-$(slugify "$ALBUM")"
    kv trash_run "$TRASH_RUN_DIR"
    if [ "$DRY_RUN" -eq 1 ]; then
        info "DRY RUN: would move (files second, D11)"
        if [ -d "$LOSSLESS_ROOT/$RELEASE" ]; then
            info "    $LOSSLESS_ROOT/$RELEASE -> $TRASH_RUN_DIR/lossless/$RELEASE"
        else
            info "    (no lossless folder to move)"
        fi
        if [ -d "$LOSSY_ROOT/$RELEASE" ]; then
            info "    $LOSSY_ROOT/$RELEASE -> $TRASH_RUN_DIR/lossy/$RELEASE"
        else
            info "    (no lossy folder to move)"
        fi
        kv trash_moved "dry-run"
        return 0
    fi

    local owner moved=() pair label root src dst
    owner="$(share_owner "$MUSICBUCKET")"
    for pair in "lossless:$LOSSLESS_ROOT" "lossy:$LOSSY_ROOT"; do
        IFS=: read -r label root <<<"$pair"
        src="$root/$RELEASE"
        # One level per tree: both trees hold the same relative path, so the
        # Artist/Album levels alone would collide (design D7).
        dst="$TRASH_RUN_DIR/$label/$RELEASE"
        if [ ! -e "$src" ]; then
            info "$label: nothing at $src — skipped (asymmetry)"
            kv "trash_$label" "absent"
            continue
        fi
        if [ -e "$dst" ]; then
            restore_moved "${moved[@]+"${moved[@]}"}"
            die 4 "$label: '$dst' already exists; refusing to overwrite a trashed copy"
        fi
        mkdir -p "$(dirname "$dst")"
        chown "$owner" "$TRASH_RUN_DIR" "$TRASH_RUN_DIR/$label" "$(dirname "$dst")" 2>/dev/null \
            || warn "Could not hand $TRASH_RUN_DIR/$label to $owner"
        if ! mv "$src" "$dst"; then
            restore_moved "${moved[@]+"${moved[@]}"}"
            die 4 "$label: the move to trash failed"
        fi
        moved+=("$src|$dst")
        kv "trash_$label" "moved"
        success "$label: moved to $dst"
        # An emptied Artist directory is exactly what leaves a `folder` row behind
        # in Navidrome, so drop it. rmdir refuses anything that is not empty.
        local artist_dir
        artist_dir="$(dirname "$src")"
        if [ -d "$artist_dir" ] && [ "$artist_dir" != "$root" ]; then
            if rmdir "$artist_dir" 2>/dev/null; then
                kv "trash_${label}_artist_dir" "empty-removed"
            fi
        fi
    done
    kv trash_moved "${#moved[@]}"
    return 0
}

stage_rescan() {
    if [ "$DRY_RUN" -eq 1 ]; then
        info "DRY RUN: would run (marking pass, no purge)"
        info "    pct exec $NAVIDROME_CT -- env ND_SCANNER_PURGEMISSING=never /usr/bin/navidrome -c $NAVIDROME_CONFIG scan -t $NAVIDROME_LIBRARY_ID:\"$RELEASE\""
        kv rescan "dry-run"
        AFTER_INV="/dev/null"
        return 0
    fi
    info "Marking scan of $NAVIDROME_LIBRARY_ID:\"$RELEASE\" (PURGEMISSING=never)"
    local rc=0
    navidrome_targeted_scan never "$RELEASE" 2>&1 | sed 's/^/    /' || rc=$?
    if [ "$rc" -ne 0 ]; then
        die 1 "The targeted scan failed (status $rc); files are in trash, Navidrome rows are untouched"
    fi
    AFTER_INV="$OPS_DIR/.missing-after-$STAMP.json"
    CLEANUP_FILES+=("$AFTER_INV" "$AFTER_INV.raw" "$AFTER_INV.raw.err")
    local count
    if ! count="$(nd_missing_inventory "$AFTER_INV")"; then
        die 4 "Could not re-read the missing set; no purge will run"
    fi
    kv after_missing "$count"
    success "Missing set after the marking scan: $count file(s)"
    return 0
}

stage_gate_after() {
    if [ "$DRY_RUN" -eq 1 ]; then
        info "DRY RUN: the gate would compare baseline plus post-scan missing sets"
        kv gate_after "dry-run"
        return 0
    fi
    local out="$OPS_DIR/.gate2-$STAMP.txt"
    CLEANUP_FILES+=("$out")
    local rc=0
    gate_py --allowed-json "$ALLOWED_INV" --allowed-prefix "$RELEASE" --baseline "$BASE_INV" --after "$AFTER_INV" >"$out" 2>&1 || rc=$?
    if [ "$rc" -eq 4 ]; then
        grep -E '^(gate_set|surplus)=' "$out" | sed 's/^/    /' >&2 || true
        kv gate_after "abort"
        die 4 "Purge gate: the missing set now holds files that do not belong to '$RELEASE'; no purge, every Navidrome row stays"
    fi
    if [ "$rc" -ne 0 ]; then
        warn "Gate error:"
        sed 's/^/    /' "$out" >&2 || true
        die 4 "The purge gate could not be evaluated (status $rc)"
    fi
    grep -E '^gate_set=' "$out" | sed 's/^/    /' >&2 || true
    kv gate_after "pass"
    return 0
}

stage_purge() {
    # DeleteAllMissing() is library-wide: with no expected ids the gate could
    # only be vacuous, so a purge is never allowed to run on an empty set.
    if [ "$DRY_RUN" -eq 0 ] && [ "$PURGE_MODE" != "none" ] && [ "${EXPECTED_COUNT:-0}" -eq 0 ]; then
        kv purge_ran "refused"
        die 4 "Refusing to purge: the expected set is empty (0 of the release's own media_file rows), so nothing bounds the library-wide purge; use --purge none to remove the files and leave Navidrome alone"
    fi
    case "$PURGE_MODE" in
        none)
            info "--purge none: leaving the Navidrome rows in place"
            kv purge_ran "no"
            PURGE_MODE_EFFECTIVE="none"
            return 0
            ;;
        api)
            if [ "$DRY_RUN" -eq 1 ]; then
                info "DRY RUN: would log in to $ND_API_URL and DELETE /api/missing?id=<each new missing row>"
                kv purge_ran "dry-run"
                return 0
            fi
            info "API purge: deleting this release's missing rows by id"
            local rc=0
            ND_API_URL="$ND_API_URL" python3 - "$BASE_INV" "$AFTER_INV" <<'PY' || rc=$?
import json, os, sys, urllib.parse, urllib.request

def ids(path):
    return [str(e.get("id")) for e in json.load(open(path)) if e.get("id")]

baseline_path, after_path = sys.argv[1], sys.argv[2]
base_url = os.environ["ND_API_URL"].rstrip("/")
before = set(ids(baseline_path))
targets = [i for i in ids(after_path) if i not in before]
if any(i in before for i in targets):
    sys.stderr.write("refusing to delete an id that was already missing before the run\n")
    raise SystemExit(4)
payload = json.dumps({"username": os.environ["ND_API_USER"],
                      "password": os.environ["ND_API_PASSWORD"]}).encode()
req = urllib.request.Request(base_url + "/auth/login", data=payload,
                             headers={"Content-Type": "application/json"}, method="POST")
with urllib.request.urlopen(req, timeout=30) as resp:
    token = json.load(resp)["token"]
for ident in targets:
    url = base_url + "/api/missing?" + urllib.parse.urlencode({"id": ident})
    req = urllib.request.Request(url, headers={"X-Nd-Authorization": "Bearer " + token}, method="DELETE")
    with urllib.request.urlopen(req, timeout=60) as resp:
        print("deleted %s (%s)" % (ident, resp.status))
print("deleted %d row(s)" % len(targets))
PY
            if [ "$rc" -ne 0 ]; then
                kv purge_ran "failed"
                die 1 "The API purge failed (status $rc); the rows are still there and the files are in trash"
            fi
            PURGE_RAN=1
            kv purge_ran "api"
            PURGE_MODE_EFFECTIVE="api"
            return 0
            ;;
        auto)
            if [ "$DRY_RUN" -eq 1 ]; then
                info "DRY RUN: would run, only after a passing gate:"
                info "    pct exec $NAVIDROME_CT -- env ND_SCANNER_PURGEMISSING=always /usr/bin/navidrome -c $NAVIDROME_CONFIG scan -t $NAVIDROME_LIBRARY_ID:\"$RELEASE\""
                kv purge_ran "dry-run"
                return 0
            fi
            info "Purging scan of $NAVIDROME_LIBRARY_ID:\"$RELEASE\" (PURGEMISSING=always, this process only)"
            local rc=0
            navidrome_targeted_scan always "$RELEASE" 2>&1 | sed 's/^/    /' || rc=$?
            if [ "$rc" -ne 0 ]; then
                kv purge_ran "failed"
                die 1 "The purging scan failed (status $rc); check the missing set by hand"
            fi
            PURGE_RAN=1
            kv purge_ran "scan"
            PURGE_MODE_EFFECTIVE="scan"
            return 0
            ;;
    esac
}

stage_verify() {
    local problems=() l_exists=0 y_exists=0
    if [ -e "$LOSSLESS_ROOT/$RELEASE" ]; then l_exists=1; fi
    if [ -e "$LOSSY_ROOT/$RELEASE" ]; then y_exists=1; fi
    kv lossless_tree_after "$([ "$l_exists" -eq 0 ] && echo gone || echo present)"
    kv lossy_tree_after "$([ "$y_exists" -eq 0 ] && echo gone || echo present)"

    if [ "$DRY_RUN" -eq 1 ]; then
        info "DRY RUN: every store is byte-identical; nothing to verify"
        kv verify "dry-run"
        kv result "dry-run"
        return 0
    fi

    [ "$l_exists" -eq 0 ] || problems+=("the lossless tree still holds $LOSSLESS_ROOT/$RELEASE")
    [ "$y_exists" -eq 0 ] || problems+=("the lossy tree still holds $LOSSY_ROOT/$RELEASE")

    local pair label tree rep rc
    for pair in "lossless:$LOSSLESS_ROOT" "lossy:$LOSSY_ROOT"; do
        IFS=: read -r label tree <<<"$pair"
        rep="$OPS_DIR/.verify-$label-$STAMP.txt"
        CLEANUP_FILES+=("$rep")
        rc=0
        beets_check "$tree" "$RELEASE" "$rep" || rc=$?
        if [ "$rc" -eq 3 ]; then
            kv "beets_$label" "gone"
        else
            kv "beets_$label" "present"
            problems+=("the $label beets database still holds the release (album $(kv_of "$rep" album_id))")
        fi
    done

    local nd_rows
    nd_rows="$(nd_release_rows "$RELEASE")"
    kv navidrome_rows_after "$nd_rows"
    if [ "$nd_rows" = "0" ]; then
        kv navidrome "gone"
    else
        kv navidrome "$nd_rows row(s)"
        problems+=("Navidrome still lists $nd_rows media_file row(s) for the release")
    fi

    local final_inv="$OPS_DIR/.missing-final-$STAMP.json"
    CLEANUP_FILES+=("$final_inv" "$final_inv.raw" "$final_inv.raw.err")
    local nfinal="" nbaseline=""
    if nfinal="$(nd_missing_inventory "$final_inv")"; then
        nbaseline="$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))))' "$BASE_INV")"
        kv missing_final "$nfinal"
        kv missing_baseline "$nbaseline"
        [ "$nfinal" = "$nbaseline" ] || problems+=("the missing set did not return to baseline: $nbaseline before, $nfinal after")
    else
        problems+=("could not re-read the missing set after the purge")
    fi

    local after_purge_policy
    after_purge_policy="$(config_value PurgeMissing)"
    kv purge_policy_after "$after_purge_policy"
    [ "$after_purge_policy" = "never" ] || problems+=("the persistent PurgeMissing policy is no longer 'never' ($after_purge_policy)")
    kv purge_mode_used "$PURGE_MODE_EFFECTIVE"

    if [ "${#problems[@]}" -gt 0 ]; then
        local p
        for p in "${problems[@]}"; do
            kv leftover "$p"
            warn "LEFTOVER: $p"
        done
        kv verify "failed"
        kv result "leftovers"
        finish 1
    fi
    kv verify "clean"
    success "Gone from both trees, both beets databases and the Navidrome view; the missing set equals the baseline"
    return 0
}

abort_report() {  # abort_report <stage> <status>
    local stage="$1" status="$2"
    kv failed_stage "$stage"
    warn "Aborted in stage '$stage' (status $status)."
    local s
    if [ "${#COMPLETED[@]}" -gt 0 ]; then
        warn "Stages completed before the abort: ${COMPLETED[*]}"
        for s in "${COMPLETED[@]}"; do kv completed_stage "$s"; done
    else
        warn "No stage completed: nothing was changed."
    fi
    if [ -n "$TRASH_RUN_DIR" ] && [ -d "$TRASH_RUN_DIR" ]; then
        # Between the trash stage and the rows stage the file move is the only
        # change made to the release, so that is the one window where moving the
        # files back restores the previous state exactly. Once rows are gone or a
        # purge ran, moving the files back would only create a new mismatch: the
        # operator gets the commands instead. --keep-trash keeps even that window
        # untouched, for inspection.
        if [ "$KEEP_TRASH" -eq 0 ] && [ "$ROWS_REMOVED" -eq 0 ] && [ "$PURGE_RAN" -eq 0 ]; then
            restore_moved "$LOSSLESS_ROOT/$RELEASE|$TRASH_RUN_DIR/lossless/$RELEASE" \
                          "$LOSSY_ROOT/$RELEASE|$TRASH_RUN_DIR/lossy/$RELEASE"
            find "$TRASH_RUN_DIR" -depth -type d -empty -delete 2>/dev/null || true
        fi
        if [ -d "$TRASH_RUN_DIR" ]; then
            warn "Trash holds:"
            find "$TRASH_RUN_DIR" -mindepth 1 -maxdepth 4 -type d 2>/dev/null | sed 's/^/    /' >&2 || true
            warn "To undo the file move:"
            kv restore "mv '$TRASH_RUN_DIR/lossless/$RELEASE' '$LOSSLESS_ROOT/$RELEASE'    # if present in trash"
            kv restore "mv '$TRASH_RUN_DIR/lossy/$RELEASE' '$LOSSY_ROOT/$RELEASE'          # if present in trash"
            kv restore "pct exec $NAVIDROME_CT -- /usr/bin/navidrome -c $NAVIDROME_CONFIG scan -t $NAVIDROME_LIBRARY_ID:\"$RELEASE\""
            if [ "$KEEP_TRASH" -eq 1 ]; then
                warn "--keep-trash was given: the files stay in trash"
            fi
        else
            warn "Nothing is left in trash: the file move was undone, every store is as it was."
        fi
        if [ "${#RESTORED[@]}" -gt 0 ]; then
            warn "Already moved back: ${RESTORED[*]}"
        fi
    fi
    if [ "$ROWS_REMOVED" -eq 1 ]; then
        kv restore "beets rows: stop beets, then cp library.db.prev over library.db inside LXC $BEETS_CT"
    fi
    if [ "$PURGE_RAN" -eq 1 ] && [ -n "$SNAP_PATH" ]; then
        kv restore "Navidrome: pct exec $NAVIDROME_CT -- systemctl stop navidrome"
        kv restore "Navidrome: pct push $NAVIDROME_CT '$SNAP_PATH' '$CT_BACKUP_DIR/$SNAP_CT_NAME'"
        kv restore "Navidrome: pct exec $NAVIDROME_CT -- /usr/bin/navidrome -c $NAVIDROME_CONFIG backup restore -f -b '$SNAP_CT_NAME'"
        kv restore "Navidrome: pct exec $NAVIDROME_CT -- systemctl start navidrome"
    fi
    kv result "aborted"
    finish "$status"
}

begin_stage() {  # begin_stage <name>: banner + the stage the report blames
    STAGE_NUM=$((STAGE_NUM + 1))
    CUR_STAGE="$1"
    printf '\n' >&2
    printf '%s-- [%d/10] %s%s\n' "${BLUE:-}" "$STAGE_NUM" "$1" "${NC:-}" >&2
}

end_stage() {  # end_stage <name>
    COMPLETED+=("$1")
    CUR_STAGE="between-stages"
}

# ---------------------------------------------------------------------------
# gate subcommand
# ---------------------------------------------------------------------------
if [ "${1:-}" = "gate" ]; then
    shift
    rc=0
    gate_py "$@" || rc=$?
    exit "$rc"
fi

while [ "$#" -gt 0 ]; do
    case "$1" in
        --release) [ "$#" -ge 2 ] || die 2 "--release needs a value"; RELEASE="$2"; shift 2 ;;
        --release=*) RELEASE="${1#*=}"; shift ;;
        --lossless-root) [ "$#" -ge 2 ] || die 2 "--lossless-root needs a value"; LOSSLESS_ROOT="$2"; shift 2 ;;
        --lossy-root) [ "$#" -ge 2 ] || die 2 "--lossy-root needs a value"; LOSSY_ROOT="$2"; shift 2 ;;
        --purge) [ "$#" -ge 2 ] || die 2 "--purge needs a value"; PURGE_MODE="$2"; shift 2 ;;
        --purge=*) PURGE_MODE="${1#*=}"; shift ;;
        --beets-tools-dir) [ "$#" -ge 2 ] || die 2 "--beets-tools-dir needs a value"; BEETS_TOOLS_CT="$2"; shift 2 ;;
        --keep) [ "$#" -ge 2 ] || die 2 "--keep needs a value"; KEEP_SNAPSHOTS="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --yes|-y) ASSUME_YES=1; shift ;;
        --keep-trash) KEEP_TRASH=1; shift ;;
        --json) JSON=1; shift ;;
        -h|--help) usage; exit 0 ;;
        --*) usage >&2; die 2 "Unknown option: $1" ;;
        *)
            [ -z "$RELEASE" ] || { usage >&2; die 2 "Unexpected argument: $1"; }
            RELEASE="$1"
            shift
            ;;
    esac
done

case "$PURGE_MODE" in
    auto|api|none) ;;
    *) die 2 "--purge must be auto, api or none (got '$PURGE_MODE')" ;;
esac

[ -n "$RELEASE" ] || { usage >&2; die 2 "--release is required"; }
RELEASE="${RELEASE#./}"
RELEASE="${RELEASE#/}"
RELEASE="${RELEASE%/}"
case "$RELEASE" in
    *..*) die 2 "--release must stay inside the library, got '$RELEASE'" ;;
    */*/*) die 2 "--release must be 'Artist/Album', got '$RELEASE'" ;;
    */*) ;;
    *) die 2 "--release must be 'Artist/Album', got '$RELEASE'" ;;
esac
ARTIST="${RELEASE%%/*}"
ALBUM="${RELEASE#*/}"
[ -n "$ARTIST" ] && [ -n "$ALBUM" ] || die 2 "--release needs a non-empty artist and album"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$OPS_DIR" 2>/dev/null || die 4 "Cannot create $OPS_DIR"

info "Guarded removal of '$RELEASE'"
if [ "$DRY_RUN" -eq 1 ]; then
    info "DRY RUN — nothing will be changed"
fi

begin_stage "preflight"
stage_preflight
end_stage "preflight"
begin_stage "snapshot"
stage_snapshot
end_stage "snapshot"
begin_stage "baseline-missing"
stage_baseline
end_stage "baseline-missing"
begin_stage "gate-baseline"
stage_gate_baseline
end_stage "gate-baseline"
begin_stage "beets-rows"
stage_rows
end_stage "beets-rows"
begin_stage "trash"
stage_trash
end_stage "trash"
begin_stage "targeted-scan"
stage_rescan
end_stage "targeted-scan"
begin_stage "gate-after"
stage_gate_after
end_stage "gate-after"
begin_stage "purge"
stage_purge
end_stage "purge"
begin_stage "verify"
stage_verify
end_stage "verify"

if [ "$DRY_RUN" -eq 1 ]; then
    info "DRY RUN complete — every store is unchanged"
    kv result "dry-run"
    finish 0
fi

if [ "$PURGE_MODE" = "none" ] && [ "${EXPECTED_COUNT:-0}" -gt 0 ]; then
    kv result "removed-rows-kept"
    success "Removed '$RELEASE' from both trees and both beets databases"
    warn "The $EXPECTED_COUNT Navidrome row(s) were left in place (--purge none), so they now show as missing"
    finish 1
fi
kv result "removed"
success "Removed '$RELEASE' from every store"
finish 0
