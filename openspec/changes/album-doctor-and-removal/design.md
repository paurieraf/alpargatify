# Design

## Context

See `proposal.md` for motivation. The constraints that shape the approach are all measured facts from the live stack, not assumptions:

| Fact | Value | Consequence |
|---|---|---|
| Navidrome | native 0.64.2 in LXC 111, `MusicFolder=/media/music` | CLI is available through `pct exec`; the Docker stack in `navidrome-orchestra/` is dead config |
| Purge policy | `PurgeMissing="never"`, `ScanOnStartup=false`, `Schedule="0"`, `WatcherWait="1m"` | nothing purges implicitly; a purge must be explicit, and `DeleteAllMissing()` is library-wide |
| Missing set | empty (`missing list -f json` → `[]`) | the purge gate has a clean baseline today |
| Trees | `/mnt/usb-hdd-wd-5tb/musicbucket/navidrome_library{,_flac}` on the PVE host, `/mnt/musicbucket/...` in LXC 101 | two path views of the same storage |
| Beets DBs | `library.db` inside each tree, paths relative | staging and share are interchangeable; `library.db.prev` must be preserved |
| Beets binary | only inside the `local/beets:latest` image on LXC 101 | the beets API is reachable only through Docker |
| Navidrome DB | 885 MB, WAL, no `sqlite3` inside 111 | never opened in place; read from a snapshot |
| Album identity | `DefaultAlbumPID` = `musicbrainz_albumid|albumartistid,album,albumversion,releasedate` | no discnumber: a multi-disc release is one album spanning folders |
| Backups | nightly vzdump, DB yes, music no | trash is the only file-level undo |
| Tools on the PVE host | `pct`, `python3` 3.13, `sqlite3` | one machine can reach both CTs and read everything |

`audit-library.py` already owns the DB-vs-disk comparison for one library and the lossless↔lossy mirror comparison, including NFC/NFD drift, absolute paths, orphan items, duplicate `mb_albumid`, drift timestamps and temp leftovers. The doctor work is a widening of that reconciler, not a second one.

## Goals / Non-Goals

**Goals**

- One reconciler that answers "does this release exist identically in all five views, and if not, which tracks are short".
- One removal path that is reversible (trash), guarded (delta of the missing inventory), and verifiable (the same reconciler proves the release is gone).
- Zero new credentials, zero new services, zero persistent configuration changes.
- Run from the PVE host, which is the only machine that reaches both CTs.

**Non-Goals**

- Repairing the 8 orphaned rows of the Basinski album: the doctor will name them; fixing them is a separate change.
- Pruning the trash automatically, or deleting anything permanently.
- Changing the import pipeline, the beets config, or the beets plugin list.
- Migrating `navidrome-orchestra/` or reconciling it with the native install.
- Rebuilding Navidrome annotations, play counts or ratings after a purge.

## Decisions

### D1 — Widen `audit-library.py`; do not write a second reconciler

The alternative (a new `doctor.py`, or shell-only checks) duplicates the normalization, path-comparison and mirror logic that already exists and is battle-tested against the NFD pitfalls. `audit-library.py` keeps every existing check and exit code; the new capability lands as an additional view layer that the existing checks feed.

### D2 — A release is identified three ways, and the doctor reconciles on track keys

On disk a release is `Artist/Album` (and its `Disc NN` subfolders); in a beets database it is an album row with an id and `mb_albumid`; in Navidrome it is an album row with an id. The reconciler compares tracks on `(disc, track)` with the title as a tie-breaker, so a track present in one view and absent from another is named rather than merely counted. Disc numbers come from the folder name when present, from the beets item otherwise.

### D3 — Five views, one findings vocabulary

`flac_disk`, `flac_db`, `opus_disk`, `opus_db`, `navidrome`. Findings carry a stable code and a severity so both humans and scripts read the same thing: `TRACK_SHORT`, `ORPHAN_PATH` (absolute or unmapped row path), `DB_NO_FILE`, `FILE_NO_DB`, `NAV_ABSENT` (release on disk unknown to Navidrome), `NAV_GHOST` (Navidrome album with no files), `NAV_SPLIT` (one release, several albums), `NAV_MISSING_ROW`, `UNREADABLE`, `MASS_MISSING`.

### D4 — The Navidrome view is a snapshot on the shared volume

`pct exec 111 -- navidrome backup create -d /var/lib/navidrome/backup` then `pct pull` into `<musicbucket>/.ops/navidrome-<timestamp>.db`; the doctor opens it with a read-only URI and maps the snapshot's library root onto a local directory (`--library-map`). Alternatives rejected: opening the live DB (WAL, no `sqlite3` in the CT, and it would need write access), and driving the Subsonic/native API for a full sweep (thousands of calls, and it reports the *current* scan state, not the contents of the store). The snapshot doubles as the rollback artifact for removal, so one mechanism serves both purposes.

Measured while implementing: in this 0.64.2 snapshot `media_file.path` is **relative to `library.path`** (`select count(*) from media_file where path like '/%'` returns 0), contrary to what the 0.61.2 schema suggested. The reader therefore accepts both shapes and resolves each row to a local path either way.

`--navidrome-db` is optional for the doctor as a whole but **mandatory for removal**: without it the `navidrome` view reports `available: false` and a ghost album would be invisible, so `remove-album.sh` refuses to continue unless the JSON carries a present `views.navidrome`.

### D5 — The purge gate reads the live missing inventory, not the snapshot

The gate needs the state *now*, so it runs `pct exec 111 -- navidrome missing list -c /etc/navidrome/navidrome.toml -f json` before and after the rescan. Tolerating the tool's banner is part of the contract: the parser anchors on the first `[` and ignores everything before it. Measured: in this install the banner goes to stderr, so stdout is already clean; the tolerance stays because the CLI may change where it prints, and it is exercised by a fixture with a banner-prefixed file.

### D6 — Beets rows are removed through the beets API, by album id, in the existing image

`rm_album.py` loads the library, resolves the album by id, and calls `album.remove(delete=False)` inside the beets transaction; the script refuses an ambiguous or unknown id and prints what it removed. Alternatives rejected: raw SQL (beets maintains dynamic attribute tables and mutation hooks; a hand-written delete drifts from the model), and `beet remove -a -d "<query>"` (queries are fuzzy, `id:` on an album query can resolve to an item, and `-d` unlinks files irreversibly). The database file is never copied to staging: the script runs with the tree mounted at `/data`, exactly like the import does, and the previous state is kept as `library.db.prev`. The container runs with `--user 0:0`: the beets image runs as uid 1000 and `library.db` is owned by root, so without the flag the transaction opens the database read-only (found on the first attempt, and the reason the flag is part of the documented invocation rather than a detail of the caller).

### D7 — Files go to a dated trash area inside the shared volume

`<musicbucket>/.trash/<YYYYMMDDTHHMMSSZ>-<slug>/<lossless|lossy>/<Artist>/<Album>/`, with the lossless and lossy copies kept side by side under their tree label and their relative paths preserved below it. The tree level is not decoration: both libraries hold the same `Artist/Album` relative path, so without it the second move would overwrite the first (found while implementing; the script refuses an existing trashed copy and rolls the first tree back instead of losing it). The labels match the `--lossless-root`/`--lossy-root` flags and the `trash_lossless`/`trash_lossy` report keys. It sits outside both library roots, so neither the Navidrome scanner nor the doctor sees it. Alternatives rejected: `rm` (no undo, and the music is not in the vzdump), moving the folder *into* the library tree as `.deleted/` (Navidrome would skip it, but the doctor's temp-file and stray-file checks would flag it forever), and naming the level after the root basename (self-describing on disk, but it changes as soon as the roots are overridden).

The move leaves two things behind that the design has to name. The emptied `Artist` directory is removed with `rmdir` (which refuses to touch anything non-empty), so a one-album artist does not leave a husk that the doctor would report as an empty folder. Navidrome keeps a `folder` row for the removed path, flagged `missing = 1`, and a targeted scan does not collect it — only a full-library scan does, which a removal never runs; the rows are harmless (no `media_file` or `album` row references them, the missing inventory is empty, and the album view is unchanged) and the doctor must not present them as a problem, only as a note that a later full scan will tidy up. `--keep-trash` keeps the files in trash even when the failure window is still fully reversible; by default the move is rolled back when nothing has been purged and no row is gone.

### D8 — Purge: targeted scan plus a per-invocation override, gated by set arithmetic

After the files are gone, `ND_SCANNER_PURGEMISSING=always` is set **only for the duration of** `navidrome scan -t 1:"Artist/Album"`. Because `DeleteAllMissing()` is library-wide, the run proceeds only when both the baseline and the post-scan missing sets are subsets of the removed release's own files; otherwise it aborts and leaves every row in place. The persistent configuration keeps `never`. The id-scoped `DELETE /api/missing?id=…` route exists and is documented as the manual escape hatch for a single stubborn row, but it needs admin credentials that the server does not have.

### D9 — The entry point lives on the PVE host and crosses into the CTs with `pct`

```
PVE host  server/remove-album.sh  (MUSICBUCKET=/mnt/usb-hdd-wd-5tb/musicbucket)
   |-- pct exec 111 -- navidrome backup|missing list|scan -t   (no credentials)
   |-- pct exec 101 -- docker run --rm --user 0:0 local/beets:latest rm_album.py
   |                      (mounts use the CT view: /mnt/musicbucket/...)
   +-- local: doctor, trash moves, gate arithmetic
```

`MUSICBUCKET` defaults to `/mnt/musicbucket`, which is the **container** view, because `common.sh` is shared with the in-container `audit.sh`; it does not exist on the PVE host, so every host run needs `export MUSICBUCKET=/mnt/usb-hdd-wd-5tb/musicbucket`. `remove-album.sh` refuses to start unless `MUSICBUCKET` is an existing directory and not the container path, and the hint it prints is the export line above. `ct_path()` translates host paths back into the CT view for the `pct exec` calls.

Alternatives rejected: running on LXC 101 and reaching 111 over the network (would need a new credential or a scanner-privileged ssh path), and running on the host but writing the beets rows with SQL. `common.sh` keeps `MUSICBUCKET` overridable and gains `CT_MUSICBUCKET` for the Docker mounts, with `ct_path()` translating between the two.

### D10 — Nothing destructive runs before a verified snapshot

`pct exec 111 -- navidrome backup create`, then `pct pull`, then a verification pass that the file is a readable SQLite database with the Navidrome schema (`pragma quick_check` plus a `media_file` count). Old snapshots are pruned to two with `navidrome backup prune`, so the shared volume does not accumulate 885 MB files.

### D11 — Order of the destructive stages: database rows, then files

Rows first, files second. If the run dies in between, the worst state is files on disk with no rows — invisible to the library and recoverable by re-import, and the doctor names it. The reverse order leaves rows pointing at nothing, which is the state the Basinski album is already in and which is harder to reason about. Both stages are preceded by the snapshot and the baseline capture.

Rollback is automatic only in the one window where it is provably exact: after the file move and before any row is removed or any purge runs, the abort path moves the folders back from trash and leaves every store as it was. Once `library.db` rows are gone the script prints the exact restore commands (copy `library.db.prev` over `library.db` inside LXC 101, restore the Navidrome snapshot offline) instead of performing them, deliberately: between our own removal and the abort another process may have written the database (an import, a sync run), and silently overwriting it would destroy that work. The `.prev` copy is taken immediately before the removal, so the operator's manual restore has a well-defined target, and the doctor's five views make the resulting mismatch visible if the restore is never done.

### D12 — Shared exit codes and one JSON document

`0` clean, `1` findings, `2` usage error, `3` unknown release; the removal reuses the doctor's statuses and adds `4` for "aborted by a guard". `--json` prints exactly one document; human output stays the default because this is an operator tool.

## Risks / Trade-offs

- **The purge is library-wide even when targeted** → the set-arithmetic gate is the only thing standing between a targeted scan and a global purge; it is implemented as the last step before the scan, aborts on any unrelated entry, and the run reports both sets in full.
- **Trash accumulates forever** → out of scope to prune, but it is a single directory outside both libraries, named per run, so pruning is `rm -rf` with a date argument; the docs say so.
- **Path translation between host and CT is a footgun** → every Docker mount goes through one helper, and the run verifies the CT-side path exists before launching the container.
- **The beets API work depends on the 101 checkout being current** → the deploy step is a `git pull` of `/opt/alpargatify` on 101, documented as a manual step in the repo's usual style; the script version is printed in the run header.
- **The doctor's Navidrome view is only as fresh as the snapshot** → the report prints the snapshot timestamp and path, and the removal always takes a fresh one first.
- **Existing drift stays invisible until the doctor runs** → the change does not fix anything by itself; it makes the drift reportable, and the Basinski album is the proof case.

## Migration Plan

1. Deploy the scripts: `git pull` in `/opt/alpargatify` on LXC 101 (for the Docker-side `rm_album.py`) and a checkout of the same repository on the PVE host at `/opt/alpargatify` (for `remove-album.sh`, `doctor.sh`, `audit-library.py`).
2. Dry run against the Basinski album: it must report 10 lossless tracks against 3 lossy tracks, name the 8 orphan-path rows, and touch nothing.
3. First real removal, on a throwaway release, then re-run the doctor to confirm all five views are clean and the missing set is back to its baseline.
4. Rollback for any step: `mv` the trash folder back, `navidrome scan -t` to rescan, `library.db.prev` for the databases, `navidrome backup restore` for the database as a whole.

No configuration, schema or plugin change is involved, so there is no data migration and no compatibility window.

## Deployment evidence (2026-11-04, live stack)

Run from the PVE host (`root@10.1.1.10`), with the repository checked out at `/opt/alpargatify` on the PVE host (clone over SSH, key `/root/.ssh/id_ed25519_github`) at commit `35f195e`, and `export MUSICBUCKET=/mnt/usb-hdd-wd-5tb/musicbucket`.

Tooling check: `python3 -m py_compile` on `audit-library.py` and `beets/rm_album.py`, `bash -n` on `common.sh`, `remove-album.sh` and `navidrome-snapshot.sh`, and `--help` for both entry points all pass on the host (Python 3.13.5, git 2.47.3, no Docker on the host — the beets work goes through `pct exec 101 -- docker run`).

Snapshot used by both reports: `.ops/navidrome-20261104T081052Z.db` (885,112,832 B, UTC stamp), created and verified by `server/navidrome-snapshot.sh` (`media_file=46663`, `albums=4337`, `libraries=1`, `quick_check` ok, `.ops` pruned to two).

Doctor on the example release (`--release "William Basinski/William Basinski - [2026] Passing the Cup of Sorrows" --navidrome-db <snapshot> --library-map /media/music=…/navidrome_library`): `flac_disk 10 / flac_db 10 / opus_disk 3 / opus_db 10 / navidrome 3`, 15 findings (7 `TRACK_SHORT` + 8 `ORPHAN_PATH`), exit 1. `--missing` on the same snapshot: `missing files: 0 (MASS_MISSING above 20)`, exit 0 — this is the baseline a removal must return to.

Removal dry run on the same release (`--dry-run --beets-tools-dir /opt/beets-tools`): all ten stages printed their plan, including the two album ids (`5506` lossless, `4713` lossy), the two trash destinations under `<run>/lossless|lossy/…`, the targeted `scan -t 1:"…"` with `ND_SCANNER_PURGEMISSING=never` and the purge command with `always`; every store reported unchanged, exit 0.

End-to-end with a throwaway release (`Fela Kuti & Africa 70 - [2013] Confusion`, one track, consistent in all five views; album ids `4983`/`4218`, Navidrome `383yndYcQ9rZ5BCaGIeev6`): the real removal reported `baseline_missing=0`, `gate_allowed=1`, `gate_baseline=pass`, `rows_lossless_items=1`, `rows_lossy_items=1`, `trash_moved=2`, `gate_after=pass`, `purge_ran=scan`, `verify=clean`, `result=removed`, exit 0; afterwards both trees were gone, both beets albums had 0 items and `navidrome missing list` returned `[]`. The rollback (files back from trash, both `library.db` restored from `library.db.prev`, targeted rescan to re-add in Navidrome) left both databases byte-identical to their pre-run SHA-256, both trees back to 2 files, the doctor reporting `0 finding(s) … exit 0` and `--missing` reporting nothing missing. This is the round trip the procedure is supposed to guarantee.

Note for the LXC 101 deployment: its checkout is on `feat/server-side-sync` (pulled to `f257042`), which does not contain `beets/rm_album.py`, so the run used `--beets-tools-dir /opt/beets-tools` (the file pushed with `pct push --perms 644`) instead of the default `/opt/alpargatify/library-organizer/beets`. Once `paurieraf/eliminar-track` reaches that branch, the default path works without the flag and the tools copy can be deleted.

## Open Questions

- ~~Whether the PVE host should keep a full checkout of the repository or only the three scripts~~ — answered by the deployment: a full checkout at `/opt/alpargatify`, cloned over SSH from GitHub, so `git pull` updates the entry points and the audit script together.
- Whether the doctor should be wired to a timer on the host once the drift is understood (deliberately left out of this change).
