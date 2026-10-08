#!/usr/bin/env python3
"""audit-library.py — read-only health check of the FLAC and Opus libraries.

Compares each beets DB with the files on disk, and the two libraries with each
other (they must mirror: same album folders and track names, .flac vs .opus).
Nothing is written to the libraries; DBs are opened read-only.

Paths are compared byte for byte, as Linux (the server, Navidrome, beets in
Docker) sees them. Run it on the server for authoritative results: over SMB
from macOS the listing is still exact, but other tools resolve names
case- and normalization-insensitively and can hide problems.

Usage:
  audit-library.py --lossless DIR --lossy DIR [--old DIR] [--list]
                   [--emit-missing-lossy FILE] [--samples N]

  --old DIR                 Also check that DIR (an old copy of the lossy
                            library) holds nothing the lossy library lacks.
  --list                    Print every entry of each finding, not samples.
  --emit-missing-lossy FILE Write the FLAC album folders with no Opus copy, one
                            per line, for `sync-lossless.sh --lossy-only FILE`.
                            Albums that need fixing first are written commented
                            out ("# reason: folder").

Exit status: 0 = no problems, 1 = problems found, 2 = usage/IO error.
"""

import argparse
import collections
import os
import re
import sqlite3
import sys
import time
import unicodedata
from concurrent.futures import ThreadPoolExecutor
from urllib.parse import quote

AUDIO = {'.flac', '.opus', '.mp3', '.m4a', '.ogg', '.oga', '.wav', '.aiff', '.aif',
         '.aac', '.wma', '.ape', '.wv', '.dsf'}
IMAGES = {'.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp'}
DISC_DIR = re.compile(r'^Disc \d+$')
# beets' interrupted-move temp files and rsync's partial transfers
TEMP_FILE = re.compile(r'(^\..+\.beets$)|(^\..+\.[A-Za-z0-9]{6}$)')
# Files beets/our pipeline keep at the library root on purpose
ROOT_KEEP = {'library.db', 'library.db.prev', '.ndignore'}
DRIFT_DAYS = 1


def nfc(s):
    return unicodedata.normalize('NFC', s)


def ext(path):
    return os.path.splitext(path)[1].lower()


def stem(path):
    return os.path.splitext(path)[0]


def album_dir(rel):
    """Album folder of a track: its parent, skipping a "Disc NN" level."""
    d = os.path.dirname(rel)
    if DISC_DIR.match(os.path.basename(d)):
        d = os.path.dirname(d)
    return d


def decode(value):
    if isinstance(value, (bytes, bytearray)):
        return value.decode('utf-8', 'surrogateescape')
    return value


def human(n):
    for unit in ('B', 'KB', 'MB', 'GB', 'TB'):
        if abs(n) < 1024:
            return f'{n:.1f} {unit}'
        n /= 1024
    return f'{n:.1f} PB'


# --------------------------------------------------------------------------
# Disk scan
# --------------------------------------------------------------------------

def _scan_subtree(root, top):
    files, dirs, errors = {}, {}, []
    stack = [top]
    while stack:
        d = stack.pop()
        try:
            with os.scandir(d) as it:
                entries = list(it)
        except OSError as e:
            errors.append(f'{d}: {e}')
            continue
        dirs[os.path.relpath(d, root)] = [e.name for e in entries]
        for e in entries:
            try:
                if e.is_dir(follow_symlinks=False):
                    stack.append(e.path)
                else:
                    st = e.stat(follow_symlinks=False)
                    files[os.path.relpath(e.path, root)] = (st.st_size, st.st_mtime)
            except OSError as ex:
                errors.append(f'{e.path}: {ex}')
    return files, dirs, errors


def scan(root, threads):
    """Returns ({relpath: (size, mtime)}, {reldir: [names]}, [errors])."""
    files, dirs, errors = {}, {}, []
    with os.scandir(root) as it:
        top = list(it)
    dirs['.'] = [e.name for e in top]
    subdirs = []
    for e in top:
        if e.is_dir(follow_symlinks=False):
            subdirs.append(e.path)
        else:
            st = e.stat(follow_symlinks=False)
            files[e.name] = (st.st_size, st.st_mtime)
    with ThreadPoolExecutor(threads) as pool:
        for f, d, err in pool.map(lambda p: _scan_subtree(root, p), subdirs):
            files.update(f)
            dirs.update(d)
            errors.extend(err)
    return files, dirs, errors


# --------------------------------------------------------------------------
# beets DB
# --------------------------------------------------------------------------

def open_db(path):
    """Read-only connection. Loads the file into memory when possible: one
    sequential read is much faster than SQLite's random reads over SMB."""
    if hasattr(sqlite3.Connection, 'deserialize'):
        with open(path, 'rb') as fh:
            data = fh.read()
        con = sqlite3.connect(':memory:')
        con.deserialize(data)
    else:
        con = sqlite3.connect(f'file:{quote(path)}?mode=ro&immutable=1', uri=True)
    con.row_factory = sqlite3.Row
    return con


def load_db(path):
    con = open_db(path)
    items = [dict(r) for r in con.execute(
        'SELECT id, path, album_id, format, title, artist, album, albumartist, track, disc,'
        ' year, length, mtime, mb_trackid, mb_albumid, genres FROM items')]
    albums = [dict(r) for r in con.execute(
        'SELECT id, album, albumartist, year, mb_albumid, artpath, added FROM albums')]
    con.close()
    for it in items:
        it['path'] = decode(it['path'])
    for al in albums:
        al['artpath'] = decode(al['artpath'])
    return items, albums


def album_key(al):
    if al['mb_albumid']:
        return al['mb_albumid']
    return 'noid:' + '|'.join(nfc(str(al[k] or '')).lower() for k in ('albumartist', 'album', 'year'))


def album_label(al):
    return f"{al['albumartist']} - {al['album']} ({al['year']})"


# --------------------------------------------------------------------------
# Report
# --------------------------------------------------------------------------

class Report:
    def __init__(self, samples, full):
        self.samples = samples
        self.full = full
        self.problems = 0

    def section(self, title):
        print(f'\n== {title}')

    def line(self, text):
        print(f'  {text}')

    def finding(self, title, entries, problem=True):
        entries = sorted(entries, key=str)
        mark = '!!' if problem and entries else 'ok' if problem else '--'
        print(f'  [{mark}] {title}: {len(entries)}')
        if problem and entries:
            self.problems += 1
        limit = len(entries) if self.full else self.samples
        for e in entries[:limit]:
            print(f'        {e}')
        if len(entries) > limit:
            print(f'        ... {len(entries) - limit} more (--list shows all)')


class Library:
    def __init__(self, name, root, threads):
        self.name, self.root = name, root
        self.files, self.dirs, self.errors = scan(root, threads)
        self.items, self.albums = load_db(os.path.join(root, 'library.db'))
        self.audio = {f: v for f, v in self.files.items() if ext(f) in AUDIO}
        self.by_album = collections.defaultdict(list)
        for it in self.items:
            self.by_album[it['album_id']].append(it)
        # exact disk name -> DB item, and the inverse lookups used below
        self.disk_nfc = {}
        self.disk_fold = {}
        for f in self.audio:
            self.disk_nfc.setdefault(nfc(f), f)
            self.disk_fold.setdefault(nfc(f).casefold(), f)


def check_library(lib, rep):
    rep.section(f'{lib.name}: {lib.root}')
    total = sum(s for s, _ in lib.files.values())
    rep.line(f'disk: {len(lib.audio)} audio files ({human(sum(s for s, _ in lib.audio.values()))}), '
             f'{len(lib.files)} files total ({human(total)}), {len({album_dir(f) for f in lib.audio})} album folders')
    rep.line(f'DB:   {len(lib.items)} items, {len(lib.albums)} albums; formats '
             + ', '.join(f'{k}={v}' for k, v in collections.Counter(i['format'] for i in lib.items).most_common()))
    rep.finding('scan errors', lib.errors)

    # --- DB items vs files, byte for byte
    exact, norm, case, missing, outside = [], [], [], [], []
    tracked = set()
    for it in lib.items:
        p = it['path']
        if p.startswith('/'):
            outside.append(p)
        elif p in lib.audio:
            exact.append(p)
            tracked.add(p)
        elif nfc(p) in lib.disk_nfc:
            norm.append(f'{lib.disk_nfc[nfc(p)]!a}  (DB: {p!a})')
            tracked.add(lib.disk_nfc[nfc(p)])
        elif nfc(p).casefold() in lib.disk_fold:
            case.append(f'{lib.disk_fold[nfc(p).casefold()]}  (DB: {p})')
            tracked.add(lib.disk_fold[nfc(p).casefold()])
        else:
            missing.append(p)
    rep.line(f'DB paths matching the disk byte for byte: {len(exact)}/{len(lib.items)}')
    rep.finding('DB path differs from the file only in Unicode normalization (NFC/NFD)', norm)
    rep.finding('DB path differs from the file only in letter case', case)
    rep.finding('DB items with no file', missing)
    rep.finding('DB items with an absolute path outside the library (broken import)', outside)
    rep.finding('audio files not in the DB', [f for f in lib.audio if f not in tracked])

    # --- albums
    rep.finding('album rows without items', [f'{album_label(a)} [id {a["id"]}]'
                                            for a in lib.albums if a['id'] not in lib.by_album])
    keys = collections.Counter(a['mb_albumid'] for a in lib.albums if a['mb_albumid'])
    rep.finding('releases imported more than once (same mb_albumid)',
                [f'{album_label(a)} [{a["mb_albumid"]}]' for a in lib.albums
                 if a['mb_albumid'] and keys[a['mb_albumid']] > 1])
    # Art paths that only differ in normalization/case are already covered above.
    files_fold = {nfc(f).casefold() for f in lib.files}
    rep.finding('album art path set but file missing',
                [a['artpath'] for a in lib.albums
                 if a['artpath'] and nfc(a['artpath']).casefold() not in files_fold])

    # --- informational
    drift = collections.Counter()
    for it in lib.items:
        f = it['path']
        if f in lib.audio and it['mtime'] and lib.audio[f][1] - it['mtime'] > DRIFT_DAYS * 86400:
            drift[album_dir(f)] += 1
    rep.finding(f'albums with files modified >{DRIFT_DAYS} day after beets last wrote them '
                '(edited outside beets? run `beet update -p`)',
                [f'{d} [{n}]' for d, n in drift.items()], problem=False)
    with_audio = set()
    for f in lib.audio:
        d = os.path.dirname(f)
        while d not in with_audio:
            with_audio.add(d)
            if not d:
                break
            d = os.path.dirname(d)
    rep.finding('folders without audio (leftovers)',
                [d for d in lib.dirs if d != '.' and d not in with_audio and not d.startswith('.')],
                problem=False)
    rep.finding('temporary / partial files',
                [f for f in lib.files if TEMP_FILE.match(os.path.basename(f))], problem=False)
    rep.finding('other non-music files',
                [f for f in lib.files if ext(f) not in AUDIO and ext(f) not in IMAGES
                 and f not in ROOT_KEEP and not TEMP_FILE.match(os.path.basename(f))
                 and os.path.basename(f) != '.DS_Store'], problem=False)


def check_mirror(a, b, rep, emit_path=None):
    """a = lossless, b = lossy. Compared on NFC names: normalization problems
    are reported per library above, and would only add noise here."""
    rep.section(f'mirror: {a.name} vs {b.name}')
    stems_a = collections.defaultdict(set)
    stems_b = collections.defaultdict(set)
    exact_dir_a = {}
    for f in a.audio:
        d = nfc(album_dir(f))
        stems_a[d].add(nfc(stem(f)))
        exact_dir_a.setdefault(d, album_dir(f))
    for f in b.audio:
        stems_b[nfc(album_dir(f))].add(nfc(stem(f)))
    common = sum(len(stems_a[d] & stems_b.get(d, set())) for d in stems_a)
    rep.line(f'tracks in both: {common} ({a.name} {len(a.audio)}, {b.name} {len(b.audio)})')
    only_a = [d for d in stems_a if d not in stems_b]
    only_b = [d for d in stems_b if d not in stems_a]
    partial = [f'{d}: {a.name}={len(stems_a[d])} {b.name}={len(stems_b[d])}'
               for d in stems_a if d in stems_b and stems_a[d] != stems_b[d]]
    rep.finding(f'album folders only in {a.name}', [f'{d} [{len(stems_a[d])}]' for d in only_a])
    rep.finding(f'album folders only in {b.name}', [f'{d} [{len(stems_b[d])}]' for d in only_b])
    rep.finding('album folders whose tracks differ', partial)

    keys_a = collections.defaultdict(list)
    keys_b = collections.defaultdict(list)
    for al in a.albums:
        keys_a[album_key(al)].append(al)
    for al in b.albums:
        keys_b[album_key(al)].append(al)
    rep.finding(f'DB albums only in {a.name}', [album_label(v[0]) for k, v in keys_a.items() if k not in keys_b])
    rep.finding(f'DB albums only in {b.name}', [album_label(v[0]) for k, v in keys_b.items() if k not in keys_a])

    fields = ('title', 'artist', 'album', 'albumartist', 'year', 'track', 'disc',
              'mb_trackid', 'mb_albumid', 'genres')
    by_stem_b = {nfc(stem(it['path'])): it for it in b.items}
    diffs = collections.defaultdict(list)
    for it in a.items:
        other = by_stem_b.get(nfc(stem(it['path'])))
        if not other:
            continue
        for f in fields:
            if (it[f] or '') != (other[f] or ''):
                diffs[f].append(f'{stem(it["path"])}: {it[f]!r} vs {other[f]!r}')
    rep.finding('tracks whose tags differ between libraries',
                [f'{f}: {len(v)} track(s), e.g. {v[0]}' for f, v in sorted(diffs.items())])

    if emit_path:
        emit_missing_lossy(a, b, [exact_dir_a[d] for d in only_a], keys_b, emit_path)


def emit_missing_lossy(a, b, only_a, keys_b, path):
    """Album folders (exact on-disk names) for `sync-lossless.sh --lossy-only`;
    ones that would fail or duplicate are written commented out, with why."""
    tracked = {}
    for it in a.items:
        tracked[nfc(it['path']).casefold()] = it
    albums = {al['id']: al for al in a.albums}
    tracks_by_dir = collections.defaultdict(list)
    for f in a.audio:
        tracks_by_dir[album_dir(f)].append(f)
    lines = []
    for d in sorted(only_a):
        items = [tracked.get(nfc(f).casefold()) for f in tracks_by_dir[d]]
        if not items or None in items:
            lines.append(f'# not (fully) in the {a.name} DB, fix first: {d}')
            continue
        known = [it['album_id'] for it in items
                 if it['album_id'] in albums and album_key(albums[it['album_id']]) in keys_b]
        if known:
            lines.append(f'# already in the {b.name} DB under another folder: {d}')
        else:
            lines.append(d)
    with open(path, 'w', encoding='utf-8', errors='surrogateescape') as fh:
        fh.write('\n'.join(lines) + ('\n' if lines else ''))
    usable = sum(1 for line in lines if not line.startswith('#'))
    print(f'\n  wrote {path}: {usable} album(s) to convert, {len(lines) - usable} commented out')


def check_old(old, lossy, rep):
    rep.section(f'old copy: {old.root} vs {lossy.name}')
    have = {stem(f) for f in lossy.audio}
    have_nfc = {nfc(s) for s in have}
    unique = [f for f in old.audio if stem(f) not in have and nfc(stem(f)) not in have_nfc]
    rep.line(f'{len(old.audio)} audio files ({human(sum(s for s, _ in old.audio.values()))})')
    rep.finding(f'tracks in the old copy missing from {lossy.name}', unique)
    rep.line('SAFE TO DELETE: nothing unique' if not unique else 'NOT SAFE TO DELETE: it holds unique tracks')


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('--lossless', required=True, help='FLAC library root (with library.db)')
    ap.add_argument('--lossy', required=True, help='Opus library root (with library.db)')
    ap.add_argument('--old', help='old lossy copy to compare against --lossy')
    ap.add_argument('--list', action='store_true', help='print every entry, not samples')
    ap.add_argument('--samples', type=int, default=10, help='entries shown per finding (default 10)')
    ap.add_argument('--emit-missing-lossy', metavar='FILE', help='write FLAC albums with no Opus copy')
    ap.add_argument('--threads', type=int, default=16, help='parallel directory scans (default 16)')
    args = ap.parse_args()

    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(errors='backslashreplace')
    for d in filter(None, (args.lossless, args.lossy, args.old)):
        if not os.path.isfile(os.path.join(d, 'library.db')):
            print(f'error: no library.db in {d}', file=sys.stderr)
            return 2

    start = time.time()
    rep = Report(args.samples, args.list)
    print(f'Library audit, {time.strftime("%Y-%m-%d %H:%M")} (read-only)')
    flac = Library('FLAC', args.lossless, args.threads)
    opus = Library('Opus', args.lossy, args.threads)
    check_library(flac, rep)
    check_library(opus, rep)
    check_mirror(flac, opus, rep, args.emit_missing_lossy)
    if args.old:
        old = Library('old', args.old, args.threads)
        check_old(old, opus, rep)
    print(f'\n{rep.problems} finding(s) flagged [!!], {time.time() - start:.0f}s')
    return 1 if rep.problems else 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except OSError as e:
        print(f'error: {e}', file=sys.stderr)
        sys.exit(2)
