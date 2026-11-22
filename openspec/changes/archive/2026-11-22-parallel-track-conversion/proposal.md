# Proposal

## Why

The lossy conversion step (`library-organizer/flac-to-lossy.sh`) currently converts FLAC tracks strictly one at a time using single-threaded `opusenc` (or `afconvert`). Because `sync-lossless.sh` and `frigopeuify` intentionally enforce `MAX_JOBS=1` at the album level to avoid concurrent writes to beets' SQLite database, multi-core hosts sit mostly idle during Opus conversion, turning multi-album or large-album imports into a slow single-core bottleneck.

## What Changes

- Add bounded per-track parallel conversion to `library-organizer/flac-to-lossy.sh`, controlled by a new `-j` / `--jobs N` CLI flag and `CONVERT_JOBS` environment variable, defaulting to the host's detected CPU core count (with a safe fallback of `4`).
- Decouple cover art copying (`copy_cover_art`) from per-track workers so each unique source directory's cover art is copied once without concurrent write races.
- Track worker exit statuses accurately across parallel background jobs so any track conversion failure still causes `flac-to-lossy.sh` to exit non-zero (preserving downstream failure detection in `wrapper.sh` and `sync-lossless.sh`).
- Ensure `--dry-run`, `--split-only`, CUE-based splitting (`split_with_xld`), and ReplayGain temp-file cleanup work safely under parallel execution without temp-file collisions or interleaved half-lines corrupting error tracking.
- Document `CONVERT_JOBS` / `--jobs` in `flac-to-lossy.sh` usage help and `library-organizer` docs; keep `MAX_JOBS=1` untouched so beets SQLite imports remain strictly serialized.

## Capabilities

### New Capabilities
- `lossy-audio-conversion`: Bounded parallel FLAC-to-lossy track conversion with race-free cover art copying, accurate failure aggregation, and cross-platform concurrency configuration (`--jobs` / `CONVERT_JOBS`).

### Modified Capabilities
<!-- None: existing capabilities (album-decommission, library-doctor) are unaffected. -->

## Impact

- **Modified files (in `alpargatify`):**
  - `library-organizer/flac-to-lossy.sh` — CLI parsing (`-j`/`--jobs`), CPU core auto-detection, directory-level cover art copy, bounded parallel worker pool, exit-status aggregation, and `print_settings` / `usage` output.
  - `library-organizer/README.md` and/or `library-organizer/docs/sync-lossless.md` — document `CONVERT_JOBS` / `--jobs` and clarify the separation between album-level `MAX_JOBS` (beets SQLite serialization) and track-level `CONVERT_JOBS` (encoder parallelism).
- **Downstream callers (`wrapper.sh`, `sync-lossless.sh`, `frigopeuify`):** No breaking changes; `wrapper.sh` already converts into an isolated temp directory before running beets, so existing callers automatically gain parallel track encoding while keeping beets imports serialized, and can optionally override concurrency via `CONVERT_JOBS`.
- **Cross-platform compatibility:** Must work on both Linux (Proxmox LXC 101, Bash 5.x, `nproc`) and macOS (dev host, Bash 3.2+, `sysctl -n hw.ncpu`) with zero `shellcheck` warnings.
