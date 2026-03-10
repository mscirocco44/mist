Prerequisites & Required Downloads
-----------------------------------
This project is designed for air‑gapped environments.  Before running any
installer script you must ensure the host OS has a few basic packages
installed:

- `firewalld` (for opening ports)
- `wget`, `curl`, and `git` (used by the scripts and helpers)

If these packages are not present the scripts will abort and you'll need to
install them manually; you can copy their RPMs into `downloads/` and run
`dnf localinstall` yourself.

Place all other required RPMs and container tarballs in `downloads/` before
running scripts.

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
3. Run server deploy (optionally pass a hosts file listing client hostnames/IPs
   and select which components to enable).  The script now supports
   `--help` for a quick summary, and it will prompt you to pick a local
   interface/IP simply so you can remember which address you're working
   with:
    ```bash
    sudo ./scripts/deploy-server.sh --help                    # show usage
    sudo ./scripts/deploy-server.sh --only-prometheus configs/hosts.txt
    # or enable everything:
    sudo ./scripts/deploy-server.sh --with-loki --with-tempo configs/hosts.txt
    ```
	- `configs/hosts.txt` should list client IPs/hostnames, one per line.

**Client:**
1. Place all RPMs and tarballs in `downloads/`.
2. Make scripts executable:
    ```bash
    chmod +x scripts/deploy-client.sh
    ```
3. Run client deploy (specify the server hostname or IP; `--help` is
   supported if you forget the syntax):
    ```bash
    sudo ./scripts/deploy-client.sh <server_ip_or_hostname>
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
- To upgrade any component, replace the RPM/tarball in `downloads/` and re-run the deploy script.  You can also use the `--update` flag to load a new image and restart a specific service, for example:

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



> **Offline note:** the server installer runs completely offline; ensure all required files are in `downloads/` before starting.

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
> **Offline note:** client installation also requires RPMs/tarballs in
> `downloads/`.  No network access will be attempted.
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
- install `node_exporter` strictly from `downloads/node_exporter*` and create a systemd unit at `/etc/systemd/system/node_exporter.service` (no network fetch will be attempted);
- install the OpenTelemetry Collector from `downloads/` if a tarball is provided, otherwise skip that optional component entirely.

Notes
-----
- `configs/prometheus.yml.template` is used when no hosts file is provided.

Offline operation
-----------------
This repository is intended for completely disconnected environments.  All
RPMs and tarballs required for server and client installation must be placed
in the `downloads/` directory before running any script.  The installers will
fail fast with a clear "Missing …" message if a required file is absent; they
will never attempt to contact external package repositories or download
binaries from the internet.  The deployment scripts do **not** run `dnf
update` or any other command that might reach out over the network.  For
air‑gapped systems you can ship updated artifacts yourself and rerun the
script to perform upgrades.
- `alloy` is used for log shipping; if an `alloy` RPM is present in `downloads/` the setup will install it and copy `configs/config.alloy.template` to `/etc/alloy/config.alloy`.
- Prometheus expects `node_exporter` on port `9100` and the OpenTelemetry Collector (if installed) should forward traces to Tempo.

If you want Kubernetes manifests instead of Docker Compose, tell me and I will generate them.
