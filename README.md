# dejis-cloud-infra

Cloud infrastructure configuration and automated deployment pipeline for `dejis-cloud`.

## Overview

This repository manages containerized services running on the `dejis-cloud` instance, featuring:

- **PostgreSQL via IPC**: Runs `postgres:18` with TCP disabled (`listen_addresses=''`). All database communication occurs strictly over Unix Domain Sockets mounted at `/var/run/postgres-sockets` on the host.
- **Beszel Monitoring**: Runs `henrygd/beszel:latest` (central dashboard on port `8090`) and `henrygd/beszel-agent:latest` (lightweight host and Docker metrics agent connected via IPC Unix socket).
- **Keyless CI/CD Deployment**: Automated GitHub Actions workflow that connects via Tailscale OAuth and executes deployments over **Tailscale SSH** (no static private SSH keys).
- **Zero-Disk Backup Streaming**: Daily automated backup script that dumps PostgreSQL, compresses the stream on the fly, and pipes it directly over Tailscale SSH to a secondary GCP instance without consuming local storage on `dejis-cloud`.

---

## Services in Docker Compose

All instance services run as separate, isolated containers orchestrated through a single [`docker-compose.yml`](file:///Users/mac/Documents/repos/dejis-cloud-infra/docker-compose.yml):

| Service | Image | Purpose | Network / Access |
| :--- | :--- | :--- | :--- |
| `postgres` | `postgres:18` | Primary database | IPC only via `/var/run/postgres-sockets` (TCP disabled) |
| `beszel` | `henrygd/beszel:latest` | Monitoring Web UI & Hub | Port `8090` |
| `beszel-agent` | `henrygd/beszel-agent:latest` | Metrics & Docker stats collector | `network_mode: host`, communicates with hub via IPC socket |

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
│   ├── backup-to-gcp.sh   # Direct-to-GCP database backup streaming script
│   └── sync-env.sh        # Secure local-to-server .env sync script
├── docker-compose.yml     # Multi-container service definitions (Postgres, Beszel)
└── .gitignore
```


