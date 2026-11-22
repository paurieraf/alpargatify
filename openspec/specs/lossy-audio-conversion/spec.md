# lossy-audio-conversion Specification

## Purpose

Converts lossless FLAC audio directories into lossy formats (Opus or AAC) with bounded per-track concurrency while preserving directory structure, cover art, ReplayGain stripping, CUE-sheet splitting, and accurate failure reporting.

## Requirements

### Requirement: Bounded parallel track conversion
The converter SHALL process multiple FLAC tracks concurrently up to a configured job limit, defaulting to the host's detected CPU core count (falling back to `4` if CPU count cannot be detected).

#### Scenario: Default concurrency uses detected CPU cores
- **WHEN** the converter is invoked without `--jobs`, `-j`, or `CONVERT_JOBS`
- **THEN** it detects the available CPU core count, logs the effective job count in the settings summary, and runs at most that many track conversions concurrently

#### Scenario: Explicit job count via CLI flag
- **WHEN** the converter is invoked with `-j 2` or `--jobs 2`
- **THEN** it runs at most 2 track conversions concurrently, overriding any `CONVERT_JOBS` environment variable

#### Scenario: Explicit job count via environment variable
- **WHEN** `CONVERT_JOBS=3` is set in the environment and neither `-j` nor `--jobs` is passed
- **THEN** the converter runs at most 3 track conversions concurrently

#### Scenario: Sequential fallback with jobs set to 1
- **WHEN** the converter is invoked with `--jobs 1` or `CONVERT_JOBS=1`
- **THEN** it converts tracks one at a time in sequence

#### Scenario: Invalid job count is rejected
- **WHEN** the converter is invoked with `--jobs 0`, `--jobs -2`, `--jobs abc`, or `CONVERT_JOBS=invalid`
- **THEN** it reports an error to stderr, prints usage help, and exits with status `2` without starting any conversion

### Requirement: Race-free cover art copying
The converter SHALL copy cover art at most once per unique source directory containing FLAC files, without concurrent writes to the same destination image file.

#### Scenario: Multi-track album with cover image
- **WHEN** a directory contains 12 FLAC tracks and a `cover.jpg` and is converted with `--jobs 4`
- **THEN** `cover.jpg` is copied once to the destination directory without race conditions or duplicate copy attempts

#### Scenario: Cover art disabled
- **WHEN** the converter is invoked with `--no-cover` (or `COPY_COVERS=no`)
- **THEN** no cover art files are copied

### Requirement: Accurate failure aggregation across parallel workers
The converter SHALL collect the exit status of every track worker and exit with a non-zero status if one or more tracks fail to convert, while allowing remaining tracks in the batch to finish and cleaning up any partial output or temporary ReplayGain files.

#### Scenario: Single track fails in a parallel batch
- **WHEN** one FLAC file in a multi-track album is corrupt and fails encoding while other tracks succeed under `--jobs 4`
- **THEN** the partial output file and any temporary stripped FLAC for the failed track are removed, the remaining tracks complete normally, and the converter exits with status `1`

#### Scenario: All tracks succeed in a parallel batch
- **WHEN** every FLAC file in the source tree converts without error under `--jobs 4`
- **THEN** all expected output files exist in the destination tree and the converter exits with status `0`

### Requirement: Dry-run and split-only compatibility
The converter SHALL honor `--dry-run` and `--split-only` cleanly regardless of the configured job count.

#### Scenario: Dry-run with parallel jobs configured
- **WHEN** the converter is invoked with `--dry-run --jobs 4`
- **THEN** it prints the planned commands without modifying files, creating temp files, or failing

#### Scenario: CUE-sheet image splitting under parallel mode
- **WHEN** a source directory contains a single-file FLAC image with a matching `.cue` sheet and XLD is available
- **THEN** the image is split into individual tracks in an isolated temporary directory, converted (or copied under `--split-only`) without colliding with other workers, and the temporary directory is removed on completion
