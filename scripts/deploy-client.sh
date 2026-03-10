#!/bin/bash
set -euo pipefail
# deploy-client.sh: Complete Mist client setup and deployment

# Usage: ./deploy-client.sh [options] <server_ip_or_hostname>
#   --with-loki            configure Alloy to ship logs to Loki (disabled by default)
#   --with-tempo           install OpenTelemetry Collector for traces to Tempo (disabled by default)
#   --help, -h             show this message

USE_LOKI=no
USE_TEMPO=no
SERVER=""

log() {
    printf '%s %s\n' "$(date '+%F %T')" "$*"
}

error_exit() {
    log "ERROR: $*" >&2
    exit 1
}

show_usage() {
    cat <<'EOF'
Usage: ./deploy-client.sh [options] <server_ip_or_hostname>

Options:
  --with-loki            configure Alloy to ship logs to Loki (disabled by default)
  --with-tempo           install OpenTelemetry Collector for traces to Tempo (disabled by default)
  --help, -h             show this message

server_ip_or_hostname: IP address or hostname of the Mist server
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --with-loki)
            USE_LOKI=yes
            ;;
        --with-tempo)
            USE_TEMPO=yes
            ;;
        --help|-h)
            show_usage
            exit 0
            ;;
        *)
            [ -z "$SERVER" ] && SERVER="$1" || true
            ;;
    esac
    shift
done

# script needs root for package installation and service configuration
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: this installer must be run as root (use sudo or login as root)" >&2
    exit 1
fi

if [ -z "$SERVER" ]; then
    show_usage
    exit 1
fi

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOWNLOAD_DIR="$BASE_DIR/downloads"

log "Base directory resolved to $BASE_DIR"

# basic validation: ensure server resolves (skip for bare IPs)
[[ "$SERVER" =~ ^[0-9.]+$ ]] || getent hosts "$SERVER" >/dev/null 2>&1 || error_exit "Server '$SERVER' does not resolve"

# NIC/IP selection
log "Querying available network interfaces and IP addresses"
echo "Available network interfaces and IP addresses:"
ip -o -4 addr show | awk '{print NR ". " $2 " - " $4}'
read -p "Select the number of the interface/IP to use for this client: " NIC_CHOICE
SELECTED_IP=$(ip -o -4 addr show | awk -v n="$NIC_CHOICE" 'NR==n {print $4}' | cut -d'/' -f1)
log "Selected IP: $SELECTED_IP"

# ensure at least one match exists in downloads directory
shopt -s nullglob
alloys=("$DOWNLOAD_DIR"/alloy*.rpm)
shopt -u nullglob
[ ${#alloys[@]} -gt 0 ] || error_exit "Missing alloy RPM in $DOWNLOAD_DIR"

NE_TAR=$(ls "$DOWNLOAD_DIR"/node_exporter*.tar* 2>/dev/null | head -n1 || true)
[ -n "$NE_TAR" ] || error_exit "Missing node_exporter tarball in $DOWNLOAD_DIR"

if [ "$USE_TEMPO" = yes ]; then
    OTEL_TAR=$(ls "$DOWNLOAD_DIR"/otelcol*.tar* 2>/dev/null | head -n1 || true)
    [ -n "$OTEL_TAR" ] || error_exit "--with-tempo specified but no otelcol tarball found in $DOWNLOAD_DIR"
fi

# System prep – offline only.  this script assumes the base system already
# has the following packages; if any are missing we abort.
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
    echo "You can copy the corresponding RPMs into $DOWNLOAD_DIR and run" >&2
    echo "'dnf localinstall -y <rpm>' manually." >&2
    exit 1
fi

systemctl enable --now firewalld || true
setenforce 1
restorecon -Rv /etc /var

# track whether firewall rules changed so we can reload once at end
FIREWALL_CHANGED=0

# Create svc_mist service user
if ! id svc_mist &>/dev/null; then
    useradd --system --home-dir /home/svc_mist --create-home \
            --shell /sbin/nologin svc_mist
else
    mkdir -p /home/svc_mist
    chown svc_mist:svc_mist /home/svc_mist
fi

# --- Install mist-alloy ---
if ! rpm -q alloy >/dev/null 2>&1; then
    dnf localinstall -y "${alloys[@]}" || error_exit "Alloy install failed"
fi

# Disable the RPM-provided unit; mist-alloy.service takes over
systemctl disable --now alloy.service 2>/dev/null || true

mkdir -p /etc/alloy /var/lib/alloy
chown svc_mist:svc_mist /etc/alloy /var/lib/alloy
restorecon -Rv /etc/alloy

if [ ! -f "/etc/alloy/config.alloy" ]; then
    tmpl=$(<"$BASE_DIR/configs/config.alloy.template")
    config_content="${tmpl//<server-ip>/$SERVER}"
    printf '%s' "$config_content" > /etc/alloy/config.alloy
fi

cat > /etc/systemd/system/mist-alloy.service <<'UNIT'
[Unit]
Description=Mist - Alloy log and metrics agent
Wants=network-online.target
After=network-online.target

[Service]
User=svc_mist
Group=svc_mist
WorkingDirectory=/var/lib/alloy
ExecStart=/usr/bin/alloy run --server.http.listen-addr=0.0.0.0:12345 /etc/alloy/config.alloy
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now mist-alloy || true

for port in 12345; do
    if ! firewall-cmd --permanent --query-port="$port"/tcp >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="$port"/tcp
        FIREWALL_CHANGED=1
    fi
done
log "mist-alloy installed and started"

# --- Install mist-node-exporter ---
id node_exporter &>/dev/null || useradd --system --no-create-home --shell /sbin/nologin node_exporter

log "Using local node_exporter archive: $NE_TAR"
tmpdir=$(mktemp -d)
tar -C "$tmpdir" -xzf "$NE_TAR"
cp "$tmpdir"/node_exporter-*/node_exporter /usr/local/bin/ || error_exit "failed copying node_exporter"
rm -rf "$tmpdir"
chown node_exporter:node_exporter /usr/local/bin/node_exporter

cat > /etc/systemd/system/mist-node-exporter.service <<'UNIT'
[Unit]
Description=Mist - Prometheus Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now mist-node-exporter || true

if ! firewall-cmd --permanent --query-port=9100/tcp >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port=9100/tcp
    FIREWALL_CHANGED=1
fi
log "mist-node-exporter installed and started"

# --- Install mist-otelcol (requires --with-tempo) ---
if [ "$USE_TEMPO" = yes ]; then
    log "Using local OTel Collector archive: $OTEL_TAR"
    tmpdir=$(mktemp -d)
    tar -C "$tmpdir" -xzf "$OTEL_TAR"
    if [ -f "$tmpdir/otelcol-contrib" ]; then
        cp "$tmpdir/otelcol-contrib" /usr/local/bin/otelcol
    elif [ -f "$tmpdir/otelcol" ]; then
        cp "$tmpdir/otelcol" /usr/local/bin/otelcol
    else
        error_exit "Could not find otelcol binary in archive $OTEL_TAR"
    fi
    rm -rf "$tmpdir"

    mkdir -p /etc/otel-collector
    if [ ! -f /etc/otel-collector/config.yaml ]; then
        tmpl=$(<"$BASE_DIR/configs/otel-collector-config.yaml.template")
        config_content="${tmpl//<TEMPO_HOST>/$SERVER}"
        printf '%s' "$config_content" > /etc/otel-collector/config.yaml
    fi

    cat > /etc/systemd/system/mist-otelcol.service <<'UNIT'
[Unit]
Description=Mist - OpenTelemetry Collector
Wants=network-online.target
After=network-online.target

[Service]
ExecStart=/usr/local/bin/otelcol --config /etc/otel-collector/config.yaml
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    systemctl enable --now mist-otelcol || true

    if ! firewall-cmd --permanent --query-port=4317/tcp >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port=4317/tcp
        FIREWALL_CHANGED=1
    fi
    log "mist-otelcol installed and started"
fi

# final firewall reload if needed
if [ "$FIREWALL_CHANGED" -eq 1 ]; then
    firewall-cmd --reload
fi

log "Client deployment complete."
