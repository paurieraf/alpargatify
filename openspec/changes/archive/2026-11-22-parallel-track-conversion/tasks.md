# Tasks

## 1. Concurrency configuration and CLI parsing (`flac-to-lossy.sh`)

- [x] 1.1 Add `detect_cpu_cores()` helper (`nproc` → `sysctl -n hw.ncpu` → `4`), `-j` / `--jobs N` flag parsing, `CONVERT_JOBS` environment variable support (with CLI precedence over env), positive-integer validation (exit `2` on invalid values), and display `Jobs` in `print_settings()` and `usage()`. Verify with `--help`, `--dry-run --jobs 2`, `CONVERT_JOBS=3 --dry-run`, and invalid values (`--jobs 0`, `--jobs abc`, `CONVERT_JOBS=0`) confirming exit code `2` on invalid inputs.

## 2. Parallel-safe temp handling and directory pre-pass (`flac-to-lossy.sh`)

- [x] 2.1 Refactor `strip_replaygain_to_temp()` to create an isolated temp directory per call (`mktemp -d`) holding the stripped `.flac` copy and update `convert_to_lossy()` cleanup to remove that temp directory on both success and failure, eliminating macOS/Linux `mktemp` suffix collisions. Verify with `bash -n` and `shellcheck` (0 warnings) plus a smoke run confirming no leftover temp directories in `/tmp`.
- [x] 2.2 Decouple destination directory creation (`mkdir -p`) and `copy_cover_art()` from `process_flac_file()` into a sequential pre-pass over unique source directories in `process_all_files()` (Bash 3.2-compatible deduplication, no `declare -A`). Verify with a multi-track test directory containing `cover.jpg` under `--jobs 4` that `Copying cover:` appears once and `cover.jpg` is copied cleanly.

## 3. Bounded parallel worker pool and failure aggregation (`flac-to-lossy.sh`)

- [x] 3.1 Implement the bounded PID-array worker pool in `process_all_files()` (running sequentially when `JOBS=1` or `DRY_RUN=yes`), reaping completed PIDs with `wait "$pid"` to count non-zero exits accurately, adding filename context to `-> OK` / `-> ERROR` log lines, and registering a `SIGINT`/`SIGTERM` trap to kill active child workers cleanly. Verify with a multi-track FLAC smoke test (e.g. 4+ valid FLACs under `--jobs 4`) confirming concurrent encoding, all `.opus` outputs created, and exit code `0`, plus a batch containing 1 corrupt `.flac` confirming partial output cleanup, completion of valid tracks, and exit code `1`.

## 4. Documentation and end-to-end validation

- [x] 4.1 Document `-j` / `--jobs` and `CONVERT_JOBS` (including how it complements album-level `MAX_JOBS=1` for beets SQLite safety) in `library-organizer/README.md` and `library-organizer/docs/sync-lossless.md`, and verify `shellcheck library-organizer/flac-to-lossy.sh` passes with 0 warnings and `bash -n library-organizer/flac-to-lossy.sh` succeeds.
