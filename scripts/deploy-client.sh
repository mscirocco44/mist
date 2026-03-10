#!/bin/bash
set -euo pipefail
# deploy-client.sh: Complete Mist client setup and deployment

# Usage: ./deploy-client.sh <server_ip_or_hostname>

SERVER="$1"
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DOWNLOAD_DIR="$BASE_DIR/downloads"

show_usage() {
    cat <<'EOF'
Usage: ./deploy-client.sh <server_ip_or_hostname>
EOF
}

log() {
    printf '%s %s\n' "$(date '+%F %T')" "$*"
}

error_exit() {
    log "ERROR: $*" >&2
    exit 1
}

if [ -z "$SERVER" ]; then
    show_usage
    exit 1
fi

# basic validation: ensure server resolves
if ! getent hosts "$SERVER" >/dev/null 2>&1; then
    error_exit "Server '$SERVER' does not resolve via DNS/hosts"
fi


# NIC/IP selection
log "Querying available network interfaces and IP addresses"
echo "Available network interfaces and IP addresses:"
ip -o -4 addr show | awk '{print NR ". " $2 " - " $4}'
read -p "Select the number of the interface/IP to use for this client: " NIC_CHOICE
SELECTED_IP=$(ip -o -4 addr show | awk -v n="$NIC_CHOICE" 'NR==n {print $4}' | cut -d'/' -f1)
log "Selected IP: $SELECTED_IP"

# Check file (wildcard for alloy RPM)
# ensure at least one match exists in downloads directory
shopt -s nullglob
alloys=("$DOWNLOAD_DIR"/alloy*.rpm)
shopt -u nullglob
[ ${#alloys[@]} -gt 0 ] || error_exit "Missing alloy RPM in $DOWNLOAD_DIR"

# System prep (idempotent) – offline only.  install helpers from downloads

# System prep (idempotent) – offline only.  this script assumes the base
# system already has the following packages installed; if any are missing
# we abort and prompt you to install them (you can use RPMs from
# $DOWNLOAD_DIR if required).

required_pkgs=(firewalld wget curl)
missing=()
for pkg in "${required_pkgs[@]}"; do
    if ! rpm -q "$pkg" >/dev/null 2>&1; then
        missing+=("$pkg")
    fi
done
if [ ${#missing[@]} -gt 0 ]; then
    echo "Prerequisite packages missing: ${missing[*]}" >&2
    echo "Please install them before running this script." >&2
    echo "You can copy the corresponding RPMs into $DOWNLOAD_DIR (e.g." >&2
    echo "$DOWNLOAD_DIR/firewalld*.rpm, $DOWNLOAD_DIR/wget*.rpm) and then" >&2
    echo "run 'dnf localinstall -y <rpm>' manually." >&2
    exit 1
fi

systemctl enable --now firewalld || true
setenforce 1
restorecon -Rv /etc /var

# track whether firewall rules changed so we can reload once at end
FIREWALL_CHANGED=0

# Create svc_mist
id svc_mist &>/dev/null || useradd --system --no-create-home --shell /sbin/nologin svc_mist

# Install alloy (skip if installed, use wildcard)
if ! rpm -q alloy >/dev/null 2>&1; then
    dnf localinstall -y "${alloys[@]}" || error_exit "Alloy install failed"
fi

# Config dir and copy/rename template (idempotent—skip if exists)
mkdir -p /etc/alloy
chown svc_mist:svc_mist /etc/alloy
restorecon -Rv /etc/alloy

# Replace <server-ip> in alloy config (template substitution without sed)
if [ ! -f "/etc/alloy/config.alloy" ]; then
  tmpl=$(<"$BASE_DIR/configs/config.alloy.template")
  # bash substitution does not treat / specially
  config_content="${tmpl//<server-ip>/$SERVER}"
  printf '%s' "$config_content" > /etc/alloy/config.alloy
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
  if ! firewall-cmd --permanent --query-port="$port"/tcp >/dev/null; then
    firewall-cmd --permanent --add-port="$port"/tcp
    FIREWALL_CHANGED=1
  fi
done

# --- Install node_exporter (idempotent) ---
NODE_USER=node_exporter
id $NODE_USER &>/dev/null || useradd --system --no-create-home --shell /sbin/nologin $NODE_USER

# Install node_exporter strictly from downloads
NE_TAR=$(ls "$DOWNLOAD_DIR"/node_exporter*.tar* 2>/dev/null | head -n1 || true)
if [ -n "$NE_TAR" ]; then
  log "Using local node_exporter archive: $NE_TAR"
  tmpdir=$(mktemp -d)
  tar -C "$tmpdir" -xzf "$NE_TAR"
  cp "$tmpdir"/node_exporter-*/node_exporter /usr/local/bin/ || error_exit "failed copying node_exporter"
  rm -rf "$tmpdir"
else
  log "Missing node_exporter tarball in $DOWNLOAD_DIR; please obtain one before running the script"
fi

if [ -x "/usr/local/bin/node_exporter" ]; then
  chown "$NODE_USER":"$NODE_USER" /usr/local/bin/node_exporter || true
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
  if ! firewall-cmd --permanent --query-port=9100/tcp >/dev/null; then
    firewall-cmd --permanent --add-port=9100/tcp
    FIREWALL_CHANGED=1
  fi
  echo "Installed and started node_exporter"
else
  echo "node_exporter not installed; please check logs" >&2
fi

# --- Install OpenTelemetry Collector (optional) strictly from downloads ---
OTEL_TAR=$(ls "$DOWNLOAD_DIR"/otel*collector*.tar* 2>/dev/null | head -n1 || true)
if [ -n "$OTEL_TAR" ]; then
  log "Using local OTEL collector archive: $OTEL_TAR"
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
  echo "No OTEL collector archive found in $DOWNLOAD_DIR; skipping optional installation" >&2
fi

if [ -x "/usr/local/bin/otelcol" ]; then
  mkdir -p /etc/otel-collector
  # Create OTEL collector config with server address
  if [ ! -f /etc/otel-collector/config.yaml ]; then
    tmpl=$(<"$BASE_DIR/configs/otel-collector-config.yaml.template")
    config_content="${tmpl//<TEMPO_HOST>/$SERVER}"
    printf '%s' "$config_content" > /etc/otel-collector/config.yaml
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

# final firewall reload if needed
if [ "$FIREWALL_CHANGED" -eq 1 ]; then
  firewall-cmd --reload
fi

log "Client deployment complete."
