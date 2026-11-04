# Tasks

Parallelisation note: group 1 lands first (both other groups consume it). After that, group 2 (doctor) and group 3 (removal) are independent — the contracts are fixed in `design.md` and in the two delta specs — and group 4 closes the loop once both are in.

## 1. Shared foundations

- [x] 1.1 Extend `library-organizer/server/common.sh` with `CT_MUSICBUCKET` (default `/mnt/musicbucket`), `OPS_DIR` (`$MUSICBUCKET/.ops`), `TRASH_DIR` (`$MUSICBUCKET/.trash`), `NAVIDROME_CT=111`, `BEETS_CT=101` and a `ct_path()` helper that maps a host path to the LXC 101 view; verify with `bash -n server/common.sh`, `shellcheck`, and a shell that sources it and prints every variable for both `MUSICBUCKET` values.
- [x] 1.2 Add a `require_ct_path()` guard that fails when the translated path does not exist inside the CT before any `docker run`; verify by sourcing the file and running it against a known-good path (`/mnt/musicbucket/navidrome_library`) and a bogus one, checking the exit codes.

## 2. Doctor — five-view reconciliation (`library-doctor`)

- [x] 2.1 Add release resolution to `library-organizer/audit-library.py`: from `--release "Artist/Album"`, resolve the release's folders in both trees (including `Disc NN` subfolders) and its album rows in both beets DBs; verify with `--release "William Basinski/William Basinski - [2026] Passing the Cup of Sorrows"` printed as one release with 10 lossless and 3 lossy files.
- [x] 2.2 Add the Navidrome snapshot reader: read-only URI, Navidrome schema check, `--library-map` translation of `library.path`, and per-album track extraction; verify against a snapshot taken in task 3.2 that the Basinski release resolves to a single album and that a non-Navidrome SQLite file is rejected with the usage status.
- [x] 2.3 Implement the track-key reconciliation (`(disc, track)` with title as tie-breaker) across the five views, producing the `short` list and the findings vocabulary from design D3; verify that the Basinski release reports exactly 7 short tracks and 8 `ORPHAN_PATH` findings.
- [x] 2.4 Add the `--missing` inventory mode (count, per-path listing, `MASS_MISSING` above a configurable threshold) and make it tolerate the Navidrome CLI banner; verify against the live instance that it reports an empty set and exit status 0.
- [x] 2.5 Wire the CLI surface and statuses (`--release`, `--navidrome-db`, `--library-map`, `--missing`, `--json`, exits 0/1/2/3) without changing any existing check or default; verify with `--help`, a consistent release (exit 0), the Basinski run (exit 1) and an unknown release (exit 3), and confirm `openspec`-free operation with `python3 -m py_compile`.
- [x] 2.6 Add `library-organizer/docs/audit.md` covering the five views, the findings codes, the exit statuses and the two run locations (PVE host and LXC 101 container); verify every documented flag exists in `--help` output.

## 3. Removal — guarded decommission (`album-decommission`)

- [x] 3.1 Add `library-organizer/beets/rm_album.py`: resolve an album by id in one library, refuse ambiguous/unknown ids, require `--expect-album-id`, call `album.remove(delete=False)` and print the removed album and item ids; verify with a read-only `--check` run against both real databases that prints album 5506 / 10 items (lossless) and 4713 / 10 items (lossy) and changes nothing (compare `sha256sum` before and after).
- [x] 3.2 Add `library-organizer/server/navidrome-snapshot.sh`: `pct exec 111 -- navidrome backup create`, `pct pull` into `$OPS_DIR`, verify with `sqlite3 "pragma quick_check"` plus a `media_file` count, prune to two snapshots with `navidrome backup prune`; verify the produced file is readable, its `media_file` count is plausible and the second run leaves exactly two snapshots in `$OPS_DIR`.
- [x] 3.3 Add the missing-inventory capture and the purge gate (`baseline ∪ after ⊆ release ids`, banner-tolerant JSON parsing, and a refusal when the expected set is empty — otherwise the gate is vacuous and the library-wide purge would sweep every unrelated missing row); verify with two fixture inventories that a subset passes, an unrelated entry aborts with status 4, the live empty baseline passes, and an empty expected set refuses the purge instead of running it.
- [x] 3.4 Add the trash step: timestamped slug path, both trees, refusal when the destination exists; verify with `--dry-run` (prints both moves, nothing changes) and with a real run on a throwaway release (trash holds both folders, libraries do not, the doctor reports the release as gone).
- [x] 3.5 Add the targeted scan and gated purge: `pct exec 111 -- env ND_SCANNER_PURGEMISSING=always /usr/bin/navidrome -c /etc/navidrome/navidrome.toml scan -t 1:"<path>"` (the form `common.sh`'s `navidrome_cli()` builds), run only after a passing gate, followed by a re-read of the inventory; verify on the throwaway release that the missing set returns to its baseline and that the persistent configuration still reports `never`.
- [x] 3.6 Add `library-organizer/server/remove-album.sh` with the D11 stage order, `--release/--dry-run/--yes/--purge/--keep-trash`, per-stage progress and statuses 0/1/2/3/4; verify `--help`, that `--dry-run` on the Basinski release lists both album ids and both folder moves while leaving every store byte-identical, and that a failing stage stops the sequence with an accurate report.
- [x] 3.7 Add `library-organizer/docs/remove-album.md`: the runbook, the trash retention and manual pruning, the rollback for each store (trash move back, `library.db.prev`, `navidrome backup restore`) and the manual `DELETE /api/missing?id=` escape hatch; verify each command in the runbook exists in a script's `--help` or is a real path on the server.

## 4. Integration and deployment

- [ ] 4.1 Run the doctor and a removal dry run against the live stack from the PVE host with `MUSICBUCKET=/mnt/usb-hdd-wd-5tb/musicbucket`, and record the two reports in the change (they are the acceptance evidence for the retired risk).
- [ ] 4.2 Deploy: `git pull` in `/opt/alpargatify` on LXC 101 and place the host checkout at `/opt/alpargatify`; verify `python3 -m py_compile`, `bash -n` on every touched script, and that `remove-album.sh --help` and `audit-library.py --help` run from the host with no missing dependency.
- [ ] 4.3 End-to-end on a throwaway release: remove it, confirm the doctor reports all five views clean, confirm the missing set is back to baseline, then restore it from trash and confirm the doctor reports it consistent again.
- [ ] 4.4 Update `library-organizer/README.md` and the root `AGENTS.md`/`CLAUDE.md` note that the live Navidrome runs natively in LXC 111 from the `homeserver` repository, so `navidrome-orchestra/` is not the deployed stack; verify no document still presents the Docker config as live.
