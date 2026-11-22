# Design

## Context

See [proposal.md](proposal.md) for the problem statement and motivation.

Currently, the music ingestion pipeline (`frigopeuify` → `sync-lossless.sh` → `wrapper.sh` → `flac-to-lossy.sh`) serializes albums via `MAX_JOBS=1` because beets' SQLite database cannot handle concurrent writes without risking `PARTIAL IMPORT` (`Exit code: 4`). Inside `wrapper.sh`, however, `flac-to-lossy.sh` runs completely before Docker/beets starts and writes only to an isolated `TMP_DEST` directory (`mktemp -d`). Therefore, parallelizing individual track conversions inside `flac-to-lossy.sh` is completely decoupled from beets and safe to enable by default.

Key constraints from the repository:
- Cross-platform Bash: developed on macOS (Bash 3.2+ default, `sysctl -n hw.ncpu`) and deployed on Linux (Proxmox LXC 101, Bash 5.x, `nproc`).
- No extra runtime dependencies (`gnu parallel` is not guaranteed to be installed in LXC 101 or macOS).
- Zero `shellcheck` warnings and adherence to existing logging helpers (`info`, `warn`, `err`, `debug`).

## Goals / Non-Goals

**Goals:**
- Encode multiple FLAC tracks concurrently inside `flac-to-lossy.sh` up to `JOBS` workers (`-j`/`--jobs` or `CONVERT_JOBS`, auto-defaulting to detected CPU cores).
- Guarantee zero race conditions on destination directories, cover art, and temporary ReplayGain-stripped FLAC files.
- Preserve exact exit-code semantics (any failed track → exit `1`) so `wrapper.sh` and `sync-lossless.sh` continue to detect and record failed lossy albums accurately.
- Keep `MAX_JOBS=1` untouched at the album/beets layer.

**Non-Goals:**
- Changing album-level parallelism (`MAX_JOBS`) or beets SQLite locking.
- Modifying `frigopeuify` CLI flags (env var `CONVERT_JOBS` already passes through automatically, and the default auto-detection requires zero changes to `frigopeuify`).
- Rewriting `flac-to-lossy.sh` in Python or adding new binary dependencies like GNU `parallel`.

## Decisions

### 1. Bounded worker pool via Bash PID array (not `xargs -P` or GNU `parallel`)
- **Choice:** Use a portable PID-array worker pool in `process_all_files()` — tracking active background PIDs, reaping finished jobs with `wait "$pid"` to capture each worker's exact exit code, and throttling launches while `${#running_pids[@]} -ge JOBS`.
- **Rationale:**
  - Works identically on macOS Bash 3.2 and Linux Bash 5.x (unlike `wait -n`, which requires Bash 4.3+).
  - Matches the proven pattern already used in `library-organizer/parallel-wrapper.sh` and `sync-lossless.sh`.
  - Unlike `xargs -P`, subshells inherit all Bash functions (`process_flac_file`, `convert_to_lossy`, `strip_replaygain_to_temp`, `apply_metadata_to_m4a`, `ENCODE_ARGS`, logging helpers) without needing `export -f` or re-invoking the script.
  - No external dependency (unlike GNU `parallel`).
- **Important improvement over `parallel-wrapper.sh`:** When checking for finished PIDs, we MUST call `wait "$pid"` on each completed PID (and on all remaining PIDs after the loop) and increment `error_count` whenever `wait "$pid"` returns non-zero. Simply checking `kill -0` without `wait` would discard non-zero exit codes.

### 2. Job count resolution & precedence
- **Precedence:** CLI flag (`-j N` / `--jobs N`) > environment variable (`CONVERT_JOBS`) > auto-detected CPU count (`nproc` on Linux, `sysctl -n hw.ncpu` on macOS, fallback `4`).
- **Validation:** Must be a positive integer (`^[1-9][0-9]*$`). Invalid values exit `2` with usage message.
- **Why `CONVERT_JOBS` instead of `MAX_JOBS`:** `frigopeuify` and `sync-lossless.sh` explicitly export `MAX_JOBS=1` into the environment to serialize beets SQLite writes. If `flac-to-lossy.sh` read `MAX_JOBS`, it would silently inherit `1` and remain sequential! Using a distinct variable (`CONVERT_JOBS`) keeps album-level beets serialization and track-level encoder parallelism cleanly separated.

### 3. Pre-pass for destination directories and cover art
- **Choice:** Before launching parallel track workers in `process_all_files()`, collect the list of `.flac` files into an array, create destination directories, and run `copy_cover_art` once per unique source directory (sequentially, in the parent shell).
- **Rationale:**
  - `copy_cover_art` is a single fast `cp` per album/disc directory. Running it once upfront eliminates concurrent `cp` races on `cover.jpg` and avoids duplicate `Copying cover: cover.jpg` log lines.
  - Also avoids `mkdir -p` races and keeps `process_flac_file` purely per-track.
- **Note on Bash 3.2:** Since associative arrays (`declare -A`) don't exist in Bash 3.2, deduplicate unique source directories using a simple newline-delimited list or `sort -u` (or checking the last seen dir after sorting the file list). Sorting the discovered `.flac` paths also makes output order deterministic.

### 4. Temp file safety for ReplayGain stripping & CUE splitting
- `strip_replaygain_to_temp` already creates unique per-call temp files via `mktemp` — safe in parallel. However, note that on macOS vs Linux, `mktemp -t flac_norga_XXXXXX.flac` behaves differently when a suffix follows `XXXXXX` (BSD `mktemp` only replaces trailing `X`s!). We should verify/fix the `mktemp` template if needed or use `mktemp "${TMPDIR:-/tmp}/flac_norga_XXXXXX"` + `.flac` or a per-worker `mktemp -d` so two workers can never collide on a literal `XXXXXX.flac` filename!
  - **Crucial catch:** On Linux GNU `mktemp` and macOS BSD `mktemp`, `mktemp -t flac_norga_XXXXXX.flac` on macOS does NOT randomize `XXXXXX` when `.flac` follows it (or fails and falls back). Using a unique temp directory per call (`mktemp -d`) and placing `track.flac` inside it is 100% POSIX/macOS/Linux-safe and guarantees zero collisions under parallel execution.
- `split_with_xld` already uses `mktemp -d` per CUE image and cleans it up on return — safe in parallel.
- For `--dry-run`, running sequentially (even when `JOBS > 1`) keeps printed dry-run output deterministic and easy to read without interleaving.

### 5. `SIGINT` / `SIGTERM` cleanup
- Track active child PIDs in a script-level array and trap `INT`/`TERM` to terminate background workers cleanly so Ctrl-C doesn't leave orphaned `opusenc` processes running.

## Risks / Trade-offs

- **[Interleaved log lines during parallel runs]** → Acceptable for `info`/`debug` output; `opusenc` itself runs with `>/dev/null 2>&1`, so only concise `Converting:` / `-> OK` lines appear. Including the filename in the `-> OK` / `-> ERROR` line (e.g., `-> OK: <relpath>`) makes parallel logs unambiguous.
- **[High CPU / `/tmp` usage on hosts with many cores]** → Each concurrent ReplayGain-stripped temp FLAC holds ~30-50 MB in `/tmp` briefly (e.g. 4 jobs ≈ 150-200 MB). On constrained hosts, users can set `CONVERT_JOBS=2` (or `CONVERT_JOBS=1` to revert to sequential).
- **[`mktemp` suffix portability on macOS]** → Mitigated by using `mktemp -d` per stripped track and removing the temp dir in `convert_to_lossy` cleanup.

## Migration Plan

1. Implement and validate locally (`shellcheck`, unit/smoke tests with `--jobs 1`, `--jobs 4`, `--dry-run`, corrupt FLAC error handling).
2. Commit and push to `alpargatify`.
3. Pull on LXC 101 (`/opt/alpargatify`) — no changes required to `frigopeuify`, `sync-lossless.sh`, or `wrapper.sh`.
4. **Rollback:** Set `CONVERT_JOBS=1` in the environment (zero-code rollback) or `git revert`.
