# dejis-cloud-infra

Cloud infrastructure configuration and automated deployment pipeline for `dejis-cloud`.

## Overview

This repository manages containerized services running on the `dejis-cloud` instance, featuring:

- **PostgreSQL via IPC**: Runs `postgres:latest` with TCP disabled (`listen_addresses=''`). All database communication occurs strictly over Unix Domain Sockets mounted at `/var/run/postgres-sockets` on the host.
- **Keyless CI/CD Deployment**: Automated GitHub Actions workflow that connects via Tailscale OAuth and executes deployments over **Tailscale SSH** (no static private SSH keys).
- **Zero-Disk Backup Streaming**: Daily automated backup script that dumps PostgreSQL, compresses the stream on the fly, and pipes it directly over Tailscale SSH to a secondary GCP instance without consuming local storage on `dejis-cloud`.

---

## Repository Structure

```text
├── .github/workflows/
│   └── deploy.yml         # CI/CD deployment pipeline via Tailscale SSH
├── scripts/
│   └── backup-to-gcp.sh   # Direct-to-GCP database backup streaming script
├── docker-compose.yml     # PostgreSQL service definition (IPC-only)
├── .env.example           # Environment template
└── .gitignore
```
