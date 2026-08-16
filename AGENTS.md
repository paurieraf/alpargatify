# AGENTS.md

Self-hosted music stack (Navidrome) split into three independent subprojects — no shared build system. Treat each folder as its own project. Deeper architecture docs: root `CLAUDE.md` and per-subproject `GEMINI.md` (navidrome-orchestra, library-organizer only — telegram-bot has none). Subproject READMEs are user-facing.

## navidrome-orchestra

- **Never run `docker compose` directly — always via `bootstrap.sh`.** It renders templates, generates secrets, computes PUID/PGID from `NAVIDROME_MUSIC_PATH`, and enables compose profiles.
- `cp .env.example .env` then `./bootstrap.sh` (`--prod` for HTTPS templates, `--down` to stop).
- Profiles: `monitoring`, `extra-storage`, `wud`, `picard`, `mdrm`, `dozzle` — each disableable with `--no-<name>`. All enabled by default.
- Template placeholders (`<domain>`, `<protocol>`, `<custom_metrics_path>`) are expanded **only** in `configs/Caddyfile` → `Caddyfile.custom` and `configs/prometheus.yml` → `prometheus.yml.custom`. Never envsubst into compose files. `*.custom`/`*.test` are gitignored build artifacts.
- Secrets never go in compose env (leaks via `docker inspect`): `bootstrap.sh` writes hashed passwords into `secrets/`; containers read them via `/run/secrets/` through custom `configs/entrypoints/*.sh` wrappers.
- `new-library.sh <user> <pass>` edits Navidrome's SQLite DB via `docker exec` and briefly stops FileBrowser to avoid DB locks.
- Adding a service: compose definition in the right file + profile + Caddy route + entrypoint wrapper (if passworded) + `--no-<name>` flag in bootstrap.sh.

## library-organizer

- **Never run `beet` on the host** (always via the one-shot Docker container) and **never convert into the live library** — always temp dir first, beets moves files in.
- `wrapper.sh [--dry-run] [--interactive] [--beets-config PATH] [--convert-only|--import-only|--order-only|--tag-only] <src> <abs_library_root>`
- `parallel-wrapper.sh --max-jobs N ...` passes all wrapper flags through.
- `sync-lossless.sh` — master sync pipeline against the SMB share. Full reference: `docs/sync-lossless.md`. Key invariants:
  - Docker on macOS cannot bind-mount SMB → beets runs against local staging `~/.alpargatify-staging` (wiped each run); results are `rsync`ed to `navidrome_library_flac/` (lossless) and `navidrome_library/` (lossy, the tree Navidrome serves). Override with `SMB_BASE`/`SMB_LOSSLESS`/`SMB_LOSSY`/`STAGING_BASE`.
  - Beets DBs (`library.db`, one per library) are round-tripped share → staging → share with SHA-256 fingerprints; pushed back only if changed, previous kept as `*.prev`.
  - Keep share paths in **NFC** — rsync from an APFS disk writes NFD and duplicates accented artist folders.
  - `--interactive` runs beets foreground/sequential with `beets-config-interactive.yaml` (needs a TTY).
- `beets/entrypoint.sh` has retry logic and multi-disc detection (`has_disc_subfolders`/`is_disc_folder`) — don't break it.
- New beets plugin: update `beets/Dockerfile` AND the `plugins` array in `beets-config.yaml`.

## telegram-bot

- Python 3.12, no framework. Run tests directly from `telegram-bot/`:
  - `python run_tests.py` — discovers `tests/test_*.py`
  - `python -m unittest tests.test_navidrome_client_unit` — single module
  - Integration tests auto-skip when `secrets/` files are missing.
- Credentials via Docker secrets (`secrets/*.txt`, gitignored); non-secret env in `docker-compose.yml`. `/login` works only in DMs (bot deletes the message after reading); authorization is group-based via `secrets/telegram_chat_id.txt`.
- `src/main.py` runs two daemon threads: scheduler (daily `SCHEDULE_TIME` + inactive-user purge) and bot polling — a single `TelegramBot` class handles both.

## Repo-wide conventions

- Bash: `set -euo pipefail`, shared `info`/`warn`/`err`/`debug` logging; honor `--dry-run`/`--verbose` everywhere.
- Cross-platform (dev on macOS, deploy on Linux): guard `stat -f` vs `stat -c`, `md5` vs `md5sum`, `openssl` vs `htpasswd`.
- Gitignored: `secrets/`, `*.env`, `*.custom`, `*.test`, `.agents/` (local skills; `skills-lock.json` tracks their versions), `telegram-bot/data/`.
- No CI configured. Commits use Conventional Commits style.
