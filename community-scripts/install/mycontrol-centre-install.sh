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

msg_info "Cloning MyControl Centre"
MCC_GIT_URL="${MCC_GIT_URL:-https://github.com/womail/MycontrolCentre.git}"
MCC_GIT_BRANCH="${MCC_GIT_BRANCH:-main}"
$STD git clone --depth 1 --branch "${MCC_GIT_BRANCH}" "${MCC_GIT_URL}" /opt/mycontrol-centre
msg_ok "Cloned MyControl Centre"

msg_info "Configuring Environment"
cd /opt/mycontrol-centre
cp .env.example .env

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

git -C /opt/mycontrol-centre rev-parse --short HEAD >~/.mycontrol-centre

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
