#!/usr/bin/env bash
#
# MyControl Centre — native install on a Debian 12 VM (Proxmox or any hypervisor).
#
# Run inside the VM as root after first boot:
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/womail/MycontrolCentre-deploy/main/proxmox-vm-install.sh)"
#
# Docs: docs/proxmox-vm-install.md
#
set -euo pipefail

INSTALL_DIR="${MCC_INSTALL_DIR:-/opt/mycontrol-centre}"
MCC_TARBALL_URL="${MCC_TARBALL_URL:-https://raw.githubusercontent.com/womail/MycontrolCentre-deploy/main/artifacts/mycontrol-centre.tar.gz}"
MCC_ENV_EXAMPLE_URL="${MCC_ENV_EXAMPLE_URL:-https://raw.githubusercontent.com/womail/MycontrolCentre-deploy/main/artifacts/env.example}"
APP_PORT="${MCC_APP_PORT:-3000}"

log() { echo "==> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || die "Run as root"

export DEBIAN_FRONTEND=noninteractive

log "Updating package lists"
apt-get update
apt-get install -y curl ca-certificates git openssl build-essential python3

if ! command -v node >/dev/null 2>&1 || [[ "$(node -p "process.versions.node.split('.')[0]")" -lt 20 ]]; then
  log "Installing Node.js 22"
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y nodejs
fi
log "Node $(node -v)"

local_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
[[ -n "${local_ip}" ]] || die "Could not detect VM IP address"

if [[ -f "${INSTALL_DIR}/package.json" && -f "${INSTALL_DIR}/.env.example" ]]; then
  log "Using existing ${INSTALL_DIR}"
else
  log "Fetching application tarball"
  rm -rf "${INSTALL_DIR}"
  mkdir -p "${INSTALL_DIR}"
  curl -fsSL "${MCC_TARBALL_URL}" | tar -xz -C "${INSTALL_DIR}" \
    || die "Failed to download ${MCC_TARBALL_URL}"
fi

cd "${INSTALL_DIR}"

if [[ ! -f .env.example ]]; then
  log "Fetching .env.example"
  curl -fsSL "${MCC_ENV_EXAMPLE_URL}" -o .env.example \
    || die "Failed to download ${MCC_ENV_EXAMPLE_URL}"
fi

log "Configuring environment"
cp -f .env.example .env

set_env() {
  local key="$1" val="$2"
  if grep -q "^${key}=" .env; then
    sed -i "s|^${key}=.*|${key}=\"${val}\"|" .env
  else
    echo "${key}=\"${val}\"" >> .env
  fi
}

set_env DATABASE_URL "file:../.data/mycontrol.db"
set_env APP_URL "http://${local_ip}:${APP_PORT}"
set_env SESSION_COOKIE_SECURE "false"
set_env RUN_EMBEDDED_WORKER "true"
set_env SESSION_SECRET "$(openssl rand -base64 32)"
set_env ENCRYPTION_KEY "$(openssl rand -base64 32)"

mkdir -p "${INSTALL_DIR}/.data"

log "Installing npm dependencies"
npm ci
npx prisma generate
npx prisma db push
npm run db:repair
npm run db:seed

log "Building application"
env NODE_ENV=production npm run build

log "Creating systemd service"
cat > /etc/systemd/system/mycontrol-centre.service <<EOF
[Unit]
Description=MyControl Centre
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
Environment=NODE_ENV=production
Environment=PORT=${APP_PORT}
EnvironmentFile=${INSTALL_DIR}/.env
ExecStart=/usr/bin/npm run start
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now mycontrol-centre

log "Done"
echo ""
echo "  URL:    http://${local_ip}:${APP_PORT}"
echo "  Login:  admin / admin  (change on first sign-in)"
echo "  Health: curl -fsSL http://${local_ip}:${APP_PORT}/api/health"
echo ""
