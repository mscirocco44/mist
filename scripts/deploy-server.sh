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

show_usage() {
    cat <<'EOF'
Usage: ./deploy-server.sh [options] [hosts_file]

Options:
  --with-loki            enable Loki (disabled by default)
  --with-tempo           enable Tempo (disabled by default)
  --only-prometheus      install/prometheus only (disables loki and tempo)
  --update [component]   load updated image(s) and restart component(s)
                         component = prometheus|grafana|loki|tempo|all
  --help, -h             show this message

hosts_file: optional path containing client IPs/hostnames
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

# Determine the directory containing this script; do not rely on $PWD
# so that the installer works no matter where you invoke it from.  Using
# BASH_SOURCE is slightly more reliable when the script is sourced, but we
# always execute it directly.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DOWNLOAD_DIR="$BASE_DIR/downloads"

log "Base directory resolved to $BASE_DIR"
if [ ! -d "$DOWNLOAD_DIR" ]; then
    error_exit "downloads directory not found under $BASE_DIR.\n"\
               "Are you running the script from the top‑level of the unzipped repo?\n"\
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

# note: this installer is offline‑first and does not require network
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

# System prep – offline behaviour.  this script will not contact any
# remote repository.  it assumes the base OS is already functional; the
# only additional packages it needs are listed below.  if any are missing
# the script will abort and expect you to install them yourself (you may
# use RPMs from the downloads/ directory to do so).

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
restorecon -Rv /opt /etc /var

# Create svc_mist
id svc_mist &>/dev/null || useradd --system --no-create-home --shell /sbin/nologin svc_mist

# Docker install
if ! rpm -q docker-ce >/dev/null; then
  # always install from local downloads
  rpm_paths=("$DOWNLOAD_DIR"/containerd.io*.rpm "$DOWNLOAD_DIR"/docker-ce*.rpm "$DOWNLOAD_DIR"/docker-ce-cli*.rpm "$DOWNLOAD_DIR"/docker-compose-plugin*.rpm)
  dnf localinstall -y "${rpm_paths[@]}" || error_exit "Docker install failed"
  log "Installed Docker packages from downloads"
else
  log "Docker already installed; skipping"
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

# runtime directory used by rootless docker
XDG_RUNTIME_DIR="/run/user/$SVC_UID"

# if the caller asked only for an update, perform that and exit early
if [ "$ACTION" = update ]; then
  echo "Performing update for component '$COMP_TO_UPDATE'"
  # load images as needed
  if [ "$COMP_TO_UPDATE" = prometheus ] || [ "$COMP_TO_UPDATE" = all ]; then
    su - svc_mist -s /bin/bash -c "docker load -i $DOWNLOAD_DIR/prometheus.tar || true"
  fi
  if [ "$COMP_TO_UPDATE" = grafana ] || [ "$COMP_TO_UPDATE" = all ]; then
    su - svc_mist -s /bin/bash -c "docker load -i $DOWNLOAD_DIR/grafana.tar || true"
  fi
  if [ "$COMP_TO_UPDATE" = loki ] || [ "$COMP_TO_UPDATE" = all ]; then
    su - svc_mist -s /bin/bash -c "docker load -i $DOWNLOAD_DIR/loki.tar || true"
  fi
  if [ "$COMP_TO_UPDATE" = tempo ] || [ "$COMP_TO_UPDATE" = all ]; then
    su - svc_mist -s /bin/bash -c "docker load -i $DOWNLOAD_DIR/tempo.tar || true"
  fi

  # restart/bring up requested services
  PROFILE_ARGS=""
  # grafana always enabled
  PROFILE_ARGS="$PROFILE_ARGS --profile grafana"
  [ "$USE_LOKI" = yes ] && PROFILE_ARGS="$PROFILE_ARGS --profile loki"
  [ "$USE_TEMPO" = yes ] && PROFILE_ARGS="$PROFILE_ARGS --profile tempo"
  if [ "$COMP_TO_UPDATE" != all ]; then
    SERVICE_ARG="$COMP_TO_UPDATE"
  else
    SERVICE_ARG=""
  fi
  su - svc_mist -s /bin/bash -c "export XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR && cd $MIST_DIR && docker compose $PROFILE_ARGS up -d $SERVICE_ARG"
  echo "Update finished."
  exit 0
fi

# Load images (install/initial run) from tarballs only.
su - svc_mist -s /bin/bash <<'LOAD'
[ "$USE_PROMETHEUS" = yes ] && docker load -i $DOWNLOAD_DIR/prometheus.tar || true
# grafana always installed
docker load -i $DOWNLOAD_DIR/grafana.tar || true
[ "$USE_LOKI" = yes ] && docker load -i $DOWNLOAD_DIR/loki.tar || true
[ "$USE_TEMPO" = yes ] && docker load -i $DOWNLOAD_DIR/tempo.tar || true
LOAD

# compute profile arguments for later use (used both in install and updates)
PROFILE_ARGS=""
# grafana always enabled
PROFILE_ARGS="$PROFILE_ARGS --profile grafana"
[ "$USE_LOKI" = yes ] && PROFILE_ARGS="$PROFILE_ARGS --profile loki"
[ "$USE_TEMPO" = yes ] && PROFILE_ARGS="$PROFILE_ARGS --profile tempo"

# Setup directories and copy only the templates needed for enabled components
mkdir -p $MIST_DIR
chown -R svc_mist:svc_mist $MIST_DIR
restorecon -Rv $MIST_DIR

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

# Firewalld – open only ports for enabled services
ports="9090 3000"                         # prometheus + grafana
[ "$USE_LOKI" = yes ] && ports="$ports 3100"
if [ "$USE_TEMPO" = yes ]; then
  ports="$ports 3200 4317"
fi
for port in $ports; do
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
su - svc_mist -s /bin/bash -c "export XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR && cd $MIST_DIR && docker compose up -d $PROFILE_ARGS"

echo "Server deployment complete."