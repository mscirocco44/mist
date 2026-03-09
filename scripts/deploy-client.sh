#!/bin/bash
set -euo pipefail
# deploy-client.sh: Complete Mist client setup and deployment

# Usage: ./deploy-client.sh <server_ip_or_hostname>

SERVER="$1"
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DOWNLOAD_DIR="$BASE_DIR/downloads"

# NIC/IP selection
echo "Available network interfaces and IP addresses:"
ip -o -4 addr show | awk '{print NR ". " $2 " - " $4}'
read -p "Select the number of the interface/IP to use for this client: " NIC_CHOICE
SELECTED_IP=$(ip -o -4 addr show | awk -v n="$NIC_CHOICE" 'NR==n {print $4}' | cut -d'/' -f1)
echo "Selected IP: $SELECTED_IP"

# Check file (wildcard for alloy RPM)
[ -f "$DOWNLOAD_DIR/alloy*.rpm" ] || { echo "Missing alloy RPM"; exit 1; }

# System prep (idempotent)
dnf update -y
dnf install -y wget curl firewalld || { echo "Install failed"; exit 1; }
systemctl enable --now firewalld || true
setenforce 1
restorecon -Rv /etc /var

# Create svc_mist
id svc_mist &>/dev/null || useradd --system --no-create-home --shell /sbin/nologin svc_mist

# Install alloy (skip if installed, use wildcard)
rpm -q alloy >/dev/null || dnf localinstall -y $DOWNLOAD_DIR/alloy*.rpm || { echo "Alloy install failed"; exit 1; }

# Config dir and copy/rename template (idempotent—skip if exists)
mkdir -p /etc/alloy
chown svc_mist:svc_mist /etc/alloy
restorecon -Rv /etc/alloy

# Replace <server-ip> in alloy config
if [ ! -f "/etc/alloy/config.alloy" ]; then
  sed "s|<server-ip>|$SERVER|g" $BASE_DIR/configs/config.alloy.template > /etc/alloy/config.alloy
fi

# Systemd override (use alloy for binary/service)
mkdir -p /etc/systemd/system/alloy.service.d
cat > /etc/systemd/system/alloy.service.d/override.conf <<'OVERRIDE'
[Service]
User=svc_mist
Group=svc_mist
ExecStart=/usr/bin/alloy run --server.http.listen-addr=0.0.0.0:12345 /etc/alloy/config.alloy
OVERRIDE

systemctl daemon-reload
systemctl enable --now alloy || true

# Firewalld
for port in 12345 4317; do
  firewall-cmd --permanent --query-port=$port/tcp >/dev/null || firewall-cmd --permanent --add-port=$port/tcp
done
firewall-cmd --reload

# --- Install node_exporter (idempotent) ---
NODE_USER=node_exporter
id $NODE_USER &>/dev/null || useradd --system --no-create-home --shell /sbin/nologin $NODE_USER

# Try local download first, else fetch latest from GitHub
NE_TAR=$(ls $DOWNLOAD_DIR/node_exporter*.tar* 2>/dev/null | head -n1 || true)
if [ -n "$NE_TAR" ]; then
  echo "Using local node_exporter archive: $NE_TAR"
  tmpdir=$(mktemp -d)
  tar -C "$tmpdir" -xzf "$NE_TAR"
  cp "$tmpdir"/node_exporter-*/node_exporter /usr/local/bin/
  rm -rf "$tmpdir"
else
  echo "No local node_exporter archive found; attempting to download latest from GitHub"
  api="https://api.github.com/repos/prometheus/node_exporter/releases/latest"
  dl=$(curl -s $api | grep "browser_download_url" | grep linux-amd64 | cut -d '"' -f4 | head -n1)
  if [ -n "$dl" ]; then
    tmpfile=$(mktemp)
    curl -sL "$dl" -o "$tmpfile"
    tmpdir=$(mktemp -d)
    tar -C "$tmpdir" -xzf "$tmpfile"
    cp "$tmpdir"/node_exporter-*/node_exporter /usr/local/bin/
    rm -rf "$tmpdir" "$tmpfile"
  else
    echo "Could not find node_exporter download URL; please place node_exporter tarball in $DOWNLOAD_DIR and re-run." >&2
  fi
fi

if [ -x "/usr/local/bin/node_exporter" ]; then
  chown $NODE_USER:$NODE_USER /usr/local/bin/node_exporter || true
  cat > /etc/systemd/system/node_exporter.service <<'UNIT'
[Unit]
Description=Prometheus Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable --now node_exporter || true
  firewall-cmd --permanent --query-port=9100/tcp >/dev/null || firewall-cmd --permanent --add-port=9100/tcp
  firewall-cmd --reload
  echo "Installed and started node_exporter"
else
  echo "node_exporter not installed; please check logs" >&2
fi

# --- Install OpenTelemetry Collector (optional) ---
OTEL_TAR=$(ls $DOWNLOAD_DIR/otel*collector*.tar* 2>/dev/null | head -n1 || true)
if [ -n "$OTEL_TAR" ]; then
  echo "Using local OTEL collector archive: $OTEL_TAR"
  tmpdir=$(mktemp -d)
  tar -C "$tmpdir" -xzf "$OTEL_TAR"
  # try common binary names
  if [ -f "$tmpdir"/otelcol ] || [ -f "$tmpdir"/otelcol-contrib ]; then
    if [ -f "$tmpdir"/otelcol-contrib ]; then
      cp "$tmpdir"/otelcol-contrib /usr/local/bin/otelcol || cp "$tmpdir"/otelcol /usr/local/bin/otelcol
    else
      cp "$tmpdir"/otelcol /usr/local/bin/otelcol
    fi
    rm -rf "$tmpdir"
  fi
else
  echo "No local OTEL collector archive found; attempting to download latest contrib collector"
  api="https://api.github.com/repos/open-telemetry/opentelemetry-collector-releases/releases/latest"
  dl=$(curl -s $api | grep "browser_download_url" | grep linux_amd64 | cut -d '"' -f4 | grep -i contrib | head -n1 || true)
  if [ -n "$dl" ]; then
    tmpfile=$(mktemp)
    curl -sL "$dl" -o "$tmpfile"
    tmpdir=$(mktemp -d)
    tar -C "$tmpdir" -xzf "$tmpfile"
    if [ -f "$tmpdir"/otelcol-contrib ]; then
      cp "$tmpdir"/otelcol-contrib /usr/local/bin/otelcol
    elif [ -f "$tmpdir"/otelcol ]; then
      cp "$tmpdir"/otelcol /usr/local/bin/otelcol
    fi
    rm -rf "$tmpdir" "$tmpfile"
  else
    echo "Could not find OTEL collector download URL; skipping OTEL installation." >&2
  fi
fi

if [ -x "/usr/local/bin/otelcol" ]; then
  mkdir -p /etc/otel-collector
  # Replace <TEMPO_HOST> in otel config
  if [ ! -f /etc/otel-collector/config.yaml ]; then
    sed "s|<TEMPO_HOST>|$SERVER|g" $BASE_DIR/configs/otel-collector-config.yaml.template > /etc/otel-collector/config.yaml
  fi
  cat > /etc/systemd/system/otel-collector.service <<'UNIT'
[Unit]
Description=OpenTelemetry Collector (contrib)
Wants=network-online.target
After=network-online.target

[Service]
ExecStart=/usr/local/bin/otelcol --config /etc/otel-collector/config.yaml
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable --now otel-collector || true
  echo "Installed and started OpenTelemetry Collector"
fi

echo "Client deployment complete."
