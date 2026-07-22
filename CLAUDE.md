# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Self-hosted personal music streaming stack built around **Navidrome**. Three independent subprojects, each deployed via Docker Compose. No shared build system — treat each folder as its own project.

- `navidrome-orchestra/` — the production Navidrome stack: reverse proxy, monitoring, storage/file helpers, tagging tools. Deployed on a remote Ubuntu host.
- `library-organizer/` — bash + Docker pipeline that converts lossless FLAC to lossy (Opus/AAC) and imports into a beets-managed library.
- `telegram-bot/` — Python Telegram bot integrating with Navidrome's Subsonic API for scheduled notifications and interactive commands.

Each subproject has its own `README.md` (user-facing) and `GEMINI.md` (agent guidelines — same substance, follow it). Root `README.md` also carries a standalone Ubuntu server-bootstrap script for provisioning a fresh host.

## navidrome-orchestra

Multi-file Compose stack driven by one orchestration script — **do not run `docker compose` directly; use `bootstrap.sh`**.

```zsh
cd navidrome-orchestra
cp .env.example .env          # fill values first
./bootstrap.sh                # render templates + compose up -d (all profiles)
./bootstrap.sh --prod         # production: PROTOCOL=https for Caddy templates
./bootstrap.sh --down         # compose down
./bootstrap.sh --no-monitoring --no-wud   # disable profiles selectively
./new-library.sh <user> <pass>            # create isolated Navidrome + FileBrowser library
```

Profiles: `monitoring`, `extra-storage`, `wud`, `picard`, `mdrm`, `dozzle` — each disableable via `--no-<name>`. All enabled by default.

Architecture:
- Compose is **split by concern**: `-core` (Navidrome + `init-chown`), `-network` (Caddy), `-monitor` (Prometheus/Grafana/node-exporter), `-storage` (SFTP/Syncthing/FileBrowser), `-extratools` (WUD/Picard/Metadata Remote/Dozzle). `bootstrap.sh` runs every `docker-compose*.yml` in the folder combined.
- **Template rendering happens only in `bootstrap.sh`**, and only for `configs/Caddyfile` → `Caddyfile.custom` and `configs/prometheus.yml` → `prometheus.yml.custom`. Never inject variables into Compose files (no `envsubst` on them). Placeholders like `<domain>`, `<protocol>`, `<custom_metrics_path>` are expanded at runtime.
- **Secrets never touch Compose env** (would leak to `docker inspect`). `bootstrap.sh` hashes/copies passwords into `secrets/`; containers read them via `/run/secrets/` through custom `configs/entrypoints/*.sh` wrappers that inject env before calling the original entrypoint.
- `PUID`/`PGID` are computed from the owner of `NAVIDROME_MUSIC_PATH`; `init-chown` fixes volume ownership before Navidrome starts.
- Web UIs are routed by Caddy at `<service>.<domain>`. Services with no native auth (Picard, mdrm, Dozzle) sit behind Caddy Basic Auth (`CADDY_AUTH_USER`/`_PASSWORD`).
- `new-library.sh` manipulates Navidrome's SQLite DB (`/data/navidrome.db`) via `docker exec`, and temporarily stops FileBrowser to avoid DB lock during user creation.
- `fail2ban/` holds filters/jails that parse Caddy JSON logs — deployed to the host, not containerized.

When adding a service: define it in the right Compose file, assign a profile, add a Caddy route, add a `configs/entrypoints/` wrapper + secret generation in `bootstrap.sh` if it needs passwords, and a `--no-<name>` flag.

## library-organizer

Bash orchestrators that convert audio into a temp dir, then run a one-shot Dockerized **beets** container to import. **Never run `beet` on the host** — always route through the Docker pipeline. **Never convert into the live library** — always temp dir first (`mktemp -d`), then beets moves files.

```zsh
cd library-organizer
./wrapper.sh /path/to/raw_flacs /abs/path/to/library_root
./wrapper.sh --dry-run ...                     # keep temp output, skip import cleanup
./wrapper.sh --beets-config /abs/config.yaml ...
./parallel-wrapper.sh --max-jobs 2 /path/to/albums /abs/path/to/library_root   # batch per-subdir
```

- `flac-to-lossy.sh` — conversion engine. Default Opus 256kbps via `opusenc`/`ffmpeg`; AAC via macOS `afconvert`. CUE image splitting via `xld`. Encoder defaults in `DEFAULT_OPUS_ARGS`/`DEFAULT_AAC_ARGS`.
- `wrapper.sh` — single-album orchestrator (convert → beets container). Read this first to understand the pipeline.
- `parallel-wrapper.sh` — runs `wrapper.sh` per subdirectory in parallel; passes through all wrapper flags.
- `sync-lossless.sh` — master sync tailored to specific HDD paths (rsync + lossless organize + trigger lossy conversion).
- `beets/` — container: `Dockerfile`, `docker-compose.yml`, `entrypoint.sh`, `beets-config.yaml` (+ `beets-config-interactive.yaml`). `entrypoint.sh` has retry logic and multi-disc detection (`has_disc_subfolders`/`is_disc_folder`) that imports from the parent to group `Disc N`/`CD N` folders as one album — don't break this. Beets config uses `lastgenre`/`fetchart`/`musicbrainz` plus inline Python (e.g. `formatted_albumartist` transliteration). New plugins need both `beets/Dockerfile` and the `plugins` array in the config.

## telegram-bot

Python 3.12 bot, no framework build — run tests directly, deploy via Compose.

```zsh
cd telegram-bot
python run_tests.py            # discovers tests/test_*.py via unittest
python -m unittest tests.test_navidrome_client_unit   # single test module
docker-compose up -d           # deploy
```

- Entry `src/main.py` runs two daemon threads: a **scheduler** (daily notifications at `SCHEDULE_TIME` + inactive-user purge) and **bot polling** (interactive commands). Single `TelegramBot` class (`src/telegram_bot.py`) handles both.
- `src/navidrome_client.py` — Subsonic API client with incremental library caching; skips re-sync when Navidrome scan count/timestamp is unchanged.
- `src/credentials_db.py` — per-user Navidrome creds encrypted AES-256-GCM in local SQLite, used by `/recommend`. `/login` only works in DMs; the bot deletes the message after reading.
- `src/user_activity.py` — tracks activity for the purge job. `src/secrets_loader.py` reads Docker secrets.
- **Config is via Docker secrets** (files in `secrets/*.txt`, no env for credentials) plus non-secret env in `docker-compose.yml` (`SCHEDULE_TIME`, `TZ`, `NAVIDROME_MUSIC_FOLDER`, etc.). Authorization is group-based: bot only responds to chat IDs in `telegram_chat_id.txt`.
- Multi-stage Debian-slim Dockerfile; runs as `${UID}:${GID}` with `init-chown` fixing `./data` ownership.

## Conventions

- Bash scripts use `set -euo pipefail` and shared `info`/`warn`/`err`/`debug` logging functions. Honor `--dry-run` and `--verbose` everywhere.
- Cross-platform matters (dev on macOS, deploy on Linux): guard `stat -f` vs `stat -c`, `md5` vs `md5sum`, `openssl` vs `htpasswd`.
