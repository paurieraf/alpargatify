#!/usr/bin/env python3
"""rm_album.py — remove one album and its items from a beets library, by identity.

This is the only supported way to take a release out of a beets database
(`beets/rm_album.py`, design D6 of the `album-doctor-and-removal` change). It
never unlinks audio: rows go, files stay wherever the caller put them, so the
release can be moved to trash by the shell wrapper and restored later.

It runs *inside* the `local/beets:latest` image on LXC 101, with the library
tree mounted at the same path the import used (e.g. `/mnt/musicbucket/...`), so
relative item paths resolve exactly like they did at import time:

    docker run --rm --user 0:0 \\
        -v /mnt/musicbucket/navidrome_library_flac:/mnt/musicbucket/navidrome_library_flac \\
        -v /opt/alpargatify/library-organizer/beets:/tools:ro \\
        --entrypoint python3 local/beets:latest \\
        /tools/rm_album.py --library /mnt/musicbucket/navidrome_library_flac \\
                           --path "Artist/Artist - [2026] Album" --check

Identity rules (spec: "Beets rows are removed by album identity"):

  * The album is selected by `--album-id` or by `--path "<Artist>/<Album>"`; a
    path is resolved against the items and the album art of every album, so a
    release whose items carry absolute `/import/...` paths is still found by
    the items that kept their proper path.
  * `--expect-album-id` is required for every destructive run and must equal
    the resolved id: the caller has to restate the identity it saw in
    `--check`, so a stale or wrong id cannot slip through.
  * Refuses (exit 4) when a path resolves to more than one album, when another
    album in the same database shares the resolved album's MusicBrainz album
    id (a split release), or when an expectation does not hold.
  * `--check` opens a temporary *copy* of the database, so the read-only mode
    cannot alter the library even by accident; it prints exactly what a real
    run would remove.

Output is one `key=value` line per fact (grep-able by the shell wrapper), or
exactly one JSON document with `--json`. The `db_sha256_before/after` pair
proves the check mode left the database byte-identical.

Exit status: 0 removed / check ok, 2 usage error, 3 album not found,
4 refused by a guard.
"""

import argparse
import hashlib
import json
import os
import shutil
import sys
import tempfile
import unicodedata

EXIT_OK = 0
EXIT_ERROR = 1
EXIT_USAGE = 2
EXIT_NOT_FOUND = 3
EXIT_REFUSED = 4

REPORT = {}
VERBOSE = False


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def detail(msg):
    if VERBOSE:
        print(msg, file=sys.stderr, flush=True)


def emit(key, value):
    """Record one fact for the machine-readable report."""
    REPORT[key] = value


def nfc(value):
    return unicodedata.normalize("NFC", value)


def decode_path(value):
    """beets stores paths as bytes; report them as text."""
    if isinstance(value, bytes):
        return os.fsdecode(value)
    return str(value or "")


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def under(path, prefix):
    """True when `path` is the release folder or lives inside it.

    Matches at a component boundary in both the relative form beets keeps
    (`Artist/Album/Disc 01/x.flac`) and inside an absolute path that still
    carries the release folder (`/import/Artist/Album/Disc 01/x.flac`).
    A path that lost the folder entirely (`/import/Disc 01/x.opus`) does not
    match, and shows up as an orphan row instead of being silently removed.
    """
    if not path:
        return False
    path = nfc(path).lstrip("/")
    prefix = nfc(prefix).strip("/")
    if not prefix:
        return False
    return path == prefix or path.startswith(prefix + "/") or ("/" + prefix + "/") in ("/" + path)


def album_paths(album):
    paths = []
    for item in album.items():
        paths.append((item, decode_path(item.path)))
    return paths


def album_matches(album, prefix):
    for _item, path in album_paths(album):
        if under(path, prefix):
            return True
    art = decode_path(album.artpath) if album.artpath else ""
    return under(art, prefix)


def album_summary(album):
    return {
        "album_id": album.id,
        "album_artist": album.albumartist or "",
        "album": album.album or "",
        "mb_albumid": album.mb_albumid or "",
        "items": len(list(album.items())),
    }


def open_library(db_path, directory):
    from beets.library import Library

    return Library(db_path, directory=directory)


def resolve(lib, args):
    """Return (album, None) or (None, exit_code) after reporting the reason."""

    album = None
    if args.album_id is not None:
        album = lib.get_album(args.album_id)
        if album is None:
            emit("reason", "unknown-album-id")
            log("rm_album: no album with id %s in this library" % args.album_id)
            return None, EXIT_NOT_FOUND
        emit("resolved_by", "album-id")
    else:
        prefix = args.path.strip("/")
        candidates = [a for a in lib.albums() if album_matches(a, prefix)]
        if not candidates:
            emit("reason", "unknown-path")
            log("rm_album: no album holds items under '%s' in this library" % prefix)
            return None, EXIT_NOT_FOUND
        if len(candidates) > 1:
            emit("reason", "ambiguous-path")
            log("rm_album: %d albums hold items under '%s' — refusing:" % (len(candidates), prefix))
            for cand in candidates:
                summary = album_summary(cand)
                log(
                    "  album id=%s %s - %s (%d items)"
                    % (summary["album_id"], summary["album_artist"], summary["album"], summary["items"])
                )
            emit("candidates", [album_summary(c) for c in candidates])
            return None, EXIT_REFUSED
        album = candidates[0]
        emit("resolved_by", "path")

    if args.path and args.album_id is not None and not album_matches(album, args.path):
        emit("reason", "album-does-not-hold-path")
        log(
            "rm_album: album %s holds no item under '%s' — refusing to remove the wrong album"
            % (album.id, args.path.strip("/"))
        )
        return None, EXIT_REFUSED

    summary = album_summary(album)
    emit("album_id", summary["album_id"])
    emit("album_artist", summary["album_artist"])
    emit("album", summary["album"])
    emit("mb_albumid", summary["mb_albumid"])
    emit("items", summary["items"])

    # A release split over two album rows of the same database cannot be
    # removed by one album id, and guessing would delete the wrong half.
    if summary["mb_albumid"]:
        same = [
            other
            for other in lib.albums()
            if other.id != album.id and (other.mb_albumid or "") == summary["mb_albumid"]
        ]
        if same:
            emit("reason", "split-release")
            log(
                "rm_album: album %s shares mb_albumid %s with %d other album(s) in this database — refusing:"
                % (album.id, summary["mb_albumid"], len(same))
            )
            for other in [album] + same:
                dup = album_summary(other)
                log(
                    "  album id=%s %s - %s (%d items)"
                    % (dup["album_id"], dup["album_artist"], dup["album"], dup["items"])
                )
            emit("candidates", [album_summary(a) for a in [album] + same])
            return None, EXIT_REFUSED

    if args.expect_album_id is not None and int(args.expect_album_id) != int(album.id):
        emit("reason", "unexpected-album-id")
        log(
            "rm_album: resolved album id %s but --expect-album-id says %s — refusing"
            % (album.id, args.expect_album_id)
        )
        return None, EXIT_REFUSED

    if args.expect_items is not None and int(args.expect_items) != summary["items"]:
        emit("reason", "unexpected-item-count")
        log(
            "rm_album: album %s holds %d items but --expect-items says %s — refusing"
            % (album.id, summary["items"], args.expect_items)
        )
        return None, EXIT_REFUSED

    return album, EXIT_OK


def describe_items(album, prefix):
    rows = []
    orphans = 0
    for item, path in sorted(album_paths(album), key=lambda pair: (pair[0].disc, pair[0].track, pair[1])):
        orphan = bool(path) and not under(path, prefix)
        if orphan:
            orphans += 1
        rows.append(
            {
                "item_id": item.id,
                "disc": item.disc,
                "track": item.track,
                "title": item.title or "",
                "path": path,
                "orphan": orphan,
            }
        )
    return rows, orphans


def main(argv=None):
    global VERBOSE

    parser = argparse.ArgumentParser(
        prog="rm_album.py",
        description="Remove one album and its items from a beets library, by album identity.",
        epilog="Exit status: 0 ok, 2 usage, 3 album not found, 4 refused by a guard.",
    )
    parser.add_argument(
        "--library",
        required=True,
        help="library directory holding library.db (the tree root, e.g. /mnt/musicbucket/navidrome_library_flac)",
    )
    parser.add_argument("--db", help="database file (default: <library>/library.db)")
    select = parser.add_mutually_exclusive_group(required=True)
    select.add_argument("--album-id", type=int, help="beets album id to remove")
    select.add_argument("--path", help='release folder inside the library, "Artist/Album"')
    parser.add_argument(
        "--expect-album-id",
        type=int,
        help="the album id the caller resolved earlier; required unless --check",
    )
    parser.add_argument("--expect-items", type=int, help="expected item count (optional extra guard)")
    parser.add_argument(
        "--check",
        action="store_true",
        help="read-only: report what would be removed, using a temporary copy of the database",
    )
    parser.add_argument("--json", action="store_true", help="print exactly one JSON document")
    parser.add_argument("--verbose", action="store_true", help="log progress to stderr")
    args = parser.parse_args(argv)
    VERBOSE = args.verbose

    library = os.path.abspath(args.library)
    db_path = os.path.abspath(args.db or os.path.join(library, "library.db"))

    def finish(code):
        REPORT["result"] = {
            EXIT_OK: "removed" if not args.check else "check-ok",
            EXIT_USAGE: "usage-error",
            EXIT_NOT_FOUND: "not-found",
            EXIT_REFUSED: "refused",
            EXIT_ERROR: "error",
        }[code]
        REPORT["exit_status"] = code
        REPORT["check"] = bool(args.check)
        if args.json:
            print(json.dumps(REPORT, indent=2, sort_keys=True))
        else:
            for key, value in REPORT.items():
                if isinstance(value, (dict, list)):
                    continue
                print("%s=%s" % (key, value))
        return code

    emit("library", library)
    emit("db", db_path)

    if not os.path.isdir(library):
        log("rm_album: library directory '%s' does not exist" % library)
        return finish(EXIT_ERROR)
    if not os.path.isfile(db_path):
        log("rm_album: no beets database at '%s'" % db_path)
        return finish(EXIT_NOT_FOUND)

    if not args.check and args.expect_album_id is None:
        log("rm_album: --expect-album-id is required for a destructive run")
        return finish(EXIT_USAGE)
    if not args.check and args.album_id is None:
        log("rm_album: a destructive run needs --album-id (resolve it with --check first)")
        return finish(EXIT_USAGE)

    prefix = (args.path or "").strip("/")
    if args.path is not None and not prefix:
        log("rm_album: --path needs 'Artist/Album'")
        return finish(EXIT_USAGE)

    # In check mode every read happens against a copy, so "changes nothing" is
    # structural rather than a promise. Hashing the real file before and after
    # proves the promise to the caller anyway.
    workdir = None
    work_db = db_path
    if args.check:
        workdir = tempfile.mkdtemp(prefix="rm_album_check_")
        work_db = os.path.join(workdir, "library.db")
        detail("copying %s -> %s" % (db_path, work_db))
        shutil.copy2(db_path, work_db)
        emit("db_sha256_before", sha256(db_path))
    else:
        emit("db_sha256_before", sha256(db_path))

    try:
        lib = open_library(work_db, library)
        album, code = resolve(lib, args)
        if album is None:
            return finish(code)

        rows, orphans = describe_items(album, prefix or _folder_of(album))
        emit("items", len(rows))
        emit("orphan_items", orphans)
        REPORT["item_detail"] = rows
        emit("item_ids", [row["item_id"] for row in rows])
        if not args.json:
            for row in rows:
                print(
                    "item=id:%s disc:%s track:%s path:%s%s"
                    % (row["item_id"], row["disc"], row["track"], row["path"], " ORPHAN" if row["orphan"] else "")
                )
        if orphans:
            log(
                "rm_album: WARNING album %s has %d item(s) whose path is outside '%s' "
                "(absolute or remapped rows); they are removed with the album"
                % (album.id, orphans, prefix or _folder_of(album))
            )

        if args.check:
            log(
                "rm_album: check only — would remove album %s (%s - %s) and %d item(s)"
                % (album.id, album.albumartist or "?", album.album or "?", len(rows))
            )
        else:
            album_id = album.id
            with lib.transaction():
                album.remove(delete=False)
            detail("committed removal of album %s" % album_id)
            emit("removed_album_id", album_id)
            emit("removed_items", len(rows))
            emit("removed_item_ids", [row["item_id"] for row in rows])

            post_album = lib.get_album(album_id)
            post_items = lib.items(f"album_id:{album_id}") if post_album else []
            post_items = list(post_items)
            emit("postcheck_album", "absent" if post_album is None else "present")
            emit("postcheck_items", len(post_items))
            if post_album is not None or post_items:
                log(
                    "rm_album: post-check FAILED for album %s: album=%s items=%d"
                    % (album_id, "present" if post_album else "absent", len(post_items))
                )
                return finish(EXIT_ERROR)
            log(
                "rm_album: removed album %s (%s - %s) and %d item(s)"
                % (album_id, album.albumartist or "?", album.album or "?", len(rows))
            )

        emit("db_sha256_after", sha256(db_path))
        emit("db_unchanged", "yes" if REPORT["db_sha256_after"] == REPORT["db_sha256_before"] else "no")
        return finish(EXIT_OK)
    finally:
        if workdir:
            shutil.rmtree(workdir, ignore_errors=True)


def _folder_of(album):
    """Best-effort release folder for an album, used when --path was not given."""
    art = decode_path(album.artpath) if album.artpath else ""
    if art:
        parts = nfc(art).split("/")
        if len(parts) >= 2:
            return "/".join(parts[:2])
    for _item, path in album_paths(album):
        if path and not os.path.isabs(path):
            parts = nfc(path).split("/")
            if len(parts) >= 2:
                return "/".join(parts[:2])
    return ""


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(EXIT_ERROR)
