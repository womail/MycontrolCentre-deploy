#!/usr/bin/env bash
#
# MyControl Centre — Proxmox VE Helper Scripts (community-scripts) CT entry.
#
# Public one-liner (Proxmox shell, as root):
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/womail/MycontrolCentre-deploy/main/proxmox-create-lxc.sh)"
#
# Advanced wizard:
#   mode=advanced bash -c "$(curl -fsSL https://raw.githubusercontent.com/womail/MycontrolCentre-deploy/main/proxmox-create-lxc.sh)"
#
# Private app repo (inside the CT after creation):
#   MCC_GIT_URL='https://github.com/you/MycontrolCentre.git' bash -c "$(curl -fsSL ...)"
#
# Canonical copy: https://github.com/womail/MycontrolCentre-deploy
# Docs: https://community-scripts.org/docs/ct/readme
#
# Copyright (c) 2021-2026 MyControl Centre contributors
# License: MIT — uses community-scripts build.func (MIT)

MCC_DEPLOY_RAW="${MCC_DEPLOY_RAW:-https://raw.githubusercontent.com/womail/MycontrolCentre-deploy/main}"
MCC_INSTALL_REL="community-scripts/install/mycontrol-centre-install.sh"

# build.func + misc/*.func must come from ProxmoxVED — do NOT point COMMUNITY_SCRIPTS_URL at the deploy repo.
BUILD_FUNC_URL="${COMMUNITY_SCRIPTS_BUILD_URL:-https://raw.githubusercontent.com/community-scripts/ProxmoxVED/main}/misc/build.func"
if ! source <(curl -fsSL "$BUILD_FUNC_URL"); then
  echo "ERROR: Failed to download community-scripts build.func from ${BUILD_FUNC_URL}" >&2
  exit 1
fi
if ! declare -f is_incus_lxc_backend >/dev/null 2>&1 || ! declare -f header_info >/dev/null 2>&1; then
  echo "ERROR: community-scripts build.func did not load completely (network or ${BUILD_FUNC_URL})." >&2
  exit 1
fi

# Install script lives in the public deploy repo; prefetch for _cs_fetch_text via COMMUNITY_SCRIPTS_ROOT.
_mcc_install_root="$(mktemp -d /tmp/mcc-cs-root.XXXXXX)"
trap 'rm -rf "${_mcc_install_root:-}"' EXIT
mkdir -p "${_mcc_install_root}/install"
if ! curl -fsSL "${MCC_DEPLOY_RAW}/${MCC_INSTALL_REL}" -o "${_mcc_install_root}/install/mycontrol-centre-install.sh"; then
  echo "ERROR: Failed to download install script from ${MCC_DEPLOY_RAW}/${MCC_INSTALL_REL}" >&2
  exit 1
fi
export COMMUNITY_SCRIPTS_ROOT="${_mcc_install_root}"

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
