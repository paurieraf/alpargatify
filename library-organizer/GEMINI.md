# Library Organizer - Instructions for Gemini

This directory contains the `library-organizer` pipeline, which converts lossless music (FLAC) into lossy formats (Opus/AAC) and automatically imports them into a beets-managed library using Docker.

## Project Structure & Architecture

*   **Converters**: `flac-to-lossy.sh` is the underlying engine for audio conversion. It expects `opusenc` (default) or `afconvert` (macOS only) and handles CUE splitting via `xld`.
*   **Orchestrators**:
    *   `wrapper.sh`: The single-album orchestrator. It converts files into a temporary directory and then spins up a Docker container to run `beets` for the import step.
    *   `parallel-wrapper.sh`: The batch orchestrator. Executes `wrapper.sh` in parallel for each subdirectory.
    *   `sync-lossless.sh`: The master synchronization script tailored to specific HDD paths. It handles lossless organization, syncing via `rsync`, and triggering the lossy conversion. The lossy library mirrors the FLAC one: Opus copies are imported as-is (`wrapper.sh --as-is`, no second autotag), failures are listed in `navidrome_inbox_failed/lossy-missing-<date>.list` and redone with `--lossy-only <list>`.
*   **Audit**: `audit-library.py` (on the server `server/audit.sh`) checks, read-only, both beets DBs against the files on disk and the FLAC↔Opus mirror.
*   **Beets Container (`beets/`)**: Beets is run exclusively via Docker to ensure dependency consistency.
    *   `beets-config.yaml`: The core beets configuration. Uses plugins like `lastgenre`, `fetchart`, `musicbrainz`, and custom inline Python scripts (e.g., `formatted_albumartist` for non-Latin character transliteration).
    *   `entrypoint.sh`: Executes the `beet import` command. It features custom retry logic, robust output logging, and specialized multi-disc folder detection to group discs into a single album correctly.

## Development Guidelines

When modifying files in this module, adhere to the following rules:

1.  **Scripting Standards**:
    *   Use `set -euo pipefail` for bash scripts.
    *   Ensure logging uses the established `info`, `warn`, `err`, `debug` functions.
    *   Support and honor the `--dry-run` and `--verbose` flags across all scripts.
2.  **Idempotency & Safety**: 
    *   The conversion step (`flac-to-lossy.sh`) gracefully skips existing files unless explicitly forced. 
    *   The import step (`beets`) handles duplicates safely based on the config.
3.  **Atomic Workflows**: Never convert directly into the live library. Always convert to a temporary directory (`mktemp -d`), then use the `beets` container to move the files into their final destination.
    *   Loops over albums must survive a failed album: `sync-lossless.sh` runs under `set -e`, which subshells inherit, so guard each `wrapper.sh` call with `||` and record the failure instead of letting it abort the batch.
    *   Keep the Opus side as-is: tags come from the FLAC, never from a second autotag, or the two libraries drift apart.
4.  **Containerization**: Any changes to `beets` plugins or dependencies must be reflected in `beets/Dockerfile`. Do not attempt to run `beet` commands natively on the host; always route them through the Docker pipeline.
5.  **Multi-disc Handling**: Be aware that albums might be split into `Disc N` or `CD N` subfolders. `beets/entrypoint.sh` relies on `has_disc_subfolders` and `is_disc_folder` to detect these and import from the parent directory to group the discs properly. Avoid breaking this logic.

## Common Tasks

*   **Updating Beets Config**: Modify `beets/beets-config.yaml` (or `beets/beets-config-interactive.yaml`). Pay attention to custom Python inline fields.
*   **Modifying Encoder Settings**: Update `DEFAULT_OPUS_ARGS` or `DEFAULT_AAC_ARGS` inside `flac-to-lossy.sh`.
*   **Updating Dependencies**: If the user needs a new beets plugin requiring native packages, update `beets/Dockerfile` and the `plugins` array in `beets-config.yaml`.