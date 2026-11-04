# Proposal

## Why

The stack can import an album but cannot decommission one: a release lives in five stores at once (FLAC tree, FLAC beets DB, Opus tree, Opus DB, Navidrome DB) and only the first four have any tooling, while Navidrome runs with `PurgeMissing = "never"` on purpose, so files deleted behind its back stay as missing rows forever.

The failure is not hypothetical. On 2026-11-03 the import of *William Basinski — Passing the Cup of Sorrows* recorded "All albums processed successfully" and exit 0 while only 2 of 10 files reached the Opus tree; the other 8 rows kept absolute `/import/Disc 0X/...` paths in the lossy beets DB, and no existing check detects it. Removing that album today would have to be done by hand against five stores with no audit trail.

## What Changes

- `library-organizer/audit-library.py` gains per-release reconciliation across five views (`flac_disk`, `flac_db`, `opus_disk`, `opus_db`, `navidrome`), so a partial import is reported as a short track list instead of an exit code 0. New flags: `--release`, `--navidrome-db`, `--library-map`, `--missing`, `--json`; stable exit codes.
- New `library-organizer/beets/rm_album.py`: removes a beets album **by album id** through the beets API on both databases (never by query, never by path).
- New `library-organizer/server/doctor.sh`: the server entry point that takes a consistent Navidrome snapshot and runs the reconciliation.
- New `library-organizer/server/navidrome-snapshot.sh`: takes the Navidrome database snapshot through `pct exec` and `pct pull`, verifies it, and prunes old copies, so both the doctor's Navidrome view and the removal's rollback artifact come from one mechanism.
- New `library-organizer/server/remove-album.sh`: the guarded deletion sequence — preflight, snapshot, beets rows, `mv` to trash, targeted scan, delta-guarded purge, verification.
- New `library-organizer/docs/audit.md` and `library-organizer/docs/remove-album.md`; `server/common.sh` gains the shared constants (`TRASH_DIR`, library id, snapshot dir).

## Capabilities

### New Capabilities

- `library-doctor`: read-only reconciliation of one release — or the whole library — across the four local stores plus the Navidrome view, with a machine-readable report that names which tracks are short and where.
- `album-decommission`: the reversible, guarded removal of a release from every store, including the trash step and the bounded purge of the Navidrome rows it leaves behind.

### Modified Capabilities

None: `library-organizer` has no specs yet, and the import pipeline's behaviour is unchanged (`sync-lossless.sh`, the beets config and the entrypoint are untouched).

## Impact

- `library-organizer/audit-library.py` (extended, existing checks preserved), `library-organizer/server/common.sh` (constants only).
- New files: `library-organizer/beets/rm_album.py`, `library-organizer/server/doctor.sh`, `library-organizer/server/remove-album.sh`, `library-organizer/server/navidrome-snapshot.sh`, `library-organizer/docs/audit.md`, `library-organizer/docs/remove-album.md`.
- Runtime stores touched: `/mnt/musicbucket/navidrome_library_flac`, `/mnt/musicbucket/navidrome_library`, their beets DBs, and the Navidrome DB in LXC 111 (read-only, from a snapshot).
- External CLI dependencies, both already present: beets 2.10.0 inside the Docker image, and `navidrome` 0.64.2 on the PVE host via `pct exec 111` (`missing list`, `doctor`, `scan -t`, `backup create`).
- No breaking changes: no default behaviour of an existing script changes, no beets plugin or config change, no new network service.
- Out of scope: repairing the 8 orphaned rows of the Basinski album, the `navidrome-orchestra/` docker stack (dead config), and the Telegram bot.
