# Stock Ticker App — Implementation Roadmap

This document outlines the phased delivery plan for the Stock Ticker App, derived from the engineering specification in [stock-ticker-spec.md](stock-ticker-spec.md).

```mermaid
flowchart LR
    A["Phase 1: MVP\n(Pi + Redis + DB + LAN Widget)"] --> B["Phase 2: Desktop\n(PyInstaller + Login + Tailscale)"]
    B --> C["Phase 3: Smart Alerts\n(Lambda + SQS + News Panel)"]
    C --> D["Phase 4: DevOps\n(GitHub Actions + CW Alarms)"]
    D --> E["Phase 5: Kubernetes Deployment\n(Helm Chart & Multi‑arch)"]
    E --> F["Phase 6: Advanced Features & Enhancements\n(Watchlists + Push + Charts)"]
```

---

## Phase 1: MVP — The Core Self-Hosted Ticker (v1.0)
>
> **Primary Milestone:** Reliable, persistent, containerized stock ticker running on Raspberry Pi 4 over LAN with **$0 cloud cost**.

* [ ] **Raspberry Pi Hardware & Host OS Hardening:**
  * [ ] Flash Raspberry Pi OS directly to NVMe SSD; update EEPROM bootloader to direct USB3 boot (`BOOT_ORDER=0xf41`) and remove microSD card entirely.
  * [ ] Verify official 15.3W USB-C power supply (run `vcgencmd get_throttled` to confirm `0x0` / no under-voltage).
  * [ ] Install active fan cooling or high-mass aluminum heatsink case (target <65°C under load via `vcgencmd measure_temp`).
  * [ ] Mount NVMe drive permanently at `/mnt/nvme` via `/etc/fstab`; create PostgreSQL storage directory on NVMe mount.
  * [ ] Verify NVMe UASP and TRIM support (`lsblk --discard`); enable weekly TRIM cron (`sudo fstrim -av`).
  * [ ] Connect via Gigabit Ethernet and configure Static DHCP reservation on home router.
  * [ ] Verify NTP time synchronization (`systemd-timesyncd`) to prevent AWS SigV4 clock skew issues (`RequestTimeTooSkewed`).
  * [ ] Configure host firewall (`ufw allow 22`, `ufw allow 8000` from LAN CIDR) and enforce SSH key authentication (`PasswordAuthentication no`).
  * [ ] Set strict `.env` file permissions on host (`chmod 600 .env`).
  * [ ] Configure initial local database backup script (`pg_dump` compressed to `/mnt/nvme/backups/`).
* [ ] **Containerized Backend (`docker-compose.yml`):**
  * [ ] `api` service: FastAPI + Uvicorn server.
  * [ ] `redis` service: `redis:alpine` in-memory cache.
  * [ ] `postgres` service: `postgres:alpine` with data directory bind-mounted to NVMe.
* [ ] **Market Data & Caching Logic:**
  * [ ] Market data client adapter for primary provider.
  * [ ] Market-hours TTL cache policy in Redis (15–60s market hours, hours when closed).
  * [ ] Asynchronous write of history records to Postgres on live fetches.
* [ ] **Security & Networking:**
  * [ ] Shared API key header validation dependency on FastAPI routes.
  * [ ] LAN-only Docker port publishing (no router port forwarding).
* [ ] **Basic Desktop Widget:**
  * [ ] Streamlit/Flask local UI wrapped in `pywebview` window.
  * [ ] Polling `GET /ticker/{symbol}` on interval with stale-data indicator fallback.
* [ ] **Observability & Diagnostics:**
  * [ ] Implement `GET /health` endpoint verifying Redis, Postgres, and NVMe disk headroom.
  * [ ] Structured JSON logging with `X-Correlation-ID` request tracking.
  * [ ] Docker container healthchecks and log rotation limits (`max-size="10m"`, `max-file="3"`).
* [ ] **Testing & Quality Assurance:**
  * [ ] **Unit Tests:** Mocked provider adapter HTTP responses (`respx`), in-memory Redis TTL calculations (`fakeredis`), and FastAPI route tests (`TestClient`).
  * [ ] **Integration Tests:** Run tests against real testcontainers (`redis:alpine`, `postgres:alpine`) verifying cache-then-fetch paths and Alembic up/down migrations.

---

## Phase 2: Native Desktop Experience & Remote Access (v1.1)

* System Tray Companion (`pystray`): Minimize widget to system tray / menu bar with status glance and hide/show toggle.

>
> **Primary Milestone:** Widget feels like an OS-native application and is reachable securely from outside the home.

* [ ] **Standalone Packaging (PyInstaller):**
  * [ ] Windowed build for Windows (`.exe`) and macOS (`.app`) without console terminal.
  * [ ] Clean background thread shutdown when window closes.
* [ ] **Start at Login Integration:**
  * [ ] Windows: Registry entry in `HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run`.
  * [ ] macOS: User `LaunchAgent` plist loaded via `launchctl`.
  * [ ] First-run prompt asking user consent + settings toggle in widget UI.
* [ ] **Secure Remote Access (Tailscale):**
  * [ ] Install and authenticate Tailscale on the Raspberry Pi.
  * [ ] Enable MagicDNS and automated Let's Encrypt HTTPS certificates.
  * [ ] Configure widget `.env` to target the Pi's Tailscale hostname.
* [ ] **Testing & Quality Assurance:**
  * [ ] **Unit Tests:** Mock OS registry (`winreg`) and filesystem plist calls to verify clean add/remove behavior without dangling entries.
  * [ ] **Packaging Smoke Tests:** Run packaged `.exe` and `.app` binaries in CI matrix with `--test` flag to verify webview libraries load without crashes.

---

## Phase 3: The "Smart" Alerting Slice (v2.0)

* Watchlists / Multi‑Ticker: Support tracking portfolios and watchlists with batch cache/fetch operations.
* Real‑Time Push Delivery: Transition UI updates from polling to Server‑Sent Events (SSE) or WebSockets for zero‑delay price and alert updates.
* Historical Charting & Technical Indicators: Render interactive sparklines, moving averages (SMA/EMA), and RSI directly from Postgres history.
* Mobile Push Notifications: Dispatch alerts via `ntfy.sh` or Pushover when significant price moves occur.

>
> **Primary Milestone:** Asynchronous AWS event-driven pipeline that sources and summarizes news on large price movements.

* [ ] **Price Delta Detection:**
  * [ ] Compare live price fetch against previous history record for symbol.
  * [ ] Asynchronously invoke AWS Lambda (`InvocationType: Event`) if delta exceeds threshold.
* [ ] **Narrow AWS Infrastructure (Terraform):**
  * [ ] Lambda function running LangChain + Google News RSS feed parser + Cloud LLM.
  * [ ] SSM Parameter Store `SecureString` for LLM API key.
  * [ ] SQS Standard Queue + Dead-Letter Queue (DLQ) with redrive policy.
  * [ ] Least-privilege IAM execution role for Lambda and IAM user/role for the Pi.
* [ ] **On-Demand SQS Polling on Pi:**
  * [ ] Ephemeral consumer task spawned strictly when Lambda is dispatched (`WaitTimeSeconds=20`), scoped to that invocation's own `request_id`.
  * [ ] Non-matching messages (belonging to a different invocation) released via `ChangeMessageVisibility=0`, never deleted or ingested by the wrong poller.
  * [ ] Matching messages ingested to Postgres (`TickerNewsAlert`), then `DeleteMessage` called, and task terminates.
  * [ ] Clean timeout after 2–3 minutes if Lambda fails.
  * [ ] FastAPI lifespan startup hook runs a full drain loop (not a single call) to recover any backlog produced during Pi downtime.
  * [ ] Low-frequency periodic backstop sweep (e.g. every 10–15 minutes) catches the residual case where a message arrives after every poller watching for it has already timed out.
* [ ] **Widget News Alert Panel:**
  * [ ] Decoupled polling loop for `GET /alerts?since={timestamp}` (30–60s).
  * [ ] Render news summary, symbol, price delta, and source links in dedicated alert section.
* [ ] **Testing & Quality Assurance:**
  * [ ] **Unit Tests:** Mock Google News RSS and Cloud LLM responses to verify LangChain prompt formatting and JSON output parsing.
  * [ ] **Unit Tests:** Mock SQS consumer with `moto` to verify idempotent upsert on duplicate delivery, `DeleteMessage` calls, timeout termination, non-matching-`request_id` release, drain-loop backlog recovery, and periodic sweep pickup.
  * [ ] **Integration Tests:** LocalStack / Moto server tests validating SQS long-polling, request-ID matching/release behavior, and DLQ redrive policies.
  * [ ] **Smoke Tests:** Post-deploy direct Lambda invocation (`aws lambda invoke`) validating message arrival on SQS.

---

## Phase 4: Production-Grade DevOps & Observability (v2.5)

* Infrastructure Dashboards: Lightweight Prometheus + Grafana stack on the Pi monitoring container metrics, hardware temperatures, and API latencies.
* Tailscale ACLs as Code: Manage Tailscale device access policies via Terraform.

>
> **Primary Milestone:** Fully automated zero-touch deploys, log rotation, and proactive alarm notifications.

* [ ] **CI/CD Workflows (GitHub Actions):**
  * [ ] PR workflow (`ci.yml`): Automated linting (`ruff`), type checking (`mypy`), unit tests, testcontainer integration tests, and Terraform plan.
  * [ ] Deploy workflow (`deploy.yml`):
    * Multi-arch ARM64 Docker build pushed to GitHub Container Registry (`ghcr.io`).
    * Pi self-hosted runner executes `docker compose pull && docker compose up -d`.
    * Terraform apply for Lambda/SQS via GitHub OIDC role.
* [ ] **Observability & Health:**
  * [ ] Docker log driver caps (`max-size="10m"`, `max-file="3"`).
  * [ ] CloudWatch Alarm on SQS `ApproximateAgeOfOldestMessage` (>15 mins).
* [ ] **Automated Backups & Disaster Recovery:**
  * [ ] Daily cron job running `pg_dump` of NVMe Postgres database with automated sync to off-host secondary storage (secondary drive or S3).
  * [ ] Document and test 10-minute rapid rebuild disaster recovery procedure from git repo, `.env`, and database backup.
* [ ] **Testing & Quality Assurance:**
  * [ ] Automated CI gate: Require 100% pass rate on unit & integration test suites before merge to `main`.
  * [ ] Post-deploy live health check verifying Pi `/ticker` endpoint returns HTTP 200.

---

## Phase 5: Kubernetes Deployment (v3.0)

> **Primary Milestone:** Deploy the service to a Kubernetes cluster using Helm, enabling scalable multi-node operation and easier upgrades.

* Responsibility: Deploy the service with Helm, enabling multi‑node scaling, easy upgrades, and unified configuration.
* Helm Chart (`charts/stock‑ticker`): Templates for Deployment, Service, ConfigMap, Secret, PersistentVolumeClaim for NVMe storage.
* CI/CD Integration: Extend GitHub Actions to lint (`helm lint`), package the chart, and push to an OCI registry or GitHub Pages.
* Multi‑arch Image: Build and push `linux/amd64,linux/arm64` API image used by the Helm chart.
* Automated Deploy Job: `helm upgrade --install` on `main` merges targeting a K3s cluster or cloud dev cluster.
* Rollback & Health‑checks: Use Helm rollback on failure; add a `postUpgrade` hook to verify pod readiness.
* Observability Add‑on: Deploy Prometheus‑node‑exporter and Grafana via Helm sub‑charts.
* Documentation: Update README with `helm install` instructions and required `values.yaml` secrets.
* Testing: KinD integration test that installs the chart and runs API smoke tests.

---
