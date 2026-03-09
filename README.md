Required Downloads (Offline Setup)
----------------------------------
Place all files in `downloads/` before running scripts.

**Server:**
- Docker RPMs (RHEL 9 x86_64):
  - [containerd.io-2.2.1-1.el9.x86_64.rpm](https://download.docker.com/linux/centos/9/x86_64/stable/Packages/containerd.io-2.2.1-1.el9.x86_64.rpm)
  - [docker-ce-29.3.0-1.el9.x86_64.rpm](https://download.docker.com/linux/centos/9/x86_64/stable/Packages/docker-ce-29.3.0-1.el9.x86_64.rpm)
  - [docker-ce-cli-29.3.0-1.el9.x86_64.rpm](https://download.docker.com/linux/centos/9/x86_64/stable/Packages/docker-ce-cli-29.3.0-1.el9.x86_64.rpm)
  - [docker-compose-plugin-5.1.0-1.el9.x86_64.rpm](https://download.docker.com/linux/centos/9/x86_64/stable/Packages/docker-compose-plugin-5.1.0-1.el9.x86_64.rpm)
- Container images (tarballs):
  - Prometheus: pull image, then `docker save prom/prometheus:latest -o prometheus.tar`
  - Grafana: pull image, then `docker save grafana/grafana:latest -o grafana.tar`
  - Loki: pull image, then `docker save grafana/loki:2.8.2 -o loki.tar`
  - Tempo: pull image, then `docker save grafana/tempo:1.5.0 -o tempo.tar`

**Client:**
- Alloy RPM: [alloy-1.13.2-1.amd64.rpm](https://github.com/grafana/alloy/releases) (find latest, download RPM)
- Node Exporter tarball: [node_exporter-1.7.0.linux-amd64.tar.gz](https://github.com/prometheus/node_exporter/releases/download/v1.7.0/node_exporter-1.7.0.linux-amd64.tar.gz)
- OpenTelemetry Collector tarball (optional): [otelcol-contrib_0.93.0_linux_amd64.tar.gz](https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v0.93.0/otelcol-contrib_0.93.0_linux_amd64.tar.gz)

---
Ports Opened
------------
**Server:**
- 9090/tcp (Prometheus)
- 3000/tcp (Grafana)
- 3100/tcp (Loki)
- 3200/tcp (Tempo gRPC)
- 4317/tcp (Tempo OTLP)

**Client:**
- 12345/tcp (Alloy metrics endpoint)
- 9100/tcp (Node Exporter metrics endpoint)
- 4317/tcp (OTEL Collector, if installed)

---
Software Used
-------------
**Server:**
- Docker (rootless, svc_mist user)
- Prometheus (container)
- Grafana (container)
- Loki (container)
- Tempo (container)

**Client:**
- Alloy (RPM, systemd service)
- Node Exporter (binary, systemd service)
- OpenTelemetry Collector (binary, systemd service, optional)

---
Step-by-step Deployment
-----------------------
**Server:**
1. Place all RPMs and tarballs in `downloads/`.
2. Make scripts executable:
	```bash
	chmod +x scripts/*.sh
	```
3. Run server autodeploy (optionally pass a hosts file listing
   client hostnames/IPs and select which components to enable):
	```bash
	sudo ./scripts/autodeploy-server.sh --only-prometheus configs/hosts.txt
	# or enable everything:
	sudo ./scripts/autodeploy-server.sh --with-loki --with-tempo configs/hosts.txt
	```
	- `configs/hosts.txt` should list client IPs/hostnames, one per line.

**Client:**
1. Place all RPMs and tarballs in `downloads/`.
2. Make scripts executable:
	```bash
	chmod +x scripts/autodeploy-client.sh
	```
3. Run client autodeploy:
	```bash
	sudo ./scripts/autodeploy-client.sh
	```
4. Edit `/etc/alloy/config.alloy` after install to point at your server’s Loki/Tempo endpoints.

---
How to Edit Dashboards
----------------------
- Grafana persists data in `/opt/mist-server/grafana`.
- Access Grafana at `http://<server>:3000` (default admin/changeme).
- You can add/edit dashboards via Grafana UI.

---
Troubleshooting & Verification
-----------------------------
**Server:**
- Prometheus UI: `http://<server>:9090/targets` (client targets should be listed)
- Grafana: `http://<server>:3000`
- Loki: `http://<server>:3100`
- Tempo: `http://<server>:3200`

**Client:**
- Node exporter metrics: `curl http://localhost:9100/metrics | head -n 20`
- Alloy metrics/log endpoints: per `/etc/alloy/config.alloy` settings
- OTEL collector: `systemctl status otel-collector`

---
Upgrade/Update
--------------
- To upgrade any component, replace the RPM/tarball in `downloads/` and re-run the setup/autodeploy script.  You can also use the `--update` flag to load a new image and restart a specific service, for example:

```
sudo ./scripts/deploy-server.sh --update prometheus    # reload prom image
sudo ./scripts/deploy-server.sh --update all         # reload everything
```

- All containers in the compose file are configured with `restart: unless-stopped`, and rootless Docker is enabled for the `svc_mist` user with lingering turned on.  That means the Docker daemon will start at boot and automatically restart the containers even if you don’t re-run the installer.  You don’t need a separate boot‑time job; simply ensure the `svc_mist` user is allowed to linger (the script already does this).
Mist — automated observability deployment

Overview
--------
This repo contains installer scripts and templates to deploy a Docker-based observability stack:
- Server: Prometheus, Grafana, Loki, Tempo (templates in `configs/`)
- Client: node_exporter, alloy (log shipper), OpenTelemetry Collector (client templates in `configs/`)


Quick start (server)
--------------------
1. Make scripts executable:
	```bash
	chmod +x scripts/deploy-server.sh
	```
2. Run server deploy (optionally pass a hosts file listing client hostnames/IPs
   and choose which services to start):
	```bash
	sudo ./scripts/deploy-server.sh --only-prometheus          # just Prometheus (Grafana and others omitted)
	sudo ./scripts/deploy-server.sh --with-loki --with-tempo  # enable Loki/Tempo in addition to Prometheus/Grafana
	```
	- Services are controlled by Docker Compose profiles; `prometheus` and
	  `grafana` are always started, while Loki and Tempo only run when the
	  corresponding `--with-*` flag is provided.
	- `configs/hosts.txt` should list client IPs/hostnames, one per line.

Quick start (client)
--------------------
Clients run native services (no containers). To install and start `alloy`, `node_exporter`, and the OpenTelemetry Collector (if available):
1. Make scripts executable:
	```bash
	chmod +x scripts/deploy-client.sh
	```
2. Run client deploy, passing the server IP or hostname:
	```bash
	sudo ./scripts/deploy-client.sh <server_ip_or_hostname>
	```
	- This will automatically set the correct server address in `/etc/alloy/config.alloy` and `/etc/otel-collector/config.yaml`.

The `deploy-client.sh` script will:
- install `alloy` from `downloads/alloy*.rpm` and configure `/etc/alloy/config.alloy` (server address auto-set);
- install `node_exporter` (from `downloads/node_exporter*` if present, else attempts to download latest release) and create a systemd unit at `/etc/systemd/system/node_exporter.service`;
- attempt to install the OpenTelemetry Collector (from `downloads/` if present or by fetching the latest contrib release) and configure `/etc/otel-collector/config.yaml` (server address auto-set).

Notes
-----
- `configs/prometheus.yml.template` is used when no hosts file is provided.
- `alloy` is used for log shipping; if an `alloy` RPM is present in `downloads/` the setup will install it and copy `configs/config.alloy.template` to `/etc/alloy/config.alloy`.
- Prometheus expects `node_exporter` on port `9100` and the OpenTelemetry Collector (if installed) should forward traces to Tempo.

If you want Kubernetes manifests instead of Docker Compose, tell me and I will generate them.
