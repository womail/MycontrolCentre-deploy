#!/usr/bin/env bash
#
# MyControl Centre — create a Proxmox LXC and deploy the app natively (Node.js + SQLite).
#
# Run on a Proxmox VE node as root:
#
#   sudo bash scripts/proxmox-lxc-deploy.sh
#   sudo bash scripts/proxmox-lxc-deploy.sh --vmid 120 --ip 10.1.1.244/24 --gw 10.1.1.1
#   sudo bash scripts/proxmox-lxc-deploy.sh --source-dir /root/MycontrolCentre
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

VMID=""
HOSTNAME="mycontrol"
MEMORY=2048
CORES=2
DISK_GB=12
STORAGE="${PVE_STORAGE:-local-lvm}"
TEMPLATE_STORAGE="${PVE_TEMPLATE_STORAGE:-local}"
BRIDGE="${PVE_BRIDGE:-vmbr0}"
IP_MODE="dhcp"
IP_CIDR=""
GATEWAY=""
GIT_URL=""
GIT_BRANCH="main"
SOURCE_DIR=""
APP_PORT=3000
APP_USER="mcc"
INSTALL_DIR="/opt/mycontrol-centre"
SSH_PUBKEY=""
DESTROY=0
REDEPLOY_ONLY=0
SKIP_CREATE=0

usage() {
  cat <<'EOF'
Usage: proxmox-lxc-deploy.sh [options]

Create a Debian LXC on Proxmox and install MyControl Centre as a native Node.js app
(systemd service, SQLite under /opt/mycontrol-centre/.data).

Options:
  --vmid ID           Container ID (default: next free >= 100)
  --hostname NAME     LXC hostname (default: mycontrol)
  --memory MB         RAM in MiB (default: 2048)
  --cores N           CPU cores (default: 2)
  --disk GB           Root disk size in GiB (default: 12)
  --storage NAME      Rootfs storage (default: local-lvm or PVE_STORAGE)
  --bridge NAME       Network bridge (default: vmbr0 or PVE_BRIDGE)
  --ip CIDR           Static IP, e.g. 10.1.1.244/24 (default: DHCP)
  --gw ADDR           Default gateway (required with --ip)
  --git-url URL       Git clone URL (default: this repo's origin or GitHub)
  --git-branch NAME   Git branch (default: main)
  --source-dir PATH   Copy local checkout instead of git clone
  --app-port PORT     HTTP port (default: 3000)
  --ssh-pubkey KEY    Install SSH public key for root in the container
  --redeploy-only     Skip LXC creation; redeploy app into existing --vmid
  --destroy           Destroy existing container (--vmid required) and exit
  -h, --help          Show this help

Examples:
  # DHCP, auto VMID, clone from GitHub
  sudo bash scripts/proxmox-lxc-deploy.sh

  # Static IP on your LAN
  sudo bash scripts/proxmox-lxc-deploy.sh --vmid 120 --ip 10.1.1.244/24 --gw 10.1.1.1

  # Deploy current checkout from the Proxmox host
  sudo bash scripts/proxmox-lxc-deploy.sh --source-dir ~/MycontrolCentre

After deploy:
  curl -fsSL http://CONTAINER_IP:3000/api/health
  Login: admin / admin (change password on first login)
EOF
}

log()  { echo "==> $*"; }
warn() { echo "==> WARNING: $*" >&2; }
die()  { echo "ERROR: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vmid)         VMID="${2:?}"; shift 2 ;;
    --hostname)     HOSTNAME="${2:?}"; shift 2 ;;
    --memory)       MEMORY="${2:?}"; shift 2 ;;
    --cores)        CORES="${2:?}"; shift 2 ;;
    --disk)         DISK_GB="${2:?}"; shift 2 ;;
    --storage)      STORAGE="${2:?}"; shift 2 ;;
    --bridge)       BRIDGE="${2:?}"; shift 2 ;;
    --ip)           IP_CIDR="${2:?}"; IP_MODE="static"; shift 2 ;;
    --gw)           GATEWAY="${2:?}"; shift 2 ;;
    --git-url)      GIT_URL="${2:?}"; shift 2 ;;
    --git-branch)   GIT_BRANCH="${2:?}"; shift 2 ;;
    --source-dir)   SOURCE_DIR="${2:?}"; shift 2 ;;
    --app-port)     APP_PORT="${2:?}"; shift 2 ;;
    --ssh-pubkey)   SSH_PUBKEY="${2:?}"; shift 2 ;;
    --redeploy-only) REDEPLOY_ONLY=1; shift ;;
    --destroy)      DESTROY=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *) die "Unknown option: $1 (try --help)" ;;
  esac
done

[[ "$(id -u)" -eq 0 ]] || die "Run as root on the Proxmox node (sudo bash $0 ...)"

command -v pct >/dev/null 2>&1 || die "pct not found — is this a Proxmox VE host?"
command -v pveam >/dev/null 2>&1 || die "pveam not found — is this a Proxmox VE host?"

if [[ "$IP_MODE" == "static" && -z "$IP_CIDR" ]]; then
  die "--ip requires a CIDR, e.g. 10.1.1.244/24"
fi
if [[ "$IP_MODE" == "static" && -z "$GATEWAY" ]]; then
  die "Static --ip requires --gw"
fi
if [[ -n "$SOURCE_DIR" && ! -d "$SOURCE_DIR" ]]; then
  die "Source directory not found: $SOURCE_DIR"
fi
if [[ "$DESTROY" -eq 1 && -z "$VMID" ]]; then
  die "--destroy requires --vmid"
fi

default_git_url() {
  if [[ -n "$GIT_URL" ]]; then
    echo "$GIT_URL"
    return
  fi
  local url
  url="$(git -C "$PROJECT_ROOT" remote get-url origin 2>/dev/null || true)"
  case "$url" in
    git@github.com:*)
      echo "https://github.com/${url#git@github.com:}" | sed 's|\.git$||'
      ;;
    http*|https*)
      echo "$url" | sed 's|\.git$||'
      ;;
    *)
      echo "https://github.com/womail/MycontrolCentre"
      ;;
  esac
}

next_free_vmid() {
  local id=100
  while pct status "$id" &>/dev/null || qm status "$id" &>/dev/null 2>&1; do
    id=$((id + 1))
  done
  echo "$id"
}

find_debian_template() {
  local line
  line="$(pveam list "$TEMPLATE_STORAGE" 2>/dev/null | awk '/debian-12-standard/ {print $2}' | sort -V | tail -1 || true)"
  if [[ -n "$line" ]]; then
    echo "${TEMPLATE_STORAGE}:vztmpl/${line}"
    return
  fi
  line="$(pveam list "$TEMPLATE_STORAGE" 2>/dev/null | awk '/debian-11-standard/ {print $2}' | sort -V | tail -1 || true)"
  if [[ -n "$line" ]]; then
    warn "Debian 12 template not found; using ${line}"
    echo "${TEMPLATE_STORAGE}:vztmpl/${line}"
    return
  fi
  echo ""
}

ensure_template() {
  local tpl
  tpl="$(find_debian_template)"
  if [[ -n "$tpl" ]]; then
    echo "$tpl"
    return
  fi
  log "Downloading Debian 12 standard template to ${TEMPLATE_STORAGE}..."
  pveam update
  local candidate=""
  candidate="$(pveam available --section system 2>/dev/null | awk '/debian-12-standard/ {print $2}' | sort -V | tail -1 || true)"
  [[ -n "$candidate" ]] || die "Could not find debian-12-standard in pveam available list"
  pveam download "$TEMPLATE_STORAGE" "$candidate"
  echo "${TEMPLATE_STORAGE}:vztmpl/${candidate}"
}

container_ip() {
  if [[ "$IP_MODE" == "static" ]]; then
    echo "${IP_CIDR%%/*}"
    return
  fi
  local ip=""
  for _ in $(seq 1 30); do
    ip="$(pct exec "$VMID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"
    [[ -n "$ip" ]] && break
    sleep 2
  done
  echo "$ip"
}

wait_container_ready() {
  log "Waiting for container ${VMID} to accept commands..."
  for _ in $(seq 1 60); do
    if pct exec "$VMID" -- true 2>/dev/null; then
      return 0
    fi
    sleep 2
  done
  die "Container ${VMID} did not become ready"
}

destroy_container() {
  if pct status "$VMID" &>/dev/null; then
    log "Destroying container ${VMID}..."
    pct stop "$VMID" 2>/dev/null || true
    sleep 2
    pct destroy "$VMID"
    log "Container ${VMID} destroyed"
  else
    warn "Container ${VMID} does not exist"
  fi
}

create_container() {
  local template net0
  template="$(ensure_template)"
  log "Using template: ${template}"

  if [[ "$IP_MODE" == "dhcp" ]]; then
    net0="name=eth0,bridge=${BRIDGE},ip=dhcp"
  else
    net0="name=eth0,bridge=${BRIDGE},ip=${IP_CIDR},gw=${GATEWAY}"
  fi

  log "Creating LXC ${VMID} (${HOSTNAME}) — ${MEMORY}MiB RAM, ${CORES} cores, ${DISK_GB}G disk..."
  pct create "$VMID" "$template" \
    --hostname "$HOSTNAME" \
    --memory "$MEMORY" \
    --cores "$CORES" \
    --rootfs "${STORAGE}:${DISK_GB}" \
    --net0 "$net0" \
    --features nesting=1 \
    --onboot 1 \
    --unprivileged 1

  log "Starting container ${VMID}..."
  pct start "$VMID"
  wait_container_ready
}

copy_source_into_container() {
  log "Copying source from ${SOURCE_DIR} into ${INSTALL_DIR}..."
  pct exec "$VMID" -- mkdir -p "$INSTALL_DIR"
  tar -C "$SOURCE_DIR" \
    --exclude=.git \
    --exclude=node_modules \
    --exclude=.next \
    --exclude=.data \
    --exclude=.run \
    --exclude=.logs \
    -cf - . | pct exec "$VMID" -- tar -xf - -C "$INSTALL_DIR"
}

deploy_application() {
  local git_url app_url ct_ip
  git_url="$(default_git_url)"

  log "Installing OS packages and Node.js inside container ${VMID}..."
  pct exec "$VMID" -- bash -s <<'EOS'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y curl ca-certificates git openssl build-essential python3 sudo
if ! command -v node >/dev/null 2>&1 || [[ "$(node -p "process.versions.node.split('.')[0]")" -lt 20 ]]; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y nodejs
fi
node -v
npm -v
EOS

  pct exec "$VMID" -- mkdir -p "$INSTALL_DIR"
  pct exec "$VMID" -- rm -rf "${INSTALL_DIR:?}/"*

  if [[ -n "$SOURCE_DIR" ]]; then
    copy_source_into_container
  else
    log "Cloning ${git_url} (branch ${GIT_BRANCH})..."
    pct exec "$VMID" -- bash -s <<EOS
set -euo pipefail
git clone --depth 1 --branch "${GIT_BRANCH}" "${git_url}" "${INSTALL_DIR}"
EOS
  fi

  if [[ -n "$SSH_PUBKEY" ]]; then
    pct exec "$VMID" -- env MCC_PUBKEY="$SSH_PUBKEY" bash -s <<'EOS'
set -euo pipefail
mkdir -p /root/.ssh
chmod 700 /root/.ssh
touch /root/.ssh/authorized_keys
grep -qxF "$MCC_PUBKEY" /root/.ssh/authorized_keys 2>/dev/null || printf '%s\n' "$MCC_PUBKEY" >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
EOS
  fi

  ct_ip="$(container_ip)"
  [[ -n "$ct_ip" ]] || die "Could not determine container IP — set --ip or check DHCP"
  app_url="http://${ct_ip}:${APP_PORT}"

  log "Building app (APP_URL=${app_url})..."
  pct exec "$VMID" -- bash -s <<EOS
set -euo pipefail
id -u ${APP_USER} >/dev/null 2>&1 || useradd --system --home ${INSTALL_DIR} --shell /usr/sbin/nologin ${APP_USER}
mkdir -p ${INSTALL_DIR}/.data
chown -R ${APP_USER}:${APP_USER} ${INSTALL_DIR}

if [[ ! -f ${INSTALL_DIR}/.env ]]; then
  cp ${INSTALL_DIR}/.env.example ${INSTALL_DIR}/.env
fi

set_env() {
  local key="\$1" val="\$2" file="${INSTALL_DIR}/.env"
  if grep -q "^\${key}=" "\$file"; then
    sed -i "s|^\${key}=.*|\${key}=\"\${val}\"|" "\$file"
  else
    echo "\${key}=\"\${val}\"" >> "\$file"
  fi
}

set_env DATABASE_URL "file:../.data/mycontrol.db"
set_env APP_URL "${app_url}"
set_env SESSION_COOKIE_SECURE "false"
set_env RUN_EMBEDDED_WORKER "true"

if grep -q '^SESSION_SECRET="change-me' ${INSTALL_DIR}/.env || ! grep -q '^SESSION_SECRET=' ${INSTALL_DIR}/.env; then
  set_env SESSION_SECRET "\$(openssl rand -base64 32)"
fi
if grep -q '^ENCRYPTION_KEY="change-me' ${INSTALL_DIR}/.env || ! grep -q '^ENCRYPTION_KEY=' ${INSTALL_DIR}/.env; then
  set_env ENCRYPTION_KEY "\$(openssl rand -base64 32)"
fi

chown ${APP_USER}:${APP_USER} ${INSTALL_DIR}/.env

cd ${INSTALL_DIR}
sudo -u ${APP_USER} npm ci
sudo -u ${APP_USER} npx prisma generate
sudo -u ${APP_USER} npx prisma db push
sudo -u ${APP_USER} npm run db:repair
sudo -u ${APP_USER} npm run db:seed
sudo -u ${APP_USER} env NODE_ENV=production npm run build
EOS

  log "Installing systemd service..."
  pct exec "$VMID" -- bash -s <<EOS
set -euo pipefail
cat > /etc/systemd/system/mycontrol-centre.service <<'UNIT'
[Unit]
Description=MyControl Centre
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${INSTALL_DIR}
Environment=NODE_ENV=production
Environment=PORT=${APP_PORT}
EnvironmentFile=${INSTALL_DIR}/.env
ExecStart=/usr/bin/npm run start
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable mycontrol-centre.service
systemctl restart mycontrol-centre.service
EOS

  log "Waiting for health endpoint..."
  for _ in $(seq 1 30); do
    if curl -fsS --connect-timeout 3 "${app_url}/api/health" >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done

  cat <<EOF

=== MyControl Centre deployed ===
  VMID:     ${VMID}
  Hostname: ${HOSTNAME}
  URL:      ${app_url}
  Health:   curl -fsSL ${app_url}/api/health
  Login:    admin / admin (change password on first login)
  App dir:  ${INSTALL_DIR}
  Logs:     pct exec ${VMID} -- journalctl -u mycontrol-centre -f
  Shell:    pct enter ${VMID}
  Redeploy: sudo bash $0 --vmid ${VMID} --redeploy-only

Set APP_URL in Settings if you will use a DNS name or reverse proxy in front of this IP.
Proxmox hosts must reach ${app_url} for SSH setup / enrollment curl commands.

EOF
}

# --- main ---

if [[ "$DESTROY" -eq 1 ]]; then
  destroy_container
  exit 0
fi

if [[ -z "$VMID" ]]; then
  VMID="$(next_free_vmid)"
  log "Using next free VMID: ${VMID}"
fi

if [[ "$REDEPLOY_ONLY" -eq 1 ]]; then
  pct status "$VMID" &>/dev/null || die "Container ${VMID} not found (--redeploy-only)"
  pct start "$VMID" 2>/dev/null || true
  wait_container_ready
else
  if pct status "$VMID" &>/dev/null; then
    die "VMID ${VMID} already exists — pick another --vmid or use --redeploy-only / --destroy"
  fi
  create_container
fi

deploy_application
