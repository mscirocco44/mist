Mist — Air-Gapped Observability Stack
======================================

Mist deploys a full observability stack (Prometheus, Grafana, Loki, Tempo) to a
central server and installs monitoring agents (Node Exporter, Alloy) on client
nodes — entirely from local files with no internet access required on target systems.

**Server components** (central monitoring node):
- Prometheus — metrics collection and storage
- Grafana — dashboards and visualization
- Loki — log aggregation (optional, `--with-loki`)
- Tempo — distributed tracing (optional, `--with-tempo`)

**Client components** (every monitored node):
- Node Exporter — exposes host metrics (CPU, memory, disk, network) on port 9100
- Alloy — scrapes metrics and optionally ships logs to Loki on port 12345
- OTel Collector — forwards traces to Tempo (optional, `--with-tempo`)

All components run under the `svc_mist` service account. The server stack runs in
rootless Docker managed by systemd. Everything is controlled via:
`systemctl start|stop|restart|status mist-server` (server)
`systemctl start|stop|restart|status mist-alloy` (client)

---
Scripts Reference
-----------------

| Script | Purpose | Run on |
|--------|---------|--------|
| `scripts/download-deps.sh` | Downloads all binaries into `downloads/` | Internet-connected machine |
| `scripts/create-bundle.sh` | Packages repo + downloads into one `.tar.gz` | Internet-connected machine |
| `scripts/deploy-server.sh` | Installs and starts the server stack | Server (as root) |
| `scripts/deploy-client.sh` | Installs monitoring agents | Each client node (as root) |

---
Full Installation Workflow
--------------------------

### Step 1 — Clone the repo and download dependencies (internet-connected machine)

```bash
git clone https://github.com/mscirocco44/mist.git
cd mist
chmod +x scripts/*.sh
./scripts/download-deps.sh
```

`download-deps.sh` fetches all Docker RPMs, container image tarballs, client
binaries, and Grafana dashboard JSON files into `downloads/`. It skips anything
already present, so it is safe to re-run. Docker must be installed on this machine
to pull and save container images.

Skip flags (if you only need part of it):
```
--skip-images    skip Docker image pulls (if you already have the .tar files)
--skip-rpms      skip downloading Docker and Alloy RPMs
--skip-client    skip downloading node_exporter and otelcol
```

### Step 2 — Transfer to the air-gapped environment

**Option A — Direct copy** (if you can SCP/rsync to the target):
```bash
rsync -av mist/ root@<server_ip>:/root/mist/
```

**Option B — Release bundle** (single file for wider distribution):
```bash
./scripts/create-bundle.sh v1.0.0
# Then upload mist-bundle-v1.0.0.tar.gz to GitHub Releases:
gh release create v1.0.0 --title "Mist v1.0.0"
gh release upload v1.0.0 mist-bundle-v1.0.0.tar.gz
```
Anyone with access downloads one file, extracts it, and deploys:
```bash
tar -xzf mist-bundle-v1.0.0.tar.gz
cd mist/
```

### Step 3 — Install prerequisite OS packages (on the server)

The following must be installed on the target OS before running the deploy scripts.
If missing, the scripts will abort and tell you which packages are needed.

**Server:**
- `firewalld` — port management
- `curl`, `wget` — used by scripts
- `slirp4netns` — **required** for rootless Docker port forwarding; without it
  containers start but no ports are reachable from outside

**Client:**
- `firewalld`, `curl`, `wget`

Install from RPM if no internet:
```bash
dnf localinstall -y <package>.rpm
```

### Step 4 — Deploy the server

Create `configs/hosts.txt` with one client IP or hostname per line:
```
192.168.1.10
192.168.1.11
192.168.1.12
```

Then run:
```bash
# Prometheus + Grafana only (minimal):
sudo ./scripts/deploy-server.sh configs/hosts.txt

# With Loki log aggregation:
sudo ./scripts/deploy-server.sh --with-loki configs/hosts.txt

# Full stack (Prometheus, Grafana, Loki, Tempo):
sudo ./scripts/deploy-server.sh --with-loki --with-tempo configs/hosts.txt

# Custom data directory (default is /var/lib/mist):
sudo ./scripts/deploy-server.sh --with-loki --data-dir /mnt/data configs/hosts.txt
```

The script will:
1. Prompt you to select a network interface (sets the displayed server IP)
2. Prompt for a data directory (or use `--data-dir` to skip)
3. Install Docker from local RPMs
4. Set up rootless Docker for the `svc_mist` service account
5. Load container images from local tarballs
6. Generate all config files under `/opt/mist-server/`
7. Auto-provision Grafana datasources and dashboards
8. Open firewall ports for enabled services
9. Start the stack via `mist-server.service`
10. Print a deployment summary with URLs and the exact client deploy command

### Step 5 — Deploy clients

Copy the mist directory to each client node (or use the same bundle), then run
the command printed at the end of the server deploy. It looks like:

```bash
sudo ./scripts/deploy-client.sh --with-loki <server_ip>
```

This installs and starts:
- `mist-node-exporter` — Node Exporter binary from `downloads/node_exporter*.tar.gz`
- `mist-alloy` — Alloy agent from `downloads/alloy*.rpm`; if `--with-loki` is passed,
  Alloy is configured to ship systemd journal logs to `http://<server_ip>:3100`
- `mist-otelcol` — OTel Collector (only if `--with-tempo`)

Server address is written into config files automatically — no manual editing needed.

---
Ports Opened by the Scripts
----------------------------
**Server (firewalld permanent rules):**
- `9090/tcp` — Prometheus UI and API
- `3000/tcp` — Grafana UI
- `3100/tcp` — Loki log ingestion (if `--with-loki`)
- `3200/tcp` — Tempo HTTP (if `--with-tempo`)
- `4317/tcp` — Tempo OTLP gRPC ingestion (if `--with-tempo`)

**Client (firewalld permanent rules):**
- `9100/tcp` — Node Exporter (scraped by Prometheus)
- `12345/tcp` — Alloy metrics endpoint (scraped by Prometheus)
- `4317/tcp` — OTel Collector (if `--with-tempo`)

---
Grafana Access
--------------
After server deploy, open: `http://<server_ip>:3000`
Default login: **admin / admin** — Grafana prompts for a password change on first login.

**Auto-provisioned data sources** (based on deploy flags):
- Prometheus — always present, set as default
- Loki — present if `--with-loki` was used
- Tempo — present if `--with-tempo` was used

**Auto-provisioned dashboards** (from `downloads/dashboards/`):
- Node Exporter Full — host CPU, memory, disk, network metrics
- Alloy overview — agent health and scrape stats
- Loki logs explorer — log search (if `--with-loki`)

Dashboards appear immediately under **Dashboards** in the sidebar.
All Grafana state (dashboards, users, settings) is persisted in
`<data-dir>/grafana/` and survives restarts and re-deploys.

---
Troubleshooting
---------------
**Server stack not starting:**
```bash
systemctl status mist-server
journalctl -u mist-server -f
```
- Verify `slirp4netns` is installed: `rpm -q slirp4netns`
- Check Prometheus targets are UP: `http://<server>:9090/targets`

**Client services not running:**
```bash
systemctl status mist-alloy
systemctl status mist-node-exporter
journalctl -u mist-alloy -f
```
- Test Node Exporter: `curl http://localhost:9100/metrics | head -20`
- Test Alloy: `curl http://localhost:12345/metrics | head -20`

**Loki shows "no data" in Grafana:**
1. Go to Grafana → Explore → select Loki datasource
2. Run the query: `{job="systemd-journal"}`
3. If data appears here, the pre-built dashboard uses different label selectors — use Explore
4. If no data appears, check Alloy for push errors: `journalctl -u mist-alloy -f`
5. Make sure `svc_mist` is in the `systemd-journal` group (the client script adds this,
   but requires a service restart to take effect): `systemctl restart mist-alloy`

---
Updating Components
-------------------
To upgrade a container image (e.g. new Grafana version):

1. Update the version in `scripts/download-deps.sh`
2. Re-run `download-deps.sh` to fetch the new image tarball
3. Run the update command on the server — this loads the new image and restarts only
   the affected container without touching any config or data:

```bash
sudo ./scripts/deploy-server.sh --update grafana      # Grafana only
sudo ./scripts/deploy-server.sh --update prometheus   # Prometheus only
sudo ./scripts/deploy-server.sh --update all          # all images
```

To update client binaries (Alloy, node_exporter):
1. Replace the file in `downloads/`
2. Re-run `deploy-client.sh` on each client — it reinstalls the binary and restarts the service

---
Configuration Files Created
----------------------------
**Server — app config (`/opt/mist-server/`):**

| File | Description |
|------|-------------|
| `docker-compose.yml` | Container stack definition |
| `.env` | Sets `MIST_DATA_DIR` for Docker volume paths |
| `prometheus/prometheus.yml` | Scrape targets generated from hosts file |
| `loki/loki-config.yaml` | Loki config (if `--with-loki`) |
| `tempo/tempo-config.yaml` | Tempo config (if `--with-tempo`) |
| `grafana/provisioning/datasources/datasources.yaml` | Auto-generated datasource list |
| `grafana/provisioning/dashboards/dashboards.yaml` | Dashboard provider config |
| `grafana/dashboards/dashboard-*.json` | Pre-built dashboard JSON files |

**Server — system:**

| File | Description |
|------|-------------|
| `/etc/systemd/system/mist-server.service` | Systemd unit that runs `docker compose` as `svc_mist` |

**Server — persistent data (default `/var/lib/mist/`):**

| Path | Contents |
|------|----------|
| `prometheus/` | Prometheus time-series database |
| `grafana/` | Grafana database, users, saved dashboards |
| `loki/` | Log chunks, index, WAL |
| `tempo/` | Trace storage |

**Client:**

| File | Description |
|------|-------------|
| `/etc/alloy/config.alloy` | Alloy config (Loki block added if `--with-loki`) |
| `/usr/local/bin/node_exporter` | Node Exporter binary |
| `/usr/local/bin/otelcol` | OTel Collector binary (if `--with-tempo`) |
| `/etc/otel-collector/config.yaml` | OTel Collector config (if `--with-tempo`) |
| `/etc/systemd/system/mist-alloy.service` | Alloy systemd unit |
| `/etc/systemd/system/mist-node-exporter.service` | Node Exporter systemd unit |
| `/etc/systemd/system/mist-otelcol.service` | OTel Collector systemd unit (if `--with-tempo`) |
