#!/usr/bin/env bash
#
# MyControl Centre — Proxmox VE Helper Scripts (community-scripts) CT entry.
#
# Run on the Proxmox shell as root:
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/womail/MycontrolCentre-deploy/main/proxmox-create-lxc.sh)"
#
# Advanced wizard (all prompts):
#   mode=advanced bash -c "$(curl -fsSL https://raw.githubusercontent.com/womail/MycontrolCentre-deploy/main/proxmox-create-lxc.sh)"
#
# Docs: https://community-scripts.org/docs/ct/readme
# Deploy scripts repo: https://github.com/womail/MycontrolCentre-deploy
#
# Copyright (c) 2021-2026 MyControl Centre contributors
# License: MIT — uses community-scripts build.func (MIT)

MCC_DEPLOY_RAW="${MCC_DEPLOY_RAW:-https://raw.githubusercontent.com/womail/MycontrolCentre-deploy/main}"
export COMMUNITY_SCRIPTS_URL="${MCC_SCRIPTS_URL:-${MCC_DEPLOY_RAW}/community-scripts}"

BUILD_FUNC_URL="${COMMUNITY_SCRIPTS_BUILD_URL:-https://raw.githubusercontent.com/community-scripts/ProxmoxVED/main}/misc/build.func"
if ! source <(curl -fsSL "$BUILD_FUNC_URL"); then
  echo "ERROR: Failed to download community-scripts build.func from ${BUILD_FUNC_URL}" >&2
  exit 1
fi

APP="MyControl-Centre"
var_tags="${var_tags:-control;automation;proxmox;ssh}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-2048}"
var_disk="${var_disk:-12}"
var_os="${var_os:-debian}"
var_version="${var_version:-12}"
var_unprivileged="${var_unprivileged:-1}"
var_nesting="${var_nesting:-1}"
var_arm64="${var_arm64:-no}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  if [[ ! -d /opt/mycontrol-centre ]]; then
    msg_error "No ${APP} installation found under /opt/mycontrol-centre"
    exit
  fi

  msg_info "Updating ${APP}"
  cd /opt/mycontrol-centre
  $STD git fetch origin
  $STD git pull --ff-only
  $STD npm ci
  $STD npx prisma generate
  $STD npx prisma db push
  $STD npm run db:repair
  $STD env NODE_ENV=production npm run build
  systemctl restart mycontrol-centre
  msg_ok "Updated ${APP}"
  cleanup_lxc
  exit
}

start
build_container
description

msg_ok "Completed Successfully!"
msg_custom "🚀" "${GN}" "${APP} setup has been successfully initialized!"
echo -e "${INFO}${YW} Access it using:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:3000${CL}"
echo -e "${INFO}${YW} Default login: admin / admin (change on first sign-in)${CL}"
echo -e "${INFO}${YW} Health check: curl -fsSL http://${IP}:3000/api/health${CL}"
