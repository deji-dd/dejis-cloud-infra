# dejis-cloud-infra

Cloud infrastructure configuration and automated deployment pipeline for `dejis-cloud`.

## Overview

This repository manages containerized services running on the `dejis-cloud` instance, featuring:

- **PostgreSQL via IPC**: Runs `postgres:18` with TCP disabled (`listen_addresses=''`). All database communication occurs strictly over Unix Domain Sockets mounted at `/var/run/postgres-sockets` on the host.
- **Beszel Monitoring**: Runs `henrygd/beszel:latest` (central dashboard on port `8090`) and `henrygd/beszel-agent:latest` (lightweight host and Docker metrics agent connected via IPC Unix socket).
- **Keyless CI/CD Deployment**: Automated GitHub Actions workflow that connects via Tailscale OAuth and executes deployments over **Tailscale SSH** (no static private SSH keys).
- **Verified Cloudflare R2 Backups**: Daily automated backup that dumps PostgreSQL, verifies the uploaded archive by MD5 before it is promoted, then rotates it under a GFS scheme (7 daily / 4 weekly / 12 monthly) in R2. The legacy Tailscale-SSH-to-GCP path has been retired; R2 is the sole destination.

---

## Services in Docker Compose

All instance services run as separate, isolated containers orchestrated through a single [`docker-compose.yml`](file:///Users/mac/Documents/repos/dejis-cloud-infra/docker-compose.yml):

| Service | Image | Purpose | Network / Access |
| :--- | :--- | :--- | :--- |
| `postgres` | `postgres:18` | Primary database | IPC only via `/var/run/postgres-sockets` (TCP disabled) |
| `beszel` | `henrygd/beszel:latest` | Monitoring Web UI & Hub | Port `8090` |
| `beszel-agent` | `henrygd/beszel-agent:latest` | Metrics & Docker stats collector | `network_mode: host`, communicates with hub via IPC socket |

---

## PostgreSQL Tuning

The `postgres` service passes explicit `-c` flags rather than relying on image defaults (`shared_buffers=128MB`, `work_mem=4MB`, `maintenance_work_mem=64MB`), which are sized for a generic container.

| Setting | Default here | Why |
| :--- | :--- | :--- |
| `shared_buffers` | `512MB` | Image default (128MB) forces repeated scans of hot tables to disk. |
| `effective_cache_size` | `2GB` | Planner hint only — allocates nothing. Lets the planner prefer index scans over seq scans. |
| `work_mem` | `16MB` | The ledger reconciliation sweeps sort and hash-join `personal_logs`; 4MB spills to disk. |
| `maintenance_work_mem` | `128MB` | Speeds up `VACUUM` and `CREATE INDEX`. |
| `random_page_cost` | `1.1` | Storage is SSD; the default `4.0` assumes spinning rust and discourages index use. |
| `effective_io_concurrency` | `200` | SSD-appropriate read-ahead for bitmap heap scans. |

### Sizing these to the host

The defaults above assume a **~4GB instance**. Confirm with `free -h` on `dejis-cloud` and adjust in `.env` (picked up via `${VAR:-default}` — no compose edit needed):

```bash
POSTGRES_SHARED_BUFFERS=1GB          # ~25% of RAM
POSTGRES_EFFECTIVE_CACHE_SIZE=3GB    # ~50-75% of RAM
```

**Do not set `shared_buffers` above ~25% of host RAM.** The host also runs the three `sentinel-*` containers plus Beszel, and an oversized buffer pool will OOM the instance rather than speed it up.

After changing values:

```bash
docker compose up -d postgres        # recreate to apply
docker compose logs --tail=20 postgres
```

Verify the settings actually took effect:

```bash
docker exec postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  -c "SHOW shared_buffers;" -c "SHOW effective_cache_size;" -c "SHOW work_mem;"
```

---

## Beszel Monitoring Setup

1. **Deploy Containers**:
   Push to `main` or deploy locally. The `beszel` hub container will spin up on port `8090`.
2. **Create Admin Account**:
   Open `http://<dejis-cloud-ip-or-hostname>:8090` in your browser and register the initial admin account.
3. **Add System**:
   - Click **Add System** in the Beszel dashboard.
   - For **Host / IP**, enter `/beszel_socket/beszel.sock` (or your host IP).
   - Copy the generated **Public Key** (`ssh-ed25519 AAA...`).
4. **Configure Agent Key**:
   - Add the key to your `.env`:
     ```bash
     BESZEL_AGENT_KEY="ssh-ed25519 AAA..."
     ```
   - Sync the updated `.env` to the server:
     ```bash
     ./scripts/sync-env.sh
     ```
   - Run `docker compose up -d` on the server (or trigger CI/CD), and the agent will immediately begin reporting metrics and Docker stats.

---

## Repository Structure

```text
├── .github/workflows/
│   └── deploy.yml         # CI/CD deployment pipeline via Tailscale SSH
├── scripts/
│   ├── backup-to-r2.sh    # Cluster backup -> Cloudflare R2, MD5-verified, GFS rotation
│   └── sync-env.sh        # Secure local-to-server .env sync script
├── docker-compose.yml     # Multi-container service definitions (Postgres, Beszel)
└── .gitignore
```


