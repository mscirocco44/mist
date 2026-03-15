#!/bin/bash
set -euo pipefail
# download-deps.sh: Fetch all binary dependencies for a Mist deployment.
#
# Run this on a machine WITH internet access, then transfer the entire
# repo directory (including downloads/) to your air-gapped target.
#
# Usage: ./scripts/download-deps.sh [--skip-images] [--skip-rpms] [--skip-client]
#   --skip-images    skip pulling and saving Docker container images
#   --skip-rpms      skip downloading Docker and Alloy RPMs
#   --skip-client    skip downloading node_exporter and otelcol

SKIP_IMAGES=no
SKIP_RPMS=no
SKIP_CLIENT=no

for arg in "$@"; do
    case "$arg" in
        --skip-images) SKIP_IMAGES=yes ;;
        --skip-rpms)   SKIP_RPMS=yes ;;
        --skip-client) SKIP_CLIENT=yes ;;
        --help|-h)
            grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//'
            exit 0
            ;;
    esac
done

log() { printf '%s %s\n' "$(date '+%F %T')" "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DL="$BASE_DIR/downloads"
mkdir -p "$DL/dashboards"

# --- Docker RPMs (RHEL 9 x86_64) ---
if [ "$SKIP_RPMS" = no ]; then
    log "Downloading Docker RPMs..."
    DOCKER_BASE="https://download.docker.com/linux/centos/9/x86_64/stable/Packages"
    for rpm in \
        containerd.io-2.2.1-1.el9.x86_64.rpm \
        docker-ce-29.3.0-1.el9.x86_64.rpm \
        docker-ce-cli-29.3.0-1.el9.x86_64.rpm \
        docker-ce-rootless-extras-29.3.0-1.el9.x86_64.rpm \
        docker-compose-plugin-5.1.0-1.el9.x86_64.rpm
    do
        dest="$DL/$rpm"
        [ -f "$dest" ] && log "  already exists: $rpm" && continue
        log "  $rpm"
        curl -fsSL "$DOCKER_BASE/$rpm" -o "$dest"
    done

    log "Downloading Alloy RPM..."
    ALLOY_VERSION="1.13.2"
    ALLOY_RPM="alloy-${ALLOY_VERSION}-1.amd64.rpm"
    dest="$DL/$ALLOY_RPM"
    [ -f "$dest" ] || curl -fsSL \
        "https://github.com/grafana/alloy/releases/download/v${ALLOY_VERSION}/${ALLOY_RPM}" \
        -o "$dest"
fi

# --- Client binaries ---
if [ "$SKIP_CLIENT" = no ]; then
    log "Downloading Node Exporter..."
    NE_VERSION="1.7.0"
    NE_TAR="node_exporter-${NE_VERSION}.linux-amd64.tar.gz"
    dest="$DL/$NE_TAR"
    [ -f "$dest" ] || curl -fsSL \
        "https://github.com/prometheus/node_exporter/releases/download/v${NE_VERSION}/${NE_TAR}" \
        -o "$dest"

    log "Downloading OpenTelemetry Collector..."
    OTEL_VERSION="0.93.0"
    OTEL_TAR="otelcol-contrib_${OTEL_VERSION}_linux_amd64.tar.gz"
    dest="$DL/$OTEL_TAR"
    [ -f "$dest" ] || curl -fsSL \
        "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTEL_VERSION}/${OTEL_TAR}" \
        -o "$dest"
fi

# --- Container images ---
if [ "$SKIP_IMAGES" = no ]; then
    if command -v skopeo >/dev/null 2>&1; then
        PULL_CMD=skopeo
    elif command -v docker >/dev/null 2>&1; then
        PULL_CMD=docker
    else
        log "skopeo not found — attempting to install via dnf..."
        if dnf install -y skopeo >/dev/null 2>&1; then
            log "skopeo installed successfully."
            PULL_CMD=skopeo
        else
            echo "ERROR: skopeo not found and automatic install failed." >&2
            echo "  Try manually: sudo dnf install -y skopeo" >&2
            echo "  Or skip images: --skip-images" >&2
            exit 1
        fi
    fi
    log "Pulling and saving container images via $PULL_CMD (this may take a while)..."
    for spec in \
        "prom/prometheus:latest prometheus.tar" \
        "grafana/grafana:latest grafana.tar" \
        "grafana/loki:2.8.2 loki.tar" \
        "grafana/tempo:1.5.0 tempo.tar"
    do
        image=$(echo "$spec" | cut -d' ' -f1)
        tarfile=$(echo "$spec" | cut -d' ' -f2)
        dest="$DL/$tarfile"
        if [ -f "$dest" ]; then
            log "  already exists: $tarfile"
        elif [ "$PULL_CMD" = skopeo ]; then
            log "  pulling $image → $tarfile"
            skopeo copy "docker://$image" "docker-archive:${dest}:${image}"
        else
            log "  pulling $image → $tarfile"
            docker pull "$image"
            docker save "$image" -o "$dest"
        fi
    done
fi

# --- Grafana dashboard JSON files ---
log "Downloading Grafana dashboard JSON files..."
declare -A dashboards=(
    ["dashboard-node-exporter.json"]="1860"
    ["dashboard-loki.json"]="12019"
    ["dashboard-alloy.json"]="21698"
)
for filename in "${!dashboards[@]}"; do
    id="${dashboards[$filename]}"
    dest="$DL/dashboards/$filename"
    [ -f "$dest" ] && log "  already exists: $filename" && continue
    log "  dashboard $id → $filename"
    curl -fsSL "https://grafana.com/api/dashboards/${id}/revisions/latest/download" -o "$dest"
done

log "All dependencies downloaded to $DL"
log "Transfer the full repo directory to your air-gapped machine and run deploy-server.sh / deploy-client.sh"
