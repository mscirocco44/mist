Mist — Air-Gapped Observability Stack
======================================

Mist is an automated deployment toolkit for a self-contained observability stack
in air-gapped or offline environments. It sets up Prometheus, Grafana, Loki, and
Tempo on a central server, and deploys Node Exporter and Alloy (log/metrics agent)
on client nodes — all from local files with zero network access required.

- **Server**: Prometheus + Grafana (always), Loki and Tempo (optional)
- **Client**: Node Exporter + Alloy (always), OTel Collector (optional, with `--with-tempo`)
- All components run as the `svc_mist` service user; server stack runs in rootless Docker
- Managed via systemd: `mist-server`, `mist-alloy`, `mist-node-exporter`, `mist-otelcol`

---
Prerequisites & Required Downloads
-----------------------------------
This project is designed for air-gapped environments. Before running any
installer script, the host OS must have these packages installed:

- `firewalld` — for managing open ports
- `wget`, `curl` — used by the scripts
- `slirp4netns` — **server only**, required for rootless Docker port forwarding;
  without it, containers start but ports are unreachable from the host

If any are missing the scripts will abort with a clear error. You can copy their
RPMs into `downloads/` and run `dnf localinstall -y <rpm>` manually.

Place all required RPMs, tarballs, and dashboard JSON files in `downloads/`
before running any script.

**Server downloads:**

Docker RPMs (RHEL 9 x86_64):
- `containerd.io-2.2.1-1.el9.x86_64.rpm`
- `docker-ce-29.3.0-1.el9.x86_64.rpm`
- `docker-ce-cli-29.3.0-1.el9.x86_64.rpm`
- `docker-compose-plugin-5.1.0-1.el9.x86_64.rpm`

Container image tarballs (pull on a connected machine, then copy to `downloads/`):
```bash
docker pull prom/prometheus:latest      && docker save prom/prometheus:latest      -o downloads/prometheus.tar
docker pull grafana/grafana:latest      && docker save grafana/grafana:latest      -o downloads/grafana.tar
docker pull grafana/loki:2.8.2          && docker save grafana/loki:2.8.2          -o downloads/loki.tar
docker pull grafana/tempo:1.5.0         && docker save grafana/tempo:1.5.0         -o downloads/tempo.tar
```

Grafana dashboard JSON files (optional — auto-provisioned if present in `downloads/dashboards/`):
```bash
mkdir -p downloads/dashboards
curl -L "https://grafana.com/api/dashboards/1860/revisions/latest/download"  -o downloads/dashboards/dashboard-node-exporter.json
curl -L "https://grafana.com/api/dashboards/12019/revisions/latest/download" -o downloads/dashboards/dashboard-loki.json
curl -L "https://grafana.com/api/dashboards/21698/revisions/latest/download" -o downloads/dashboards/dashboard-alloy.json
```
Copy `downloads/dashboards/` to the target server before running `deploy-server.sh`.
The installer copies them automatically and Grafana loads them on first start.
If omitted, Grafana still works — you just won't have pre-built dashboards.

**Client downloads:**
- Alloy RPM: e.g. `alloy-1.13.2-1.amd64.rpm` — from https://github.com/grafana/alloy/releases
- Node Exporter tarball: e.g. `node_exporter-1.7.0.linux-amd64.tar.gz` — from https://github.com/prometheus/node_exporter/releases
- OTel Collector tarball (optional, `--with-tempo` only): e.g. `otelcol-contrib_0.93.0_linux_amd64.tar.gz` — from https://github.com/open-telemetry/opentelemetry-collector-releases/releases

---
Ports Opened
------------
**Server:**
- `9090/tcp` — Prometheus
- `3000/tcp` — Grafana
- `3100/tcp` — Loki (if `--with-loki`)
- `3200/tcp` — Tempo HTTP (if `--with-tempo`)
- `4317/tcp` — Tempo OTLP gRPC (if `--with-tempo`)

**Client:**
- `9100/tcp` — Node Exporter metrics
- `12345/tcp` — Alloy metrics endpoint
- `4317/tcp` — OTel Collector (if `--with-tempo`)

---
Step-by-step Deployment
-----------------------
**Server:**

1. Place all RPMs, tarballs, and dashboard JSON files in `downloads/`.
2. Make scripts executable:
   ```bash
   chmod +x scripts/deploy-server.sh
   ```
3. Create `configs/hosts.txt` — one client IP or hostname per line.
4. Run server deploy:
   ```bash
   sudo ./scripts/deploy-server.sh --help                                       # show usage
   sudo ./scripts/deploy-server.sh configs/hosts.txt                            # Prometheus + Grafana only
   sudo ./scripts/deploy-server.sh --with-loki configs/hosts.txt               # + Loki log aggregation
   sudo ./scripts/deploy-server.sh --with-loki --with-tempo configs/hosts.txt  # full stack
   sudo ./scripts/deploy-server.sh --data-dir /mnt/data configs/hosts.txt      # custom data directory
   ```
   - The script prompts for a network interface and data directory (default: `/var/lib/mist`).
     Pass `--data-dir <path>` to skip the prompt.
   - At the end it prints a deployment summary with URLs and the exact client deploy command to run.

**Client:**

1. Place all RPMs and tarballs in `downloads/`.
2. Make scripts executable:
   ```bash
   chmod +x scripts/deploy-client.sh
   ```
3. Run client deploy (use the server IP shown in the server deploy summary):
   ```bash
   sudo ./scripts/deploy-client.sh --help                                    # show usage
   sudo ./scripts/deploy-client.sh <server_ip>                               # Node Exporter + Alloy only
   sudo ./scripts/deploy-client.sh --with-loki <server_ip>                  # + Loki log shipping
   sudo ./scripts/deploy-client.sh --with-loki --with-tempo <server_ip>     # + OTel traces to Tempo
   ```
   - Server address is written into `/etc/alloy/config.alloy` and `/etc/otel-collector/config.yaml` automatically.

---
Grafana Dashboards & Data Sources
-----------------------------------
Data sources and dashboards are **auto-provisioned** on first start — no manual
configuration needed.

**Data sources** (configured automatically based on install flags):
- Prometheus — always added as the default data source
- Loki — added when `--with-loki` was passed to `deploy-server.sh`
- Tempo — added when `--with-tempo` was passed to `deploy-server.sh`

**Pre-built dashboards** (provisioned if JSON files were in `downloads/dashboards/` at install time):
- `dashboard-node-exporter.json` — Node Exporter Full (ID 1860) — host CPU, memory, disk, network
- `dashboard-loki.json` — Loki logs explorer (ID 12019) — requires `--with-loki`
- `dashboard-alloy.json` — Alloy overview (ID 21698) — agent health and metrics

1. Open Grafana at `http://<server>:3000` — default login is **admin / admin**.
   Grafana will prompt you to change the password on first login.

2. Pre-built dashboards appear under **Dashboards** in the sidebar immediately after first start.
   If no JSON files were present at install time, import them manually:
   Dashboards → New → Import → enter a dashboard ID → Load → select data source → Import.

3. **Build a custom dashboard**: Dashboards → New → New dashboard → Add visualization.
   Pick a data source, write a PromQL or LogQL query, choose a panel type, and save.

4. Dashboards and all Grafana state are persisted in `<data-dir>/grafana/`
   (default `/var/lib/mist/grafana`) and survive container restarts and re-deploys.

---
Troubleshooting & Verification
-------------------------------
**Server:**
```bash
systemctl status mist-server                    # stack status
systemctl restart mist-server                   # restart all containers
journalctl -u mist-server -f                    # follow service logs
```
- Prometheus targets: `http://<server>:9090/targets` — clients should appear as UP
- Grafana: `http://<server>:3000`
- If ports are unreachable: verify `slirp4netns` is installed — `rpm -q slirp4netns`

**Client:**
```bash
systemctl status mist-alloy                     # Alloy agent status
systemctl status mist-node-exporter             # Node Exporter status
curl http://localhost:9100/metrics | head -20   # Node Exporter metrics
curl http://localhost:12345/metrics | head -20  # Alloy metrics
journalctl -u mist-alloy -f                     # Alloy logs (check for Loki push errors)
```

**Loki "no data" in Grafana:**
- Verify logs are flowing: Grafana → Explore → select Loki → run `{job="systemd-journal"}`
- If that returns data, the pre-built dashboard query may use different labels — use Explore directly
- If no data, check Alloy logs for push errors: `journalctl -u mist-alloy -f`
- Ensure `svc_mist` is in the `systemd-journal` group (the client script does this, but the
  service must be restarted after the group change): `systemctl restart mist-alloy`

---
Upgrade / Update
----------------
Replace the RPM or tarball in `downloads/`, then use `--update` to reload a specific image:

```bash
sudo ./scripts/deploy-server.sh --update grafana      # reload Grafana image only
sudo ./scripts/deploy-server.sh --update prometheus   # reload Prometheus image only
sudo ./scripts/deploy-server.sh --update all          # reload all images
```

All containers use `restart: unless-stopped` and rootless Docker is set to linger,
so the stack starts automatically at boot without any extra configuration.

---
Configuration Files Created
----------------------------
The deploy scripts create and manage the following files:

**Server** (app config under `/opt/mist-server/`):

| File | Description |
|------|-------------|
| `docker-compose.yml` | Compose stack definition (copied from `configs/docker-compose.yml.template`) |
| `.env` | Sets `MIST_DATA_DIR` for volume mounts |
| `prometheus/prometheus.yml` | Prometheus scrape config generated from hosts file |
| `loki/loki-config.yaml` | Loki config (if `--with-loki`) |
| `tempo/tempo-config.yaml` | Tempo config (if `--with-tempo`) |
| `grafana/provisioning/datasources/datasources.yaml` | Auto-generated Grafana datasource list |
| `grafana/provisioning/dashboards/dashboards.yaml` | Dashboard provider config |
| `grafana/dashboards/dashboard-*.json` | Pre-built dashboard JSON files |

**Server** (system):

| File | Description |
|------|-------------|
| `/etc/systemd/system/mist-server.service` | Systemd unit wrapping `docker compose` as `svc_mist` |

**Server** (data directories, default `/var/lib/mist/`):

| Path | Contents |
|------|----------|
| `prometheus/` | Prometheus TSDB data |
| `grafana/` | Grafana database, plugins, sessions |
| `loki/` | Loki chunks, index, WAL (if `--with-loki`) |
| `tempo/` | Tempo trace storage (if `--with-tempo`) |

**Client**:

| File | Description |
|------|-------------|
| `/etc/alloy/config.alloy` | Alloy River config (Loki section appended if `--with-loki`) |
| `/var/lib/alloy/` | Alloy working directory |
| `/usr/local/bin/node_exporter` | Node Exporter binary extracted from tarball |
| `/etc/otel-collector/config.yaml` | OTel Collector config (if `--with-tempo`) |
| `/usr/local/bin/otelcol` | OTel Collector binary (if `--with-tempo`) |
| `/etc/systemd/system/mist-alloy.service` | Alloy systemd unit |
| `/etc/systemd/system/mist-node-exporter.service` | Node Exporter systemd unit |
| `/etc/systemd/system/mist-otelcol.service` | OTel Collector systemd unit (if `--with-tempo`) |
