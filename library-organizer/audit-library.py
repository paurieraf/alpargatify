#!/usr/bin/env python3
"""audit-library.py — read-only health check of the FLAC and Opus libraries.

Compares each beets DB with the files on disk, and the two libraries with each
other (they must mirror: same album folders and track names, .flac vs .opus).
Nothing is written to the libraries; DBs are opened read-only.

Paths are compared byte for byte, as Linux (the server, Navidrome, beets in
Docker) sees them. Run it on the server (server/audit.sh) for authoritative
results: over SMB, macOS presents many names decomposed (NFD) that are NFC on
the server, so the normalization finding is meaningless there. The mirror and
--old comparisons normalize names and are not affected.

Usage:
  audit-library.py --lossless DIR --lossy DIR [--old DIR] [--list]
                   [--emit-missing-lossy FILE] [--samples N]

  audit-library.py --lossless DIR --lossy DIR --release "Artist/Album"
                   [--navidrome-db FILE --library-map ROOT=DIR] [--json]

  audit-library.py --missing [--navidrome-db FILE --library-map ROOT=DIR]
                   [--missing-json FILE] [--json]
                   [--mass-missing-threshold N]

  --old DIR                 Also check that DIR (an old copy of the lossy
                            library) holds nothing the lossy library lacks.
  --list                    Print every entry of each finding, not samples.
  --emit-missing-lossy FILE Write the FLAC album folders with no Opus copy, one
                            per line, for `sync-lossless.sh --lossy-only FILE`.
                            Albums that need fixing first are written commented
                            out ("# reason: folder").

Release doctor ("five views"):
  --release "Artist/Album"  Reconcile one release across the lossless tree, the
                            lossless beets DB, the lossy tree, the lossy beets
                            DB and Navidrome. A release is the album folder on
                            disk; every "Disc NN" subfolder belongs to it.
  --navidrome-db FILE       A Navidrome database snapshot, opened read-only.
                            The live database is never opened (WAL, and it would
                            need write access): take a snapshot first, see
                            docs/audit.md.
  --library-map ROOT=DIR    Translate the library root recorded in the snapshot
                            (library.path) into a real directory. Repeatable;
                            every root in the snapshot must be mapped.
  --missing                 Report Navidrome's missing inventory: count, every
                            path, and a MASS_MISSING finding above the
                            threshold. Reads the snapshot, or --missing-json.
  --missing-json FILE       `navidrome missing list -f json` output, read from
                            FILE ("-" for stdin) instead of the snapshot. The
                            CLI banner printed before the JSON is ignored.
  --mass-missing-threshold N
                            Missing files tolerated before MASS_MISSING is
                            raised (default 20, i.e. "more than 20").
  --json                    Print one JSON document instead of the text report.
                            Needs --release or --missing.

Findings: TRACK_SHORT, ORPHAN_PATH, DB_NO_FILE, FILE_NO_DB, NAV_ABSENT,
NAV_GHOST, NAV_SPLIT, NAV_MISSING_ROW, UNREADABLE, MASS_MISSING.

Exit status: 0 = no problems, 1 = problems found, 2 = usage/IO error,
3 = unknown release (--release only).
"""

import argparse
import collections
import json
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


# ---------------------------------------------------------------------------
# Doctor: the five views of one release (design D1-D4)
#
# One release, looked at through the lossless tree, the lossless beets DB, the
# lossy tree, the lossy beets DB and the Navidrome library. A release is the
# album folder on disk and every "Disc NN" subfolder belongs to it (design D2);
# tracks are keyed on (disc, track) with the title as a tie-breaker. Every
# disagreement becomes a finding with a stable code (design D3). No store is
# ever written.
# ---------------------------------------------------------------------------

VIEWS = ('flac_disk', 'flac_db', 'opus_disk', 'opus_db', 'navidrome')

# design D3. Warnings are reported but do not by themselves change the status.
SEVERITY = {
    'TRACK_SHORT': 'error',
    'ORPHAN_PATH': 'error',
    'DB_NO_FILE': 'error',
    'FILE_NO_DB': 'error',
    'NAV_ABSENT': 'error',
    'NAV_GHOST': 'error',
    'NAV_SPLIT': 'error',
    'NAV_MISSING_ROW': 'warning',
    'UNREADABLE': 'error',
    'MASS_MISSING': 'error',
}
CODE_ORDER = dict((code, i) for i, code in enumerate(SEVERITY))

CLEAN, FINDINGS, USAGE, UNKNOWN = 0, 1, 2, 3
MASS_MISSING_DEFAULT = 20

# beets names tracks "$disc_and_track. $artist - $title", so a file name starts
# with "DD.TT."; "01 - Title" is accepted too. The number is album-wide.
NAME_TRACK = re.compile(r'^(\d{1,2})\.(\d{1,3})\.\s*(.*)$')
NAME_TRACK_ALT = re.compile(r'^(\d{1,3})\s*[-.]\s+(.*)$')
DISC_NAME = re.compile(r'^(?:disc|disk|cd)\s*[-_]?\s*(\d+)$', re.I)
YEAR_PREFIX = re.compile(r'^\[\d{4}\]\s*')


class UsageError(Exception):
    """Bad command line, unreadable input, or a store that is not what it claims."""


class UnknownRelease(Exception):
    """The requested Artist/Album is in none of the views."""


def track_label(disc, track):
    if track is None:
        return '--'
    if not disc:
        return '%02d' % track
    return '%02d.%02d' % (disc, track)


class Finding(object):
    """One disagreement between views (design D3): a code and its severity."""

    __slots__ = ('code', 'detail', 'view', 'disc', 'track', 'title', 'album_id', 'path')

    def __init__(self, code, detail='', view=None, disc=None, track=None,
                 title=None, album_id=None, path=None):
        if code not in SEVERITY:
            raise AssertionError('unknown finding code %r' % code)
        self.code = code
        self.detail = detail
        self.view = view
        self.disc = disc
        self.track = track
        self.title = title
        self.album_id = album_id
        self.path = path

    @property
    def severity(self):
        return SEVERITY[self.code]

    def sort_key(self):
        return (CODE_ORDER[self.code], self.disc or 0,
                -1 if self.track is None else self.track,
                self.path or '', self.detail)

    def as_dict(self):
        out = {'code': self.code, 'severity': self.severity}
        for name in ('view', 'disc', 'track', 'title', 'album_id', 'path', 'detail'):
            value = getattr(self, name)
            if value is not None and value != '':
                out[name] = value
        return out

    def text(self):
        parts = ['[%s]' % ('ERROR' if self.severity == 'error' else 'WARN'), self.code]
        if self.view:
            parts.append(self.view)
        if self.disc is not None or self.track is not None:
            parts.append(track_label(self.disc, self.track))
        if self.album_id is not None:
            parts.append('album %s' % self.album_id)
        if self.title:
            parts.append(self.title)
        if self.detail:
            parts.append(self.detail)
        if self.path:
            parts.append('at %s' % self.path)
        return '  '.join(parts)


# ---------------------------------------------------------------------------
# The release on disk
# ---------------------------------------------------------------------------

def disc_of_name(name):
    found = DISC_NAME.match(nfc(name).strip())
    return int(found.group(1)) if found else None


def release_parts(root, spec):
    """(release folder, folder to scan) relative to root, or (None, None).

    The release is the album folder: a spec that names a "Disc NN" folder points
    at its parent, so every disc of the release is in scope.
    """
    parts = [part for part in nfc(spec).replace('\\', '/').split('/') if part]
    if not parts:
        return None, None
    if not os.path.isdir(os.path.join(root, *parts)):
        return None, None
    if DISC_NAME.match(nfc(parts[-1]).strip()) and len(parts) > 1:
        return '/'.join(parts[:-1]), '/'.join(parts)
    return '/'.join(parts), '/'.join(parts)


def name_track(name):
    """(track number, title) from a track file name, (None, name) without one."""
    found = NAME_TRACK.match(name)
    if found:
        return int(found.group(2)), (found.group(3) or '').strip()
    found = NAME_TRACK_ALT.match(name)
    if found:
        return int(found.group(1)), (found.group(2) or '').strip()
    return None, name.strip()


def scan_release(root, spec):
    """Audio of one release on disk: (release folder, [{disc, track, title, path}]).

    The release folder is relative to root and every "Disc NN" below it is part
    of the same release; the disc number of a file comes from that folder.
    """
    rel, scan_rel = release_parts(root, spec)
    if rel is None:
        return None, []
    entries = []
    for here, dirs, names in os.walk(os.path.join(root, scan_rel)):
        dirs[:] = sorted(d for d in dirs if not d.startswith('.'))
        for name in sorted(names):
            if ext(name) not in AUDIO or TEMP_FILE.match(name):
                continue
            rel_file = os.path.relpath(os.path.join(here, name), root)
            below = rel_file[len(rel) + 1:] if rel_file.startswith(rel + os.sep) else rel_file
            disc = None
            for part in below.split(os.sep)[:-1]:
                if DISC_NAME.match(nfc(part).strip()):
                    disc = disc_of_name(part)
                    break
            number, title = name_track(os.path.splitext(name)[0])
            entries.append({'disc': disc, 'track': number, 'title': title, 'path': rel_file})
    return rel, entries


# ---------------------------------------------------------------------------
# Navidrome snapshot (design D4)
# ---------------------------------------------------------------------------

class Navidrome(object):
    """Read-only view of a Navidrome snapshot.

    The snapshot is a copy: the live database belongs to another container and
    runs in WAL mode, so it is never opened. media_file.path is absolute in the
    Navidrome schema but relative to library.path in practice; both forms are
    resolved through the --library-map translation. Albums are matched through
    folder.path (folder_ids is a JSON array of folder ids), so nothing has to
    read artwork or blobs.
    """

    REQUIRED = (
        ('media_file', ('id', 'path', 'album_id', 'disc_number', 'track_number',
                        'title', 'missing', 'library_id')),
        ('album', ('id', 'name', 'album_artist', 'mbz_album_id', 'missing', 'folder_ids')),
        ('library', ('id', 'path')),
    )
    FILE_COLS = 'id, path, album_id, disc_number, track_number, title, missing, library_id'
    ALBUM_COLS = 'id, name, album_artist, mbz_album_id, missing, folder_ids'

    def __init__(self, path, maps):
        self.path = path
        if not os.path.isfile(path):
            raise UsageError('--navidrome-db %s: no such file' % path)
        self.maps = dict(maps)
        con = None
        try:
            uri = 'file:%s?mode=ro&immutable=1' % quote(os.path.abspath(path))
            con = sqlite3.connect(uri, uri=True, timeout=60)
            con.row_factory = sqlite3.Row
            self.con = con
            self._check_schema()
            self.libraries = [dict(row) for row in con.execute('SELECT id, name, path FROM library')]
        except sqlite3.Error as exc:
            if con is not None:
                con.close()
            raise UsageError('--navidrome-db %s: not a readable Navidrome database (%s)' % (path, exc))
        except UsageError:
            if con is not None:
                con.close()
            raise
        self.snapshot_time = time.strftime('%Y-%m-%d %H:%M',
                                           time.localtime(os.path.getmtime(path)))
        self._check_maps()

    def _check_schema(self):
        tables = set(row[0] for row in self.con.execute(
            "SELECT name FROM sqlite_master WHERE type = 'table'"))
        for table, columns in self.REQUIRED:
            if table not in tables:
                raise UsageError('--navidrome-db %s: no Navidrome schema (table %s is missing)'
                                 % (self.path, table))
            have = set(row[1] for row in self.con.execute('PRAGMA table_info(%s)' % table))
            absent = [name for name in columns if name not in have]
            if absent:
                raise UsageError('--navidrome-db %s: no Navidrome schema (table %s has no %s)'
                                 % (self.path, table, ', '.join(absent)))

    def _check_maps(self):
        roots = {}
        for lib in self.libraries:
            roots[(lib['path'] or '').rstrip('/')] = lib
        if not roots:
            raise UsageError('--navidrome-db %s: the snapshot holds no library' % self.path)
        unmapped = sorted(root for root in roots if root not in self.maps)
        if unmapped:
            raise UsageError('--navidrome-db %s: no --library-map for the library root %s'
                             % (self.path, ', '.join(unmapped)))
        unknown = sorted(root for root in self.maps if root not in roots)
        if unknown:
            raise UsageError('--library-map: %s is not the root of any library in %s'
                             % (', '.join(unknown), self.path))
        for root in sorted(self.maps):
            if not os.path.isdir(self.maps[root]):
                raise UsageError('--library-map %s=%s: not a directory' % (root, self.maps[root]))
        self.roots = roots
        self.dir_of = dict((lib['id'], self.maps[(lib['path'] or '').rstrip('/')])
                           for lib in self.libraries)

    def close(self):
        try:
            self.con.close()
        except sqlite3.Error:
            pass

    def local_path(self, row):
        """Real path of one media_file row, or None when it cannot be mapped."""
        rel = row['path'] or ''
        root = self.dir_of.get(row['library_id'])
        if root is None:
            if len(self.libraries) != 1:
                return None
            root = self.dir_of[self.libraries[0]['id']]
        if not os.path.isabs(rel):
            return os.path.join(root, rel)
        for library_root in self.maps:
            prefix = library_root.rstrip('/') + '/'
            if rel.startswith(prefix):
                return os.path.join(root, rel[len(prefix):])
            if rel == library_root.rstrip('/'):
                return root
        return None

    @staticmethod
    def _under(path, rel):
        path = nfc(path or '').replace(os.sep, '/').strip('/')
        if not rel or not path:
            return False
        return path == rel or path.startswith(rel + '/') or path.endswith('/' + rel) \
            or ('/' + rel + '/') in ('/' + path)

    def _folders(self, rels):
        """Folder ids of the release: every folder at or under any of rels."""
        wanted = [nfc(rel or '').replace(os.sep, '/').strip('/') for rel in rels]
        wanted = [rel for rel in wanted if rel]
        found = set()
        for row in self.con.execute('SELECT id, path FROM folder'):
            for rel in wanted:
                if self._under(row['path'], rel):
                    found.add(row['id'])
                    break
        return found

    def albums(self, rels, mbids):
        """Album rows that are the release: same folder, or same MusicBrainz id."""
        folder_ids = self._folders(rels)
        found = []
        for row in self.con.execute('SELECT %s FROM album' % self.ALBUM_COLS):
            album = dict(row)
            try:
                album['_folders'] = set(str(x) for x in json.loads(album['folder_ids'] or '[]'))
            except (TypeError, ValueError):
                album['_folders'] = set()
            if (album['_folders'] & folder_ids) \
                    or (album['mbz_album_id'] and album['mbz_album_id'] in mbids):
                found.append(album)
        return found

    def files(self, album_ids):
        album_ids = [x for x in album_ids if x]
        if not album_ids:
            return []
        marks = ', '.join('?' * len(album_ids))
        return [dict(row) for row in self.con.execute(
            'SELECT %s FROM media_file WHERE album_id IN (%s)' % (self.FILE_COLS, marks),
            album_ids)]

    def missing_rows(self):
        return [dict(row) for row in self.con.execute(
            'SELECT %s FROM media_file WHERE missing = 1 ORDER BY path' % self.FILE_COLS)]

    def missing_count(self):
        row = self.con.execute(
            'SELECT count(*), count(DISTINCT album_id) FROM media_file WHERE missing = 1').fetchone()
        return int(row[0] or 0), int(row[1] or 0)


# ---------------------------------------------------------------------------
# The doctor
# ---------------------------------------------------------------------------

class ReleaseDoctor(object):
    """One release reconciled across the five views (design D1-D3)."""

    def __init__(self, spec, lossless=None, lossy=None, navidrome=None,
                 threshold=MASS_MISSING_DEFAULT):
        self.spec = spec
        self.roots = {'flac': lossless, 'opus': lossy}
        self.nav = navidrome
        self.threshold = threshold
        self.mbids = set()
        self.frames = []
        self.findings = []
        self.tracks = {}
        self.disk = {'flac': {}, 'opus': {}}
        self.disk_extra = {'flac': [], 'opus': []}
        self.disk_rel = {'flac': None, 'opus': None}
        self.db_keys = {'flac': {}, 'opus': {}}
        self.db_inplace = {'flac': set(), 'opus': set()}
        self.db_orphan = {'flac': set(), 'opus': set()}
        self.db_albums = {'flac': [], 'opus': []}
        self.db_mbids = {'flac': set(), 'opus': set()}
        self.db_available = {'flac': False, 'opus': False}
        self.orphans = {'flac': [], 'opus': []}
        self.nav_keys = {}
        self.nav_albums = []
        self.nav_missing = 0

    # -- helpers -----------------------------------------------------------

    def rels(self):
        return [rel for rel in (self.disk_rel['flac'], self.disk_rel['opus']) if rel]

    def available(self):
        """Views that can actually be read; an absent store is not "short"."""
        return {
            'flac_disk': bool(self.roots['flac']),
            'flac_db': self.db_available['flac'],
            'opus_disk': bool(self.roots['opus']),
            'opus_db': self.db_available['opus'],
            'navidrome': self.nav is not None,
        }

    def same_release(self, album):
        rels = self.rels()
        if not rels:
            return False
        parts = rels[0].split('/')
        artist = nfc(parts[-2] if len(parts) > 1 else '').casefold()
        name = YEAR_PREFIX.sub('', nfc(parts[-1])).casefold()
        if not name or nfc(album['name'] or '').casefold() != name:
            return False
        return not artist or nfc(album['album_artist'] or '').casefold() == artist

    # -- steps -------------------------------------------------------------

    def resolve(self):
        """Find the release on disk. Raises UnknownRelease when nothing is there."""
        for view in ('flac', 'opus'):
            root = self.roots[view]
            if not root:
                continue
            if not os.path.isdir(root):
                self.frames.append({'view': view + '_disk', 'area': 'root', 'path': root,
                                    'error': 'no such directory'})
                continue
            rel, entries = scan_release(root, self.spec)
            if rel is None:
                continue
            self.disk_rel[view] = rel
            for entry in entries:
                if entry['track'] is None:
                    self.disk_extra[view].append(entry)
                    continue
                key = (entry['disc'] or 1, entry['track'])
                if key in self.disk[view]:
                    self.disk_extra[view].append(entry)
                    continue
                self.disk[view][key] = entry
        if not self.rels():
            raise UnknownRelease(self.spec)

    def read_db(self, view, root):
        """beets items of this release: by folder first, then by mb_albumid."""
        if not root:
            return
        path = os.path.join(root, 'library.db')
        if not os.path.isfile(path):
            self.frames.append({'view': view + '_db', 'area': 'database', 'path': path,
                                'error': 'no library.db to compare with'})
            return
        try:
            items, albums = load_db(path)
        except (sqlite3.Error, OSError) as exc:
            self.frames.append({'view': view + '_db', 'area': 'database', 'path': path,
                                'error': str(exc)})
            return
        self.db_available[view] = True
        rows = collections.defaultdict(list)
        for item in items:
            rows[item['album_id']].append(item)
        rels = self.rels()

        def owned(item):
            item_path = item['path']
            if item_path.startswith('/'):
                return any('/' + rel + '/' in item_path for rel in rels)
            return album_dir(item_path) in rels

        chosen, seen = [], set()

        def add(album):
            if album['id'] not in seen:
                seen.add(album['id'])
                chosen.append(album)

        for album in albums:
            if any(owned(item) for item in rows.get(album['id'], ())):
                add(album)
        if not chosen and self.mbids:
            # Imported under another folder layout: the MusicBrainz album id is
            # all that links it to the release (design D2).
            for album in albums:
                if album['mb_albumid'] and album['mb_albumid'] in self.mbids:
                    add(album)
        if not chosen:
            for album in albums:
                if rows.get(album['id']) and self.same_release(album):
                    add(album)
        for album in chosen:
            if album['mb_albumid']:
                self.mbids.add(album['mb_albumid'])
                self.db_mbids[view].add(album['mb_albumid'])
            self.db_albums[view].append(album['id'])
            for item in rows.get(album['id'], ()):
                if item['track'] is None:
                    self.frames.append({'view': view + '_db', 'area': 'track',
                                        'path': item['path'],
                                        'error': 'item has no track number'})
                    continue
                key = (item['disc'] or 1, item['track'])
                self.db_keys[view].setdefault(key, item['title'] or '')
                if item['path'].startswith('/'):
                    self.db_orphan[view].add(key)
                    self.orphans[view].append({
                        'album_id': album['id'], 'path': item['path'],
                        'title': item['title'], 'disc': key[0], 'track': key[1]})
                else:
                    self.db_inplace[view].add(key)

    def read_navidrome(self):
        if self.nav is None:
            return
        albums = self.nav.albums(self.rels(), self.mbids)
        self.nav_albums = [album['id'] for album in albums]
        for album in albums:
            if album['mbz_album_id']:
                self.mbids.add(album['mbz_album_id'])
        for row in self.nav.files(self.nav_albums):
            if row['track_number'] is None:
                self.frames.append({'view': 'navidrome', 'area': 'track', 'path': row['path'],
                                    'error': 'row has no track number'})
                continue
            key = (row['disc_number'] or 1, row['track_number'])
            self.nav_keys.setdefault(key, row['title'] or '')
            if row['missing']:
                self.nav_missing += 1

    def check_libraries(self):
        """ORPHAN_PATH, DB_NO_FILE, FILE_NO_DB and files that cannot be placed."""
        for view in ('flac', 'opus'):
            for row in self.orphans[view]:
                self.findings.append(Finding(
                    'ORPHAN_PATH', 'row path outside the library', view=view + '_db',
                    disc=row['disc'], track=row['track'], title=row['title'],
                    album_id=row['album_id'], path=row['path']))
            for entry in self.disk_extra[view]:
                self.findings.append(Finding(
                    'UNREADABLE', 'file name carries no usable track number, or repeats one',
                    view=view + '_disk', disc=entry['disc'], title=entry['title'],
                    path=entry['path']))
            for key in sorted(self.db_inplace[view] - set(self.disk[view])):
                if key in self.db_orphan[view]:
                    continue  # the ORPHAN_PATH row already explains this track
                self.findings.append(Finding(
                    'DB_NO_FILE', 'beets has the track, the tree does not',
                    view=view + '_db', disc=key[0], track=key[1],
                    title=self.db_keys[view].get(key),
                    album_id=self.db_albums[view][0] if self.db_albums[view] else None))
            for key in sorted(set(self.disk[view]) - set(self.db_keys[view])):
                self.findings.append(Finding(
                    'FILE_NO_DB', 'the tree has the track, beets does not',
                    view=view + '_disk', disc=key[0], track=key[1],
                    title=self.disk[view][key]['title'], path=self.disk[view][key]['path']))

    def check_navidrome(self):
        """NAV_SPLIT, NAV_ABSENT, NAV_GHOST, NAV_MISSING_ROW, MASS_MISSING.

        A release that Navidrome knows nothing about is one finding about the
        release, not one per track; the same for an album whose files are all
        gone (a purge candidate). A partially present release is reported per
        track, so the operator sees what is missing.
        """
        if self.nav is None:
            return
        if len(self.nav_albums) > 1:
            self.findings.append(Finding(
                'NAV_SPLIT', 'the release is %d Navidrome albums: %s'
                % (len(self.nav_albums), ', '.join(self.nav_albums)),
                view='navidrome', album_id=self.nav_albums[0]))
        served_view = 'opus_disk' if self.disk['opus'] else 'flac_disk'
        served = self.disk['opus'] if self.disk['opus'] else self.disk['flac']
        known = (set(self.disk['opus']) | set(self.db_keys['opus'])
                 | set(self.disk['flac']) | set(self.db_keys['flac']))
        if served and not self.nav_keys:
            self.findings.append(Finding(
                'NAV_ABSENT', 'the whole release is absent from Navidrome',
                view=served_view, album_id=self.nav_albums[0] if self.nav_albums else None,
                path=self.rels()[0] if self.rels() else None))
        else:
            for key in sorted(set(served) - set(self.nav_keys)):
                self.findings.append(Finding(
                    'NAV_ABSENT', 'in %s, absent from Navidrome' % served_view,
                    view=served_view, disc=key[0], track=key[1],
                    title=served[key]['title'],
                    album_id=self.nav_albums[0] if self.nav_albums else None))
        if self.nav_keys and not (set(self.nav_keys) & known):
            self.findings.append(Finding(
                'NAV_GHOST', 'every track of this Navidrome album is gone (%d in the snapshot, '
                'none on disk): purge candidate' % len(self.nav_keys),
                view='navidrome', album_id=self.nav_albums[0] if self.nav_albums else None))
        else:
            for key in sorted(set(self.nav_keys) - known):
                self.findings.append(Finding(
                    'NAV_GHOST', 'in Navidrome, in none of the libraries', view='navidrome',
                    disc=key[0], track=key[1], title=self.nav_keys[key],
                    album_id=self.nav_albums[0] if self.nav_albums else None))
        if self.nav_missing:
            self.findings.append(Finding(
                'NAV_MISSING_ROW', '%d row(s) of this release are marked missing'
                % self.nav_missing, view='navidrome',
                album_id=self.nav_albums[0] if self.nav_albums else None))
            if self.nav_missing > self.threshold:
                self.findings.append(Finding(
                    'MASS_MISSING', '%d missing row(s), above the threshold of %d'
                    % (self.nav_missing, self.threshold), view='navidrome'))

    def check_short(self):
        """One TRACK_SHORT per track key that a readable view does not have."""
        live = [view for view in VIEWS if self.available()[view]]
        present = {
            'flac_disk': dict((k, v['title']) for k, v in self.disk['flac'].items()),
            'flac_db': dict(self.db_keys['flac']),
            'opus_disk': dict((k, v['title']) for k, v in self.disk['opus'].items()),
            'opus_db': dict(self.db_keys['opus']),
            'navidrome': dict(self.nav_keys),
        }
        keys = set()
        for view in live:
            keys |= set(present[view])
        for key in sorted(keys):
            missing = [view for view in live if key not in present[view]]
            title = ''
            for view in live:
                title = present[view].get(key) or title
                if title:
                    break
            self.tracks[key] = {
                'disc': key[0], 'track': key[1], 'label': track_label(*key),
                'title': title, 'views': [v for v in live if key in present[v]],
                'short': missing,
            }
            if missing:
                self.findings.append(Finding(
                    'TRACK_SHORT', 'missing from ' + ', '.join(missing),
                    view=missing[0], disc=key[0], track=key[1], title=title))

    # -- report ------------------------------------------------------------

    def run(self):
        self.resolve()
        self.read_db('flac', self.roots['flac'])
        self.read_db('opus', self.roots['opus'])
        self.read_navidrome()
        self.check_libraries()
        self.check_navidrome()
        self.check_short()
        for frame in self.frames:
            self.findings.append(Finding('UNREADABLE', frame['error'],
                                         view=frame.get('view'), path=frame.get('path')))
        self.findings.sort(key=Finding.sort_key)
        return self.document()

    def document(self):
        views = {}
        for name, view, kind in (
                ('flac_disk', 'flac', 'disk'), ('flac_db', 'flac', 'db'),
                ('opus_disk', 'opus', 'disk'), ('opus_db', 'opus', 'db')):
            root = self.roots[view]
            tracks = self.disk[view] if kind == 'disk' else self.db_keys[view]
            if kind == 'disk':
                available = bool(root) and self.disk_rel[view] is not None
                reason = 'no root given' if not root else 'release absent from this tree'
                albums = []
            else:
                available = self.db_available[view]
                reason = 'no library.db read'
                albums = list(self.db_albums[view])
            doc = {'available': available, 'root': root, 'folder': self.disk_rel[view],
                   'count': len(tracks), 'items': [track_label(*k) for k in sorted(tracks)]}
            if albums:
                doc['albums'] = albums
            if kind == 'db' and self.db_mbids[view]:
                doc['mb_albumid'] = sorted(self.db_mbids[view])
            if kind == 'db' and not tracks:
                doc['present'] = bool(albums)
            else:
                doc['present'] = bool(tracks)
            if not available:
                doc['reason'] = reason
            views[name] = doc
        if self.nav is not None:
            views['navidrome'] = {
                'available': True, 'snapshot': self.nav.path,
                'snapshot_time': self.nav.snapshot_time,
                'library': sorted(self.nav.roots),
                'albums': list(self.nav_albums), 'present': bool(self.nav_albums),
                'count': len(self.nav_keys),
                'items': [track_label(*k) for k in sorted(self.nav_keys)],
            }
        else:
            views['navidrome'] = {'available': False, 'present': False, 'count': 0,
                                  'reason': 'no --navidrome-db given', 'items': []}

        errors = sum(1 for f in self.findings if f.severity == 'error')
        status = FINDINGS if errors else CLEAN
        return {
            'tool': 'audit-library.py --release',
            'generated': time.strftime('%Y-%m-%d %H:%M'),
            'release': self.spec,
            'identity': {
                'folder': self.rels()[0] if self.rels() else None,
                'mb_albumid': sorted(self.mbids),
                'beets_albums': dict(self.db_albums),
                'navidrome_albums': list(self.nav_albums),
            },
            'views': views,
            'counts': dict((view, views[view]['count']) for view in VIEWS),
            'tracks': [self.tracks[key] for key in sorted(self.tracks)],
            'short': [self.tracks[key]['label'] for key in sorted(self.tracks)
                      if self.tracks[key]['short']],
            'findings': [f.as_dict() for f in self.findings],
            'ok': status == CLEAN,
            'exit_status': status,
        }


def render_release(doc, findings, samples, full):
    print(f"Release doctor, {doc['generated']} (read-only)")
    print(f"release: {doc['release']}")
    ident = doc['identity']
    print("identity: folder %s; mb_albumid %s"
          % (ident['folder'] or '-', ', '.join(ident['mb_albumid']) or '-'))

    print('\n== views')
    for name in VIEWS:
        view = doc['views'][name]
        head = '  %-10s' % name
        if not view.get('available'):
            print('%s   --  %s' % (head, view.get('reason', 'not available')))
            continue
        detail = []
        if view.get('root'):
            detail.append(view['root'])
        if view.get('snapshot_time'):
            detail.append('snapshot ' + view['snapshot_time'])
        if view.get('albums'):
            detail.append('album ' + ', '.join(str(a) for a in view['albums']))
        if not view.get('present'):
            detail.insert(0, 'release absent')
        print('%s%4d track(s)  %s' % (head, view['count'], '  '.join(detail)))

    print('\n== tracks')
    tracks = doc['tracks']
    limit = len(tracks) if full else samples
    for track in tracks[:limit]:
        print('  %s  [%s]  %-44s  %s'
              % (track['label'], '!!' if track['short'] else 'ok', track['title'][:44],
                 ' '.join(track['views'])))
    if len(tracks) > limit:
        print('  ... %d more track(s) (--list shows all)' % (len(tracks) - limit))

    print('\n== findings')
    if not findings:
        print('  [ok] nothing to report for this release')
    limit = len(findings) if full else max(samples, 20)
    for finding in findings[:limit]:
        print('  ' + finding.text())
    if len(findings) > limit:
        print('  ... %d more (--list shows all)' % (len(findings) - limit))

    errors = sum(1 for f in findings if f.severity == 'error')
    print('\n%d finding(s): %d error, %d warning; %d short track(s) of %d; exit %d'
          % (len(findings), errors, len(findings) - errors, len(doc['short']),
             len(tracks), doc['exit_status']))


def run_release(args):
    maps = parse_library_maps(args.library_map)
    nav = Navidrome(args.navidrome_db, maps) if args.navidrome_db else None
    try:
        doctor = ReleaseDoctor(args.release, args.lossless, args.lossy, nav,
                               args.mass_missing_threshold)
        try:
            doc = doctor.run()
        except UnknownRelease:
            print('error: release %r is in none of the views (check the Artist/Album spelling)'
                  % args.release, file=sys.stderr)
            return UNKNOWN
    finally:
        if nav is not None:
            nav.close()
    if args.json:
        print(json.dumps(doc, indent=2))
    else:
        render_release(doc, doctor.findings, args.samples, args.list)
    return doc['exit_status']


def render_missing(doc, findings, samples, full):
    print(f"Navidrome missing inventory, {doc['generated']} (read-only)")
    print(f"source: {doc['source']}")
    print('\n== inventory')
    print('  [%s] missing files: %d (MASS_MISSING above %d)'
          % ('!!' if doc['count'] else 'ok', doc['count'], doc['threshold']))
    limit = len(doc['files']) if full else samples
    for entry in doc['files'][:limit]:
        print('        %s' % (entry.get('local_path') or entry.get('path') or entry.get('id')))
    if len(doc['files']) > limit:
        print('        ... %d more (--list shows all)' % (len(doc['files']) - limit))
    print('\n== findings')
    if not findings:
        print('  [ok] nothing is missing')
    for finding in findings:
        print('  ' + finding.text())
    print('\nexit %d' % doc['exit_status'])


def run_missing(args):
    maps = parse_library_maps(args.library_map)
    nav = None
    if args.missing_json:
        rows, source = read_missing_json(args.missing_json)
        for row in rows:
            row.setdefault('local_path', None)
    else:
        nav = Navidrome(args.navidrome_db, maps)
        try:
            rows = nav.missing_rows()
            for row in rows:
                row['local_path'] = nav.local_path(row)
            source = 'snapshot %s (%s)' % (args.navidrome_db, nav.snapshot_time)
        finally:
            nav.close()
    findings = []
    for row in rows:
        findings.append(Finding(
            'NAV_MISSING_ROW', '', view='navidrome', disc=row.get('disc_number'),
            track=row.get('track_number'), title=row.get('title'),
            album_id=row.get('album_id'),
            path=row.get('local_path') or row.get('path') or row.get('id')))
    if len(rows) > args.mass_missing_threshold:
        findings.append(Finding(
            'MASS_MISSING', '%d file(s) missing, above the threshold of %d'
            % (len(rows), args.mass_missing_threshold), view='navidrome'))
    findings.sort(key=Finding.sort_key)
    errors = sum(1 for f in findings if f.severity == 'error')
    status = FINDINGS if errors else CLEAN
    doc = {
        'tool': 'audit-library.py --missing',
        'generated': time.strftime('%Y-%m-%d %H:%M'),
        'source': source,
        'count': len(rows),
        'threshold': args.mass_missing_threshold,
        'files': rows,
        'findings': [f.as_dict() for f in findings],
        'ok': status == CLEAN,
        'exit_status': status,
    }
    if args.json:
        print(json.dumps(doc, indent=2))
    else:
        render_missing(doc, findings, args.samples, args.list)
    return status


def _first_json(text, opener):
    """The first JSON document in text, ignoring the banner printed before it."""
    decoder = json.JSONDecoder()
    start = text.find(opener)
    while start >= 0:
        try:
            value, _ = decoder.raw_decode(text, start)
            return value
        except ValueError:
            start = text.find(opener, start + 1)
    raise UsageError('no JSON %s found in the input' % opener)


def read_missing_json(path):
    """Rows of `navidrome missing list -f json`, banner tolerant (design D5)."""
    if path == '-':
        text = sys.stdin.read()
        source = 'stdin'
    else:
        try:
            with open(path, encoding='utf-8', errors='surrogateescape') as fh:
                text = fh.read()
        except OSError as exc:
            raise UsageError('--missing-json %s: %s' % (path, exc))
        source = path
    data = _first_json(text, '[')
    if isinstance(data, dict):
        data = data.get('missing') or data.get('files') or []
    if not isinstance(data, list):
        raise UsageError('--missing-json %s: expected a list of missing files' % path)
    rows = []
    for entry in data:
        if isinstance(entry, str):
            rows.append({'id': None, 'path': entry, 'title': None, 'album_id': None,
                         'disc_number': None, 'track_number': None})
        elif isinstance(entry, dict):
            rows.append({
                'id': entry.get('id') or entry.get('media_file_id'),
                'path': entry.get('path'),
                'title': entry.get('title'),
                'album_id': entry.get('album_id'),
                'disc_number': entry.get('disc_number') or entry.get('disc'),
                'track_number': entry.get('track_number') or entry.get('track'),
            })
        else:
            raise UsageError('--missing-json %s: unexpected entry %r' % (path, entry))
    return rows, source


def parse_library_maps(values):
    maps = {}
    for value in values or ():
        if '=' not in value:
            raise UsageError('--library-map %s: expected ROOT=DIR' % value)
        root, target = value.split('=', 1)
        root = nfc(root.strip().rstrip('/'))
        if not root or not target:
            raise UsageError('--library-map %s: expected ROOT=DIR' % value)
        maps[root] = target
    return maps


def run_audit(args):
    start = time.time()
    rep = Report(args.samples, args.list)
    print(f'Library audit, {time.strftime("%Y-%m-%d %H:%M")} (read-only)')
    if sys.platform == 'darwin':
        print('NOTE: macOS shows names on SMB shares partly in NFD: ignore the "Unicode normalization"\n'
              '      findings here and run server/audit.sh for those.')
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


def build_parser():
    ap = argparse.ArgumentParser(
        description=__doc__.split('\n\n')[0],
        epilog='Findings: %s.\n\nExit status: 0 clean, 1 findings, 2 usage or I/O error,'
               ' 3 unknown release.' % ', '.join(sorted(SEVERITY, key=SEVERITY.get)),
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--lossless', metavar='DIR', help='FLAC library root (with library.db)')
    ap.add_argument('--lossy', metavar='DIR', help='Opus library root (with library.db)')
    ap.add_argument('--old', metavar='DIR',
                    help='old lossy copy to compare against --lossy (default audit only)')
    ap.add_argument('--list', action='store_true', help='print every entry, not samples')
    ap.add_argument('--samples', type=int, default=10, help='entries shown per finding (default 10)')
    ap.add_argument('--emit-missing-lossy', metavar='FILE',
                    help='write FLAC albums with no Opus copy (default audit only)')
    ap.add_argument('--threads', type=int, default=16, help='parallel directory scans (default 16)')
    ap.add_argument('--release', metavar='ARTIST/ALBUM',
                    help='reconcile one release across the five views')
    ap.add_argument('--navidrome-db', metavar='FILE',
                    help='Navidrome database snapshot (opened read-only)')
    ap.add_argument('--library-map', metavar='ROOT=DIR', action='append', default=[],
                    help='translate a library root of the snapshot into DIR (repeatable)')
    ap.add_argument('--missing', action='store_true',
                    help="report Navidrome's missing inventory (count, paths, MASS_MISSING)")
    ap.add_argument('--missing-json', metavar='FILE',
                    help='read `navidrome missing list -f json` output from FILE (- = stdin)')
    ap.add_argument('--mass-missing-threshold', metavar='N', type=int, default=MASS_MISSING_DEFAULT,
                    help='missing files tolerated before MASS_MISSING (default %d)'
                         % MASS_MISSING_DEFAULT)
    ap.add_argument('--json', action='store_true',
                    help='print one JSON document instead of the text report')
    return ap


def main():
    ap = build_parser()
    args = ap.parse_args()

    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(errors='backslashreplace')

    try:
        if args.missing and args.release:
            ap.error('--missing and --release are two modes: pick one')
        if args.json and not (args.release or args.missing):
            ap.error('--json needs --release or --missing')
        if args.missing_json and not args.missing:
            ap.error('--missing-json needs --missing')
        if args.library_map and not args.navidrome_db:
            ap.error('--library-map needs --navidrome-db (the snapshot records the roots)')
        if args.navidrome_db and not (args.release or args.missing):
            ap.error('--navidrome-db needs --release or --missing')
        if args.mass_missing_threshold < 0:
            ap.error('--mass-missing-threshold must not be negative')
        if args.samples < 0:
            ap.error('--samples must not be negative')

        if args.release:
            if not (args.lossless and args.lossy):
                ap.error('--release needs --lossless and --lossy')
            return run_release(args)
        if args.missing:
            if not (args.missing_json or args.navidrome_db):
                ap.error('--missing needs --navidrome-db or --missing-json')
            return run_missing(args)

        if not (args.lossless and args.lossy):
            ap.error('--lossless and --lossy are required for the library audit')
        for d in filter(None, (args.lossless, args.lossy, args.old)):
            if not os.path.isfile(os.path.join(d, 'library.db')):
                print(f'error: no library.db in {d}', file=sys.stderr)
                return USAGE
        return run_audit(args)
    except UsageError as exc:
        print('error: %s' % exc, file=sys.stderr)
        return USAGE


if __name__ == '__main__':
    try:
        sys.exit(main())
    except OSError as e:
        print(f'error: {e}', file=sys.stderr)
        sys.exit(2)
