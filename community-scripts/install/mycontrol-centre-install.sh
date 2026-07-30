#!/usr/bin/env bash

# Copyright (c) 2021-2026 MyControl Centre contributors
# License: MIT | https://github.com/womail/MycontrolCentre/blob/main/LICENSE
# Source: https://github.com/womail/MycontrolCentre

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing Dependencies"
$STD apt-get install -y curl git ca-certificates openssl build-essential python3
msg_ok "Installed Dependencies"

msg_info "Installing Node.js"
NODE_VERSION="22" setup_nodejs
msg_ok "Installed Node.js"

msg_info "Fetching MyControl Centre"
MCC_TARBALL_URL="${MCC_TARBALL_URL:-https://raw.githubusercontent.com/womail/MycontrolCentre-deploy/main/artifacts/mycontrol-centre.tar.gz}"
MCC_GIT_URL="${MCC_GIT_URL:-https://github.com/womail/MycontrolCentre.git}"
MCC_GIT_BRANCH="${MCC_GIT_BRANCH:-main}"
MCC_USE_GIT="${MCC_USE_GIT:-0}"
export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=/bin/false

mcc_fetch_source() {
  if [[ -d /opt/mycontrol-centre/.git || -f /opt/mycontrol-centre/package.json ]]; then
    msg_ok "Using existing /opt/mycontrol-centre checkout"
    return 0
  fi
  $STD rm -rf /opt/mycontrol-centre
  $STD mkdir -p /opt/mycontrol-centre

  if [[ "${MCC_USE_GIT}" == "1" ]]; then
    $STD git clone --depth 1 --branch "${MCC_GIT_BRANCH}" "${MCC_GIT_URL}" /opt/mycontrol-centre
    return 0
  fi

  if [[ -n "${MCC_TARBALL_URL:-}" ]] && curl -fsSL "${MCC_TARBALL_URL}" | $STD tar -xz -C /opt/mycontrol-centre; then
    return 0
  fi

  msg_info "Public tarball unavailable; trying git clone"
  $STD rm -rf /opt/mycontrol-centre
  if ! $STD git clone --depth 1 --branch "${MCC_GIT_BRANCH}" "${MCC_GIT_URL}" /opt/mycontrol-centre; then
    msg_error "Could not fetch MyControl Centre source"
    msg_error "Ensure ${MCC_TARBALL_URL} exists (CI publish to MycontrolCentre-deploy), or run with:"
    msg_error "  MCC_GIT_URL='https://x-access-token:TOKEN@github.com/womail/MycontrolCentre.git' MCC_USE_GIT=1 bash -c \"\$(curl -fsSL ...)\""
    exit 1
  fi
}

if ! mcc_fetch_source; then
  msg_error "Could not fetch MyControl Centre source"
  exit 1
fi
msg_ok "Fetched MyControl Centre"

msg_info "Configuring Environment"
cd /opt/mycontrol-centre
if [[ ! -f .env.example ]]; then
  msg_error ".env.example missing from source package (re-publish deploy tarball)"
  exit 1
fi
$STD cp -f .env.example .env

set_env() {
  local key="$1"
  local val="$2"
  if grep -q "^${key}=" .env; then
    sed -i "s|^${key}=.*|${key}=\"${val}\"|" .env
  else
    echo "${key}=\"${val}\"" >> .env
  fi
}

set_env DATABASE_URL "file:../.data/mycontrol.db"
set_env APP_URL "http://${LOCAL_IP}:3000"
set_env SESSION_COOKIE_SECURE "false"
set_env RUN_EMBEDDED_WORKER "true"
set_env SESSION_SECRET "$(openssl rand -base64 32)"
set_env ENCRYPTION_KEY "$(openssl rand -base64 32)"
msg_ok "Configured Environment"

msg_info "Installing Application"
$STD npm ci
$STD npx prisma generate
$STD npx prisma db push
$STD npm run db:repair
$STD npm run db:seed
msg_ok "Installed Application"

msg_info "Building Application"
$STD env NODE_ENV=production npm run build
msg_ok "Built Application"

if [[ -f /opt/mycontrol-centre/.mcc-source-sha ]]; then
  head -c 7 /opt/mycontrol-centre/.mcc-source-sha >~/.mycontrol-centre
elif git -C /opt/mycontrol-centre rev-parse --short HEAD >/dev/null 2>&1; then
  git -C /opt/mycontrol-centre rev-parse --short HEAD >~/.mycontrol-centre
else
  echo unknown >~/.mycontrol-centre
fi

msg_info "Creating Service"
cat <<'EOF' >/etc/systemd/system/mycontrol-centre.service
[Unit]
Description=MyControl Centre
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/mycontrol-centre
Environment=NODE_ENV=production
Environment=PORT=3000
EnvironmentFile=/opt/mycontrol-centre/.env
ExecStart=/usr/bin/npm run start
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl enable -q --now mycontrol-centre
msg_ok "Created Service"

motd_ssh
customize
cleanup_lxc
