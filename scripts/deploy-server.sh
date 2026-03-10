#!/bin/bash
set -euo pipefail
# deploy-server.sh: Complete Mist server setup and deployment

# must be root
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: this installer must be run as root (use sudo or login as root)" >&2
    exit 1
fi

log() {
    printf '%s %s\n' "$(date '+%F %T')" "$*"
}

error_exit() {
    log "ERROR: $*" >&2
    exit 1
}

# Usage: ./deploy-server.sh [options] [hosts_file]
#   --with-loki            enable Loki (disabled by default)
#   --with-tempo           enable Tempo (disabled by default)
#   --only-prometheus      install/prometheus only (disables loki and tempo)
#   --update [component]   load updated image(s) and restart component(s)
#                          component = prometheus|grafana|loki|tempo|all
#   hosts_file             optional path containing client IPs/hostnames

# parse arguments -----------------------------------------------------------
USE_PROMETHEUS=yes
# Grafana is always installed
USE_GRAFANA=yes
USE_LOKI=no
USE_TEMPO=no
ACTION=install      # install or update
COMP_TO_UPDATE=all  # used when ACTION=update
HOSTS_FILE=""
DATA_DIR=""         # set via --data-dir or interactive prompt

DEFAULT_DATA_DIR="/var/lib/mist"

show_usage() {
    cat <<'EOF'
Usage: ./deploy-server.sh [options] <hosts_file>

Options:
  --with-loki              enable Loki (disabled by default)
  --with-tempo             enable Tempo (disabled by default)
  --only-prometheus        prometheus only (disables loki and tempo)
  --data-dir <path>        where to store service data
                           default: /var/lib/mist  (recommended for RHEL)
                           subdirs created: prometheus/ grafana/ loki/ tempo/
  --update [component]     load updated image(s) and restart component(s)
                           component = prometheus|grafana|loki|tempo|all
  --help, -h               show this message

hosts_file: required — path to file listing client IPs/hostnames, one per line
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
        --only-prometheus|--only-prom)
            USE_LOKI=no
            USE_TEMPO=no
            ;;
        --data-dir)
            DATA_DIR="$2"
            shift
            ;;
        --update)
            ACTION=update
            if [ -n "$2" ] && [[ "$2" != --* ]]; then
                COMP_TO_UPDATE="$2"
                shift
            fi
            ;;
        --help|-h)
            show_usage
            exit 0
            ;;
        *)
            # treat as hosts file if not already set
            [ -z "$HOSTS_FILE" ] && HOSTS_FILE="$1" || true
            ;;
    esac
    shift
done

# hosts file is required (skip check for --update which doesn't need it)
if [ "$ACTION" != update ]; then
    if [ -z "$HOSTS_FILE" ]; then
        echo "ERROR: hosts_file is required." >&2
        show_usage
        exit 1
    fi
    if [ ! -f "$HOSTS_FILE" ]; then
        error_exit "hosts file not found: $HOSTS_FILE"
    fi
fi

# Determine the directory containing this script; do not rely on $PWD
# so that the installer works no matter where you invoke it from.  Using
# BASH_SOURCE is slightly more reliable when the script is sourced, but we
# always execute it directly.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DOWNLOAD_DIR="$BASE_DIR/downloads"

log "Base directory resolved to $BASE_DIR"
if [ ! -d "$DOWNLOAD_DIR" ]; then
    error_exit "downloads directory not found under $BASE_DIR." \
               "Are you running the script from the top-level of the unzipped repo?" \
               "Current working dir: $(pwd)"
fi
MIST_DIR="/opt/mist-server"

# NIC/IP selection
log "Querying available network interfaces and IP addresses"
echo "Available network interfaces and IP addresses:"
ip -o -4 addr show | awk '{print NR ". " $2 " - " $4}'
read -p "Select the number of the interface/IP to use for this server: " NIC_CHOICE
SELECTED_IP=$(ip -o -4 addr show | awk -v n="$NIC_CHOICE" 'NR==n {print $4}' | cut -d'/' -f1)
log "Selected IP: $SELECTED_IP"

# Data directory selection
if [ -z "$DATA_DIR" ]; then
    echo ""
    echo "Where should service data be stored (prometheus, grafana, loki, tempo)?"
    read -p "  Data directory [${DEFAULT_DATA_DIR}]: " DATA_DIR_INPUT
    DATA_DIR="${DATA_DIR_INPUT:-$DEFAULT_DATA_DIR}"
fi
log "Data directory: $DATA_DIR"

# note: this installer is offline-first and does not require network
# connectivity; all required packages and images must live in the
# downloads/ directory.  any network access is ignored.

# Check downloads (required packages and any enabled images)
# this script runs in offline mode only: every pattern must match and be readable.
patterns=(containerd.io*.rpm docker-ce*.rpm docker-ce-cli*.rpm docker-compose-plugin*.rpm)
[ "$USE_PROMETHEUS" = yes ] && patterns+=("prometheus.tar")
# grafana always enabled
patterns+=("grafana.tar")
[ "$USE_LOKI" = yes ] && patterns+=("loki.tar")
[ "$USE_TEMPO" = yes ] && patterns+=("tempo.tar")

shopt -s nullglob
for pat in "${patterns[@]}"; do
  matches=("$DOWNLOAD_DIR"/$pat)
  if [ ${#matches[@]} -eq 0 ]; then
    error_exit "Missing required file pattern: $pat in $DOWNLOAD_DIR"
  fi
  for f in "${matches[@]}"; do
      if [ ! -r "$f" ]; then
          error_exit "Cannot read required file: $f"
      fi
  done
done
shopt -u nullglob

# System prep - offline behaviour.  this script will not contact any
# remote repository.  it assumes the base OS is already functional; the
# only additional packages it needs are listed below.  if any are missing
# the script will abort and expect you to install them yourself (you may
# use RPMs from the downloads/ directory to do so).

required_pkgs=(firewalld wget curl slirp4netns)
missing=()
for pkg in "${required_pkgs[@]}"; do
    if ! rpm -q "$pkg" >/dev/null 2>&1; then
        missing+=("$pkg")
    fi
done
if [ ${#missing[@]} -gt 0 ]; then
    echo "Prerequisite packages missing: ${missing[*]}" >&2
    echo "Please install them before running this script." >&2
    echo "You can copy the corresponding RPMs into $DOWNLOAD_DIR and then" >&2
    echo "run 'dnf localinstall -y <rpm>' manually." >&2
    echo "Note: slirp4netns is required for rootless Docker port forwarding." >&2
    exit 1
fi

systemctl enable --now firewalld || true
setenforce 1
restorecon -Rv /opt /etc /var

# Create svc_mist (ensure there is a home directory because later
# we use "su - svc_mist" for rootless Docker setup).  The home itself
# isn't important but providing one avoids warnings and permission issues.
# Also add the user to the 'docker' group so that rootful Docker commands
# can be run without a separate daemon.
if ! id svc_mist &>/dev/null; then
    useradd --system --home-dir /home/svc_mist --create-home \
            --shell /bin/bash svc_mist
else
    mkdir -p /home/svc_mist
    chown svc_mist:svc_mist /home/svc_mist
fi
if getent group docker >/dev/null; then
    usermod -aG docker svc_mist || true
fi

# prepare runtime directory now so permissions are correct
SVC_UID=$(id -u svc_mist)
mkdir -p "/run/user/$SVC_UID"
chown svc_mist:svc_mist "/run/user/$SVC_UID" || true
chmod 700 "/run/user/$SVC_UID"

# Staging directory for image tarballs: svc_mist needs to read them but may
# not be able to traverse the caller's home directory (mode 700).  Use a
# location under /opt that we control; clean it up on any exit.
IMAGE_STAGE_DIR="/opt/mist-images-stage"
rm -rf "$IMAGE_STAGE_DIR"
mkdir -p "$IMAGE_STAGE_DIR"
chown svc_mist:svc_mist "$IMAGE_STAGE_DIR"
chmod 700 "$IMAGE_STAGE_DIR"
trap 'rm -rf "$IMAGE_STAGE_DIR"' EXIT

# ensure lingering so the user bus can start later
loginctl enable-linger svc_mist || true

# Docker install
if ! rpm -q docker-ce >/dev/null; then
  # always install from local downloads
  rpm_paths=("$DOWNLOAD_DIR"/containerd.io*.rpm "$DOWNLOAD_DIR"/docker-ce*.rpm "$DOWNLOAD_DIR"/docker-ce-cli*.rpm "$DOWNLOAD_DIR"/docker-compose-plugin*.rpm)
  dnf localinstall -y "${rpm_paths[@]}" || error_exit "Docker install failed"
  log "Installed Docker packages from downloads"
else
  log "Docker already installed; skipping"
fi

# Rootless Docker setup - this script requires it, so failure is fatal.
# Precondition: tool must be available, /run/user/<uid> must be writable,
# and subuid/subgid entries must exist for the service user.
SVC_UID=$(id -u svc_mist)
if ! command -v dockerd-rootless-setuptool.sh >/dev/null 2>&1; then
    error_exit "rootless Docker helper (dockerd-rootless-setuptool.sh) not installed"
fi
# ensure subuid/subgid entries for svc_mist
# Use usermod --add-subuids/subgids (shadow-utils >= 4.9, standard on RHEL 9)
# which handles file creation, newline safety, and duplicate detection.
if ! grep -q '^svc_mist:' /etc/subuid 2>/dev/null; then
    log "adding /etc/subuid entry for svc_mist"
    usermod --add-subuids 100000-165535 svc_mist
fi
if ! grep -q '^svc_mist:' /etc/subgid 2>/dev/null; then
    log "adding /etc/subgid entry for svc_mist"
    usermod --add-subgids 100000-165535 svc_mist
fi

# runtime directory used by rootless docker
XDG_RUNTIME_DIR="/run/user/$SVC_UID"
DOCKER_HOST="unix://$XDG_RUNTIME_DIR/docker.sock"

if [ ! -S "$XDG_RUNTIME_DIR/docker.sock" ]; then
    log "running rootless Docker setup for svc_mist"
    su - svc_mist <<'ROOTLESS'
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export DOCKER_HOST=unix:///run/user/$(id -u)/docker.sock
# ensure runtime dir exists and is owned by the user
mkdir -p "${XDG_RUNTIME_DIR}"
# start user bus; it's okay if this fails but continue
systemctl --user start dbus.socket || true
# perform the installation; let failure propagate
dockerd-rootless-setuptool.sh install || true
# enable and start the rootless docker user service
systemctl --user enable --now docker.service || true
ROOTLESS
    # verify socket now exists and is owned correctly
    if [ ! -S "$XDG_RUNTIME_DIR/docker.sock" ]; then
        error_exit "rootless Docker setup did not produce socket"
    fi
    owner=$(stat -c '%U' "$XDG_RUNTIME_DIR/docker.sock")
    if [ "$owner" != "svc_mist" ]; then
        error_exit "docker.sock owned by $owner instead of svc_mist"
    fi
    log "rootless Docker successfully set up as svc_mist"
else
    log "Rootless Docker already set up; skipping"
fi

loginctl enable-linger svc_mist || true

# if the caller asked only for an update, perform that and exit early
if [ "$ACTION" = update ]; then
  echo "Performing update for component '$COMP_TO_UPDATE'"
  # Stage and load images; copy only what is needed for this update.
  if [ "$COMP_TO_UPDATE" = prometheus ] || [ "$COMP_TO_UPDATE" = all ]; then
    cp "$DOWNLOAD_DIR/prometheus.tar" "$IMAGE_STAGE_DIR/" && chown svc_mist:svc_mist "$IMAGE_STAGE_DIR/prometheus.tar"
    su - svc_mist -c "export XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR DOCKER_HOST=$DOCKER_HOST && docker load -i $IMAGE_STAGE_DIR/prometheus.tar || true"
  fi
  if [ "$COMP_TO_UPDATE" = grafana ] || [ "$COMP_TO_UPDATE" = all ]; then
    cp "$DOWNLOAD_DIR/grafana.tar" "$IMAGE_STAGE_DIR/" && chown svc_mist:svc_mist "$IMAGE_STAGE_DIR/grafana.tar"
    su - svc_mist -c "export XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR DOCKER_HOST=$DOCKER_HOST && docker load -i $IMAGE_STAGE_DIR/grafana.tar || true"
  fi
  if [ "$COMP_TO_UPDATE" = loki ] || [ "$COMP_TO_UPDATE" = all ]; then
    cp "$DOWNLOAD_DIR/loki.tar" "$IMAGE_STAGE_DIR/" && chown svc_mist:svc_mist "$IMAGE_STAGE_DIR/loki.tar"
    su - svc_mist -c "export XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR DOCKER_HOST=$DOCKER_HOST && docker load -i $IMAGE_STAGE_DIR/loki.tar || true"
  fi
  if [ "$COMP_TO_UPDATE" = tempo ] || [ "$COMP_TO_UPDATE" = all ]; then
    cp "$DOWNLOAD_DIR/tempo.tar" "$IMAGE_STAGE_DIR/" && chown svc_mist:svc_mist "$IMAGE_STAGE_DIR/tempo.tar"
    su - svc_mist -c "export XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR DOCKER_HOST=$DOCKER_HOST && docker load -i $IMAGE_STAGE_DIR/tempo.tar || true"
  fi

  # restart/bring up requested services
  # prometheus and grafana have no profile (always start);
  # only loki and tempo are profile-gated in docker-compose.yml
  PROFILE_ARGS=""
  [ "$USE_LOKI" = yes ] && PROFILE_ARGS="$PROFILE_ARGS --profile loki"
  [ "$USE_TEMPO" = yes ] && PROFILE_ARGS="$PROFILE_ARGS --profile tempo"
  if [ "$COMP_TO_UPDATE" != all ]; then
    SERVICE_ARG="$COMP_TO_UPDATE"
  else
    SERVICE_ARG=""
  fi
  systemctl restart mist-server || \
    su - svc_mist -c "export XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR DOCKER_HOST=$DOCKER_HOST && cd $MIST_DIR && docker compose $PROFILE_ARGS up -d $SERVICE_ARG"
  echo "Update finished."
  exit 0
fi

# Load images (install/initial run) from tarballs only.  If svc_mist
# cannot talk to Docker at this point something is wrong with rootless.
if ! su - svc_mist -c "export XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR DOCKER_HOST=$DOCKER_HOST && docker version >/dev/null 2>&1"; then
    error_exit "svc_mist cannot access Docker daemon after rootless setup"
fi
# Copy tarballs to staging dir so svc_mist can read them regardless of the
# permissions on the directory the repo was cloned into.
[ "$USE_PROMETHEUS" = yes ] && cp "$DOWNLOAD_DIR/prometheus.tar" "$IMAGE_STAGE_DIR/"
cp "$DOWNLOAD_DIR/grafana.tar" "$IMAGE_STAGE_DIR/"
[ "$USE_LOKI" = yes ] && cp "$DOWNLOAD_DIR/loki.tar" "$IMAGE_STAGE_DIR/"
[ "$USE_TEMPO" = yes ] && cp "$DOWNLOAD_DIR/tempo.tar" "$IMAGE_STAGE_DIR/"
chown svc_mist:svc_mist "$IMAGE_STAGE_DIR"/*.tar
su - svc_mist <<LOAD
export XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR
export DOCKER_HOST=$DOCKER_HOST
[ "$USE_PROMETHEUS" = yes ] && docker load -i $IMAGE_STAGE_DIR/prometheus.tar || true
docker load -i $IMAGE_STAGE_DIR/grafana.tar || true
[ "$USE_LOKI" = yes ] && docker load -i $IMAGE_STAGE_DIR/loki.tar || true
[ "$USE_TEMPO" = yes ] && docker load -i $IMAGE_STAGE_DIR/tempo.tar || true
LOAD

# compute profile arguments for later use
# prometheus and grafana have no profile (always start);
# only loki and tempo are profile-gated in docker-compose.yml
PROFILE_ARGS=""
[ "$USE_LOKI" = yes ] && PROFILE_ARGS="$PROFILE_ARGS --profile loki"
[ "$USE_TEMPO" = yes ] && PROFILE_ARGS="$PROFILE_ARGS --profile tempo"

# Setup directories and copy only the templates needed for enabled components
mkdir -p $MIST_DIR

# Create data directories; these are owned by svc_mist and hold all
# persistent service state (prometheus TSDB, grafana DB, loki chunks, tempo traces).
mkdir -p "$DATA_DIR/prometheus" "$DATA_DIR/grafana" "$DATA_DIR/loki" "$DATA_DIR/tempo"
chown -R svc_mist:svc_mist "$DATA_DIR"
restorecon -Rv "$DATA_DIR" 2>/dev/null || true

# Write .env so Docker Compose can substitute ${MIST_DATA_DIR} in volume mounts
echo "MIST_DATA_DIR=$DATA_DIR" > "$MIST_DIR/.env"
chown svc_mist:svc_mist "$MIST_DIR/.env"

[ -f "$MIST_DIR/docker-compose.yml" ] || cp $BASE_DIR/configs/docker-compose.yml.template $MIST_DIR/docker-compose.yml

# prometheus is always present (USE_PROMETHEUS default yes)
if [ "$USE_PROMETHEUS" = yes ]; then
  mkdir -p $MIST_DIR/prometheus
  [ -f "$MIST_DIR/prometheus/prometheus.yml" ] && : || cp $BASE_DIR/configs/prometheus.yml.template "$MIST_DIR/prometheus/prometheus.yml"
fi

if [ "$USE_LOKI" = yes ]; then
  mkdir -p $MIST_DIR/loki
  [ -f "$MIST_DIR/loki/loki-config.yaml" ] || cp $BASE_DIR/configs/loki-config.yaml.template $MIST_DIR/loki/loki-config.yaml
fi

if [ "$USE_TEMPO" = yes ]; then
  mkdir -p $MIST_DIR/tempo
  [ -f "$MIST_DIR/tempo/tempo-config.yaml" ] || cp $BASE_DIR/configs/tempo-config.yaml.template $MIST_DIR/tempo/tempo-config.yaml
fi

chown -R svc_mist:svc_mist $MIST_DIR
restorecon -Rv $MIST_DIR

# Firewalld - open only ports for enabled services
ports="9090 3000"                         # prometheus + grafana
[ "$USE_LOKI" = yes ] && ports="$ports 3100"
if [ "$USE_TEMPO" = yes ]; then
  ports="$ports 3200 4317"
fi
for port in $ports; do
  firewall-cmd --permanent --query-port=$port/tcp >/dev/null || firewall-cmd --permanent --add-port=$port/tcp
done
firewall-cmd --reload

# Prometheus config — always regenerated from hosts file
PROM_YML="$MIST_DIR/prometheus/prometheus.yml"
[ -f "$PROM_YML" ] && cp "$PROM_YML" "$PROM_YML.bak"
cat > "$PROM_YML" <<YAML
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: 'node_exporter'
    static_configs:
      - targets:
YAML
while read -r host; do
  [ -z "$host" ] && continue
  echo "        - \"${host}:9100\"" >> "$PROM_YML"
done < "$HOSTS_FILE"
cat >> "$PROM_YML" <<YAML

  - job_name: 'alloy'
    static_configs:
      - targets:
YAML
while read -r host; do
  [ -z "$host" ] && continue
  echo "        - \"${host}:12345\"" >> "$PROM_YML"
done < "$HOSTS_FILE"
chown svc_mist:svc_mist "$PROM_YML"

# Verify docker compose is reachable before creating the service
mkdir -p "$XDG_RUNTIME_DIR"
chown svc_mist:svc_mist "$XDG_RUNTIME_DIR" || true
if ! su - svc_mist -c "export XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR DOCKER_HOST=$DOCKER_HOST && docker compose version >/dev/null 2>&1"; then
    error_exit "svc_mist cannot invoke docker compose; rootless daemon not operational"
fi

# Create a system-level service so root can manage the stack with systemctl.
# The unit runs as svc_mist but lives in the system service manager, meaning
# 'systemctl status/start/stop/restart mist-server' works for any admin.
cat > /etc/systemd/system/mist-server.service <<UNIT
[Unit]
Description=Mist observability stack (Prometheus, Grafana, etc.)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=svc_mist
Group=svc_mist
Environment=XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR
Environment=DOCKER_HOST=$DOCKER_HOST
WorkingDirectory=$MIST_DIR
ExecStart=/usr/bin/docker compose $PROFILE_ARGS up
ExecStop=/usr/bin/docker compose $PROFILE_ARGS down
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now mist-server

echo "Server deployment complete."
echo "Manage the stack with: systemctl status|start|stop|restart mist-server"
