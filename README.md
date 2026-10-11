<div align="center">

# PasarGuard Scripts

**Modern deployment, orchestration, and disaster recovery suite for PasarGuard Panel and Nodes.**

[![Unit Tests](https://github.com/Free-Guy-IR/scripts/actions/workflows/command-tests.yml/badge.svg)](https://github.com/Free-Guy-IR/scripts/actions/workflows/command-tests.yml)
[![Backup Restore Tests](https://github.com/Free-Guy-IR/scripts/actions/workflows/backup-restore.yml/badge.svg)](https://github.com/Free-Guy-IR/scripts/actions/workflows/backup-restore.yml)
[![Script Safety](https://github.com/Free-Guy-IR/scripts/actions/workflows/script-update-safety.yml/badge.svg)](https://github.com/Free-Guy-IR/scripts/actions/workflows/script-update-safety.yml)
[![License](https://img.shields.io/github/license/Free-Guy-IR/scripts)](LICENSE)
[![Release](https://img.shields.io/github/v/release/Free-Guy-IR/scripts)](https://github.com/Free-Guy-IR/scripts/releases)

[English](README.md) • [راهنمای فارسی (Standalone)](iran-sanction/README-pasarguard-standalone.fa.md) • [راهنمای فارسی نود (Standalone)](iran-sanction/README-pg-node-standalone.fa.md)

</div>

---

## 📑 Table of Contents
- [Overview](#-overview)
- [Architecture](#-architecture)
- [System Requirements & OS Support](#-system-requirements--os-support)
- [Quick Start](#-quick-start)
  - [1. Installing PasarGuard Panel](#1-installing-pasarguard-panel)
  - [2. Installing a Worker Node](#2-installing-a-worker-node)
- [Installation Options](#-installation-options)
- [Master CLI Reference](#-master-cli-reference)
  - [Panel Commands (`pasarguard`)](#panel-commands-pasarguard)
  - [Node Commands (`pg-node`)](#node-commands-pg-node)
- [Database Support Matrix](#-database-support-matrix)
- [Backups & Disaster Recovery](#-backups--disaster-recovery)
- [SSL & TLS Security](#-ssl--tls-security)
- [Domestic Mirrors & Air-Gapped Networks](#-domestic-mirrors--air-gapped-networks)
- [Documentation Index](#-documentation-index)
- [Contributing & Testing](#-contributing--testing)

---

## 🌟 Overview

**PasarGuard Scripts** provides battle-tested automation for deploying and maintaining production-grade PasarGuard infrastructure:
- **PasarGuard Panel (`pasarguard.sh` / `pasarguard`)**: Orchestrates the web dashboard, database engines (SQLite, MySQL, MariaDB, PostgreSQL, TimescaleDB), native async connection pooling, admin web UIs (pgAdmin, phpMyAdmin), and disaster recovery.
- **PasarGuard Node (`pg-node.sh` / `pg-node`)**: Manages remote worker nodes, systemd background daemons (`pg-node-service`), Xray-core versions, routing geofiles, and TLS certificates.
- **Disaster Recovery**: Automated recurring backups to Telegram with proxy support, multi-database cluster snapshots, and fail-closed TimescaleDB version compatibility gates.
- **Domestic Mirror Optimization**: Benchmark and apply domestic Iranian mirrors for APT and Docker when deploying behind restricted network environments.

---

## 🏗️ Architecture

```
                               ┌─────────────────────────────────────────┐
                               │             PasarGuard Panel            │
                               │   (Web Dashboard & Background Tasks)    │
                               └──────┬──────────────────────┬───────────┘
                                      │                      │
                    ┌──────────────────┴────────┐      ┌──────┴────────────────────┐
                   ▼                           ▼      ▼                           ▼
          ┌─────────────────┐         ┌────────────────────┐            ┌───────────────────┐
          │  SQLite / MySQL │         │     PgBouncer      │            │ Automated Backup  │
          │    / MariaDB    │         │  (Port 6432 Pool)  │            │  (Telegram + Cron)│
          └─────────────────┘         └────────┬───────────┘            └───────────────────┘
                                               │
                                      ┌────────┴───────────┐
                                      │ PostgreSQL 17 /    │
                                      │   TimescaleDB      │
                                      └────────────────────┘
                                               ▲
                                               │ (Encrypted gRPC / REST)
                   ┌───────────────────────────┴───────────────────────────┐
                   ▼                                                       ▼
        ┌─────────────────────┐                                 ┌─────────────────────┐
        │  Worker Node: EU-1  │                                 │  Worker Node: AS-1  │
        │  (pg-node + Xray)   │                                 │  (pg-node + Xray)   │
        └─────────────────────┘                                 └─────────────────────┘
```

---

## 🖥️ System Requirements & OS Support

| Operating System | Package Manager | Status |
| :--- | :--- | :--- |
| **Ubuntu 20.04 / 22.04 / 24.04** | `apt-get` | Supported (Primary) |
| **Debian 11 / 12** | `apt-get` | Supported |
| **CentOS / RHEL 8+** | `dnf` / `yum` | Supported |
| **Rocky Linux / AlmaLinux 8+** | `dnf` | Supported |
| **Fedora 38+** | `dnf` | Supported |
| **Arch Linux** | `pacman` | Supported |
| **openSUSE Leap / Tumbleweed** | `zypper` | Supported |

**Prerequisites**:
- Linux x86_64 or ARM64
- Root or `sudo` privileges
- Docker and Docker Compose (automatically installed if absent)
- `curl`, `tar`, `gzip`

---

## 🚀 Quick Start

### 1. Installing PasarGuard Panel

Download and inspect the installer on your server (or pin to an immutable release tag):

```bash
# Download installer script
curl -fsSL https://raw.githubusercontent.com/Free-Guy-IR/scripts/main/pasarguard.sh -o pasarguard.sh

# Default install (SQLite, interactive SSL)
sudo bash pasarguard.sh install

# High-concurrency production install (TimescaleDB + PgBouncer)
sudo bash pasarguard.sh install --database timescaledb --pre-release
```

*(Tip: In production environments, review the script or pin to a specific release tag, e.g. `https://raw.githubusercontent.com/Free-Guy-IR/scripts/<tag>/pasarguard.sh`).*

Once installed, control the panel at any time using the global `pasarguard` command:
```bash
sudo pasarguard status
```

---

### 2. Installing a Worker Node

On each remote worker node, download and execute the node installer:

```bash
# Download node installer script
curl -fsSL https://raw.githubusercontent.com/Free-Guy-IR/scripts/main/pg-node.sh -o pg-node.sh

# Standard node installation
sudo bash pg-node.sh install

# Multi-instance node with custom name
sudo bash pg-node.sh install --name node-de1 --self-signed
```

Once installed, manage the node using the global `pg-node` command:
```bash
sudo pg-node status
```

---

## 🔧 Installation Options

The following flags can be supplied to `pasarguard install`:

| Option | Values | Description |
| :--- | :--- | :--- |
| `--database` | `sqlite`, `mysql`, `mariadb`, `postgresql`, `timescaledb` | Database backend engine. Default is `sqlite`. *(PostgreSQL and TimescaleDB require v1.0.0+)* |
| `--sub-template [LANG]` | `fa`, `en`, `ru`, `zh` | Also install the PasarGuard subscription page. Default `fa`. Without it the installer asks. |
| `--version <TAG>` | e.g. `v0.5.2`, `v1.0.0-beta.1` | Pin the installation to an explicit release version tag. |
| `--dev` | *(flag)* | Install latest development image *(v0.x releases only)*. |
| `--pre-release` | *(flag)* | Install latest pre-release image *(v1.0.0 and later)*. |
| `--ssl` | *(flag)* | Launch interactive SSL certificate configuration wizard during setup. |
| `--no-ssl` | *(flag)* | Skip SSL setup (panel binds to localhost for reverse proxy fronting). |
| `--ssl-domain <DOMAIN>` | e.g. `panel.example.com` | Automatically issue a Let's Encrypt SSL certificate for the domain. |
| `--ssl-http-port <PORT>` | e.g. `80` | Port used to verify ACME HTTP-01 challenge. Default: `80`. |

---

## ⌨️ Master CLI Reference

### Panel Commands (`pasarguard`)

| Command | Description |
| :--- | :--- |
| `pasarguard install` | Full panel setup wizard with database and SSL selection. |
| `pasarguard install-script` | Installs global `pasarguard` CLI command and shared libraries to system. |
| `pasarguard install-node` | Shortcut to download and launch the node installer. |
| `pasarguard up` | Starts all containers in the stack (`docker compose up -d`). |
| `pasarguard down` | Stops and tears down stack containers. |
| `pasarguard restart` | Restarts all containers and prompts to tail logs. |
| `pasarguard status` | Real-time container health, port mappings, and database status. |
| `pasarguard logs` | Live log streaming for all stack containers. |
| `pasarguard cli` | Launches interactive CLI session inside the panel container. |
| `pasarguard tui` | Opens curses-based Terminal User Interface (TUI). |
| `pasarguard backup` | Immediate manual backup of database, configuration, and state. |
| `pasarguard backup-service` | Configures automated recurring Telegram backups and cron schedule. |
| `pasarguard restore` | Restores panel state and database with pre-restore validation and version compatibility gates. |
| `pasarguard update` | Pulls latest Docker images and recreates containers cleanly. |
| `pasarguard uninstall` | Removes containers, services, and optional application data directories. |
| `pasarguard edit` | Opens `/opt/pasarguard/docker-compose.yml` in default editor. |
| `pasarguard edit-env` | Opens `/opt/pasarguard/.env` in default editor. |
| `pasarguard completion` | Installs Bash/Zsh tab-completion scripts. |
| `pasarguard version-script` | Shows current script version and active Git commit SHA. |
| `pasarguard help` | Displays quick reference help banner. |

👉 *For an exhaustive breakdown of panel commands and options, see [docs/cli-reference.md](docs/cli-reference.md).*

---

### Node Commands (`pg-node`)

| Command | Description |
| :--- | :--- |
| `pg-node install` | Installs or reinstalls the worker node container and service. |
| `pg-node up` / `down` / `restart` | Controls the node container stack lifecycle. |
| `pg-node status` | Displays IP, active service port, certificate path, and Xray version. |
| `pg-node logs` | Streams live logs from the node container. |
| `pg-node core-update` | Updates or switches the installed Xray-core binary version. |
| `pg-node geofiles` | Downloads official `geoip.dat` and `geosite.dat` routing assets. |
| `pg-node renew-cert` | Regenerates self-signed TLS certificates with SAN entries. |
| `pg-node l2tp-enable` | Enables IP forwarding, loads the TUN and PPP/L2TP kernel modules, maps `/dev/net/tun` and `/dev/ppp` into the node container, and restarts the node if it is running. |
| `pg-node service-install` | Registers and enables the companion `systemd` service daemon. |
| `pg-node service-status` | Inspects systemd service status (`pg-node-service.service`). |
| `pg-node service-logs` | Tails journalctl logs for the background service. |
| `pg-node service-restart` | Restarts the background service daemon. |
| `pg-node service-uninstall` | Stops, disables, and removes the systemd service. |

👉 *Multi-node support: Pass `--name <NAME>` to any node command to manage multiple instances independently on a single server (e.g. `pg-node --name node2 status`).*

#### node-serviced update safety

`service-install`, `service-update`, and `service-uninstall` serialize mutations with a persistent `flock` lock and require
Linux `setsid` (both normally provided by `util-linux`). Older `setsid` versions without `--wait` are supported. Update and
rollback probes also require Bash, `awk`, `curl`, and `openssl`; release installation requires `jq`, `tar`, and a SHA-256
tool (`sha256sum` or `shasum`).

`service-start`, `service-stop`, and `service-restart` take the same lock, so they cannot restart the service midway
through a binary swap. They wait `NODE_SERVICE_LIFECYCLE_LOCK_WAIT_SECONDS` (default `30`) for an update in progress
before giving up, and their `systemctl` call is time-bounded rather than able to hang indefinitely.

Readiness uses the same `.env` semantics as `node-serviced`: optional `export`, `=` or `:`, last duplicate wins, comments,
single- and double-quoted values (including values spanning several lines), double-quote escapes, and prior-key
expansion. The file is parsed as data and is never sourced or evaluated. A malformed entry is charged to its own key, so
it cannot hide the keys the probe actually reads. `NODE_SERVICE_READINESS_DEADLINE_SECONDS` bounds the complete readiness
loop (default `30`, matching the unit's `TimeoutStartSec`), while `NODE_SERVICE_READINESS_TIMEOUT_SECONDS` bounds an
individual authenticated HTTPS probe. Set `NODE_SERVICE_READINESS_ATTEMPTS` to cap the number of probes as well; by
default the deadline alone bounds the wait.

The probe needs `curl` 7.49 or newer for `--connect-to` and `openssl` 1.1.1 or newer for `x509 -ext subjectAltName`.
Where either is older, or where the certificate in `SSL_CERT_FILE` cannot be verified against what the running daemon
presents (during a renewal, for instance), the probe reports that it could not run. An update then falls back to the
systemd unit state with a warning instead of rolling back an installation that is working.

---

## 🗄️ Database Support Matrix

PasarGuard supports 5 database engines tailored for different workloads:

| Engine | Ideal Workload | Admin Web UI | Concurrency Mechanism |
| :--- | :--- | :--- | :--- |
| **SQLite** | Under 500 active users | Embedded | WAL mode (`PRAGMA wal_checkpoint`) |
| **MySQL 8.0** | General multi-service | phpMyAdmin (port 8010) | InnoDB transactions |
| **MariaDB** | High-performance open alternative | phpMyAdmin (port 8010) | Aria / InnoDB |
| **PostgreSQL 17** | 1,000+ concurrent clients | pgAdmin 4 (port 8010) | PgBouncer transaction pooling (port 6432) |
| **TimescaleDB** | High-throughput metrics & analytics | pgAdmin 4 (port 8010) | Hypertables + PgBouncer pooling (port 6432) |

👉 *Read the full database tuning guide in [docs/database-configurations.md](docs/database-configurations.md).*

---

## 💾 Backups & Disaster Recovery

The management script backs up application settings, persistent files and
database snapshots or dumps. New backups also record actual image digests,
source database versions and a SHA256 payload inventory.

- Run `pasarguard backup` for an immediate backup, or configure scheduled Telegram
  delivery with `pasarguard backup-service` (including optional HTTP/SOCKS proxy).
- Use `pasarguard restore /path/to/backup.zip --check` to validate a downloaded
  archive and display its source versions without changing services.
- Ordinary restore checks engine/version compatibility and supports TimescaleDB
  conversion using a temporary container. SQL imports do not provide whole-host
  rollback; keep a separate backup before replacing an existing installation.

### Recover when the original server is gone

Install only the management script on the new host (`install-script`), copy the
complete backup there, then run:

```bash
sudo pasarguard restore /root/backup.zip --check
sudo pasarguard restore /root/backup.zip --fresh
```

Fresh recovery uses the images recorded in a new backup and starts the database
before the panel. It refuses existing storage and never guesses the source
version from `latest`. Legacy archives remain supported by ordinary restore.
See the [English recovery runbook](docs/backup-and-restore.md) or
[راهنمای فارسی بازیابی](docs/backup-and-restore.fa.md) for old backups,
multipart archives, offline images, and post-recovery checks.

---

## 🔒 SSL & TLS Security

PasarGuard provides 4 SSL operational modes:
- **Let's Encrypt Domain**: Fully automated HTTP-01 challenge verification via `acme.sh`.
- **Let's Encrypt IP**: Short-lived public IP certificates when no domain is configured.
- **Custom Certificate**: Bring your own CA-signed certificate chain and private key.
- **Node Self-Signed with SAN**: Automatic Subject Alternative Name (SAN) generation for remote nodes with private key permissions hardened to `0600`.

👉 *Read the full security and certificate guide in [docs/ssl-and-certificates.md](docs/ssl-and-certificates.md).*

---

## 🇮🇷 Domestic Mirrors & Air-Gapped Networks

For servers operating under Iranian network sanctions and international filtering:
- **`mirror.sh` Benchmark Suite**: Measures latency and throughput against domestic Debian, Ubuntu, and Docker Registry mirrors (ArvanCloud, HamDocker, IranServer, MobinHost, IUT) and automatically configures `/etc/apt/sources.list` and `/etc/docker/daemon.json`.
- **Standalone Offline Bundles**: Pre-packaged tarballs containing all required compose templates and offline scripts without requiring GitHub access during installation.
  - [pasarguard-standalone.tar.gz](https://github.com/Free-Guy-IR/scripts/releases/latest/download/pasarguard-standalone.tar.gz)
  - [pg-node-standalone.tar.gz](https://github.com/Free-Guy-IR/scripts/releases/latest/download/pg-node-standalone.tar.gz)

👉 *Read the English standalone guide in [docs/offline-and-sanctions.md](docs/offline-and-sanctions.md) or the [راهنمای فارسی](iran-sanction/README-pasarguard-standalone.fa.md).*

---

## 📚 Documentation Index

| Guide | Description |
| :--- | :--- |
| **[CLI Reference](docs/cli-reference.md)** | Full command syntax, options, directory paths, and exit codes for Panel and Node. |
| **[Backup & Disaster Recovery](docs/backup-and-restore.md)** | Backup architecture, Telegram automation, proxy routing, and TimescaleDB migrations. |
| **[Database Configurations](docs/database-configurations.md)** | Engine comparisons, PgBouncer pooling, pgAdmin/phpMyAdmin, and memory tuning. |
| **[SSL & TLS Certificates](docs/ssl-and-certificates.md)** | Let's Encrypt ACME setup, custom certs, SAN entries, and node TLS verification. |
| **[Offline & Sanctions Guide](docs/offline-and-sanctions.md)** | Domestic mirror benchmarking (`mirror.sh`) and air-gapped standalone deployment. |
| **[Environment Variables](docs/environment-variables.md)** | Complete `.env` configuration dictionary for Panel and Worker Nodes. |

---

## 🤝 Contributing & Testing

Contributions are welcome! Please review [CONTRIBUTING.md](CONTRIBUTING.md) for development workflows and coding standards.

### Running the Test Suite
PasarGuard includes a master test runner executing all unit and safety test suites:

```bash
bash tests/run_all.sh
```

---

## 📄 License

This project is licensed under the terms of the repository's open source license.
