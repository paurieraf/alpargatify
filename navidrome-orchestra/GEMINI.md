# Navidrome Orchestra - Instructions for Gemini

This directory contains `navidrome-orchestra`, a lightweight orchestration and observability stack to run a single-host Navidrome music server alongside optional microservices for management, monitoring, and storage.

## Project Structure & Architecture

*   **Core Scripts**:
    *   `bootstrap.sh`: The main deployment script. It validates and reads `.env` variables, creates Docker secrets, renders templates (`Caddyfile`, `prometheus.yml`), computes host PUID/PGID to match volumes, and runs `docker compose` up with dynamically enabled profiles.
    *   `new-library.sh`: An administrative script to create an isolated library directory (`/extra-libraries/<username>`), link it to a pre-existing Navidrome user directly via SQLite queries (`navidrome.db`), and create/update a FileBrowser user restricted to that specific path.
*   **Docker Compose Files**:
    *   `docker-compose-core.yml`: Runs **Navidrome** and an `init-chown` alpine container that ensures volume permissions match `PUID`:`PGID` before the server starts.
    *   `docker-compose-network.yml`: Runs **Caddy** as a reverse proxy, mapping all domains, managing TLS, and applying Basic Auth where necessary.
    *   `docker-compose-monitor.yml`: Observability stack: **Prometheus**, **Grafana**, and **node-exporter** (profile: `monitoring`).
    *   `docker-compose-storage.yml`: File access stack: **SFTP**, **Syncthing**, and **FileBrowser** (profile: `extra-storage`).
    *   `docker-compose-extratools.yml`: Extra tools: **WUD** (What's Up Docker), **MusicBrainz Picard**, **Metadata Remote**, and **Dozzle** (profiles: `wud`, `picard`, `mdrm`, `dozzle`).
*   **Configurations (`configs/`)**: Contains `Caddyfile`, Prometheus config, Navidrome `toml`, and Grafana provisioning. *Note:* `Caddyfile` and `prometheus.yml` use template variables (e.g., `<domain>`, `<custom_metrics_path>`) which are expanded by `bootstrap.sh` at runtime.
*   **Entrypoints (`configs/entrypoints/`)**: Crucial custom entrypoint scripts (`.sh`) for containers. They read values from `/run/secrets/` and inject them as environment variables before executing the original container entrypoints.
*   **Fail2Ban (`fail2ban/`)**: Filter and jail configurations to block IPs with repeated authentication failures on Caddy (affecting tools behind basic auth + Navidrome's API) and SFTP.

## Development Guidelines

When modifying files in this module, adhere to the following rules:

1.  **Scripting Standards**:
    *   Scripts must use `set -euo pipefail` to ensure fail-fast behavior.
    *   Use the existing logging functions (`info`, `warn`, `err`).
    *   Handle cross-platform compatibility gracefully (e.g., macOS `stat -f` vs Linux `stat -c`, BSD `md5` vs GNU `md5sum`, `openssl` vs `htpasswd`).
2.  **Secrets Management & Security**:
    *   **Never leak secrets to `docker inspect`**. Passwords from `.env` are hashed or copied to the local `secrets/` directory by `bootstrap.sh`. 
    *   Containers MUST read passwords through Docker secrets (`/run/secrets/`) via their custom `configs/entrypoints/*.sh` scripts to avoid leaking credentials in compose environment variables.
3.  **Template Expansion**:
    *   Do not inject variables directly into Docker Compose files using tools like `envsubst`. Variables are exclusively substituted in `configs/Caddyfile` and `configs/prometheus.yml` by `bootstrap.sh`.
4.  **Database Manipulation (`new-library.sh`)**:
    *   When adding or modifying scripts that interact with the Navidrome SQLite database (`/data/navidrome.db`), use `docker exec` and capture/manage errors correctly.
    *   Ensure file locks are handled. For FileBrowser, the container is temporarily stopped to update the local database safely.
5.  **Profiles and Modularity**:
    *   Respect the Docker Compose `profiles` design. Any new service should be tied to a specific profile unless it's a mandatory core component. Modify `bootstrap.sh` to allow disabling that profile (e.g., `--no-new-service`).

## Common Tasks

*   **Adding a new service**: 
    1. Create its definition in the appropriate `docker-compose-*.yml` file. 
    2. Assign it a profile.
    3. If it requires a web UI, add a reverse proxy route in `configs/Caddyfile` (using `<protocol>://<service>.<domain>`).
    4. If it requires passwords, create a custom entrypoint in `configs/entrypoints/` that reads from `/run/secrets/`, mount it in the compose file, and update `bootstrap.sh` to generate the corresponding secret file.
*   **Modifying Auth**: Caddy and WUD Basic Auth hashes are generated directly in `bootstrap.sh` using `docker run caddy hash-password`, `openssl`, or `htpasswd`.
*   **Modifying Metrics**: Prometheus scrape configs go in `configs/prometheus.yml` using placeholders for custom, randomized metrics paths. Dashboards are stored in `grafana-dashboards/`.