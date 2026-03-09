#!/bin/bash
set -euo pipefail
# deploy-server.sh: Complete Mist server setup and deployment

# Usage: ./deploy-server.sh [hosts_file]

HOSTS_FILE="$1"
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DOWNLOAD_DIR="$BASE_DIR/downloads"
MIST_DIR="/opt/mist-server"

# NIC/IP selection
echo "Available network interfaces and IP addresses:"
ip -o -4 addr show | awk '{print NR ". " $2 " - " $4}'
read -p "Select the number of the interface/IP to use for this server: " NIC_CHOICE
SELECTED_IP=$(ip -o -4 addr show | awk -v n="$NIC_CHOICE" 'NR==n {print $4}' | cut -d'/' -f1)
echo "Selected IP: $SELECTED_IP"

# Check downloads
for file in containerd.io*.rpm docker-ce*.rpm docker-ce-cli*.rpm docker-compose-plugin*.rpm prometheus.tar grafana.tar loki.tar tempo.tar; do
  [ -f "$DOWNLOAD_DIR/$file" ] || { echo "Missing $file"; exit 1; }
done

# System prep
dnf update -y
dnf install -y wget curl git firewalld || { echo "Install failed"; exit 1; }
systemctl enable --now firewalld || true
setenforce 1
restorecon -Rv /opt /etc /var

# Create svc_mist
id svc_mist &>/dev/null || useradd --system --no-create-home --shell /sbin/nologin svc_mist

# Docker install
if ! rpm -q docker-ce >/dev/null; then
  dnf localinstall -y $DOWNLOAD_DIR/containerd.io*.rpm $DOWNLOAD_DIR/docker-ce*.rpm $DOWNLOAD_DIR/docker-ce-cli*.rpm $DOWNLOAD_DIR/docker-compose-plugin*.rpm || { echo "Docker install failed"; exit 1; }
  echo "Installed Docker packages"
else
  echo "Docker already installed; skipping"
fi

# Rootless Docker setup
SVC_UID=$(id -u svc_mist)
if [ ! -S "/run/user/$SVC_UID/docker.sock" ]; then
  su - svc_mist -s /bin/bash <<'ROOTLESS'
  export XDG_RUNTIME_DIR=/run/user/$(id -u)
  mkdir -p $XDG_RUNTIME_DIR
  systemctl --user start dbus.socket || true
  dockerd-rootless-setuptool.sh install
  systemctl --user enable --now docker
ROOTLESS
  echo "Applied rootless Docker setup"
else
  echo "Rootless Docker already set up; skipping"
fi

loginctl enable-linger svc_mist || true

# Load images
su - svc_mist -s /bin/bash <<LOAD
docker load -i $DOWNLOAD_DIR/prometheus.tar || true
docker load -i $DOWNLOAD_DIR/grafana.tar || true
docker load -i $DOWNLOAD_DIR/loki.tar || true
docker load -i $DOWNLOAD_DIR/tempo.tar || true
LOAD

# Setup dir and copy templates
mkdir -p $MIST_DIR/{prometheus,loki,tempo}
chown -R svc_mist:svc_mist $MIST_DIR
restorecon -Rv $MIST_DIR

[ -f "$MIST_DIR/docker-compose.yml" ] || cp $BASE_DIR/configs/docker-compose.yml.template $MIST_DIR/docker-compose.yml
[ -f "$MIST_DIR/loki/loki-config.yaml" ] || cp $BASE_DIR/configs/loki-config.yaml.template $MIST_DIR/loki/loki-config.yaml
[ -f "$MIST_DIR/tempo/tempo-config.yaml" ] || cp $BASE_DIR/configs/tempo-config.yaml.template $MIST_DIR/tempo/tempo-config.yaml

# Firewalld
for port in 9090 3000 3100 3200 4317; do
  firewall-cmd --permanent --query-port=$port/tcp >/dev/null || firewall-cmd --permanent --add-port=$port/tcp
done
firewall-cmd --reload

# Prometheus config
PROM_YML="$MIST_DIR/prometheus/prometheus.yml"
if [ -n "$HOSTS_FILE" ] && [ -f "$HOSTS_FILE" ]; then
  [ -f "$PROM_YML" ] && cp "$PROM_YML" "$PROM_YML.bak"
  cat > "$PROM_YML" <<YAML
global:
  scrape_interval: 15s
scrape_configs:
  - job_name: 'alloy_clients'
    static_configs:
      - targets:
YAML
  while read -r host; do
    [ -z "$host" ] && continue
    echo "      - \"${host}:12345\"" >> "$PROM_YML"
  done < "$HOSTS_FILE"
  chown svc_mist:svc_mist "$PROM_YML"
else
  [ -f "$PROM_YML" ] || cp $BASE_DIR/configs/prometheus.yml.template "$PROM_YML"
  chown svc_mist:svc_mist "$PROM_YML" || true
fi

# Start Docker Compose as svc_mist
XDG_RUNTIME_DIR="/run/user/$SVC_UID"
mkdir -p "$XDG_RUNTIME_DIR"
chown svc_mist:svc_mist "$XDG_RUNTIME_DIR" || true
su - svc_mist -s /bin/bash -c "export XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR && cd $MIST_DIR && docker compose up -d"

echo "Server deployment complete."