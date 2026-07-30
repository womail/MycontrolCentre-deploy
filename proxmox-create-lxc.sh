#!/usr/bin/env bash
#
# MyControl Centre — Proxmox VE Helper Scripts (community-scripts) CT entry.
#
# Public one-liner (Proxmox shell, as root):
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/womail/MycontrolCentre-deploy/main/proxmox-create-lxc.sh)"
#
# If raw.githubusercontent.com is blocked or cached, use jsDelivr:
#
#   bash -c "$(curl -fsSL https://cdn.jsdelivr.net/gh/womail/MycontrolCentre-deploy@main/proxmox-create-lxc.sh)"
#
# Advanced wizard:
#   mode=advanced bash -c "$(curl -fsSL https://raw.githubusercontent.com/womail/MycontrolCentre-deploy/main/proxmox-create-lxc.sh)"
#
# Source defaults to a public tarball on MycontrolCentre-deploy (no GitHub token needed).
# Override: MCC_USE_GIT=1 MCC_GIT_URL='https://x-access-token:TOKEN@github.com/...' bash -c "$(curl -fsSL ...)"
#
# Canonical copy: https://github.com/womail/MycontrolCentre-deploy
# Docs: https://community-scripts.org/docs/ct/readme
#
# Copyright (c) 2021-2026 MyControl Centre contributors
# License: MIT — uses community-scripts build.func (MIT)

MCC_SCRIPT_REV="5"
echo "MyControl Centre LXC installer (rev ${MCC_SCRIPT_REV})"

MCC_DEPLOY_RAW="${MCC_DEPLOY_RAW:-https://raw.githubusercontent.com/womail/MycontrolCentre-deploy/main}"
MCC_INSTALL_REL="community-scripts/install/mycontrol-centre-install.sh"

# ProxmoxVED base for build.func + misc/*.func (never point this at MycontrolCentre-deploy).
_CS_MIRROR="${COMMUNITY_SCRIPTS_MIRROR:-https://git.community-scripts.org/community-scripts/ProxmoxVED/raw/branch/main}"
_CS_GITHUB="${COMMUNITY_SCRIPTS_GITHUB:-https://raw.githubusercontent.com/community-scripts/ProxmoxVED/main}"
_CS_CDN="${COMMUNITY_SCRIPTS_CDN:-https://cdn.jsdelivr.net/gh/community-scripts/ProxmoxVED@main}"
export COMMUNITY_SCRIPTS_URL="${COMMUNITY_SCRIPTS_URL:-${_CS_MIRROR}}"

mcc_fetch() {
  local dest="$1"
  shift
  local url
  for url in "$@"; do
    if curl -fsSL "$url" -o "$dest" 2>/dev/null; then
      return 0
    fi
    echo "WARN: fetch failed: ${url}" >&2
  done
  return 1
}

_build_func_tmp="$(mktemp /tmp/mcc-build.func.XXXXXX)"
trap 'rm -f "${_build_func_tmp:-}"; rm -rf "${_mcc_install_root:-}"' EXIT

if ! mcc_fetch "$_build_func_tmp" \
  "${_CS_MIRROR}/misc/build.func" \
  "${_CS_GITHUB}/misc/build.func" \
  "${_CS_CDN}/misc/build.func"; then
  echo "ERROR: Failed to download community-scripts build.func (tried mirror, GitHub raw, jsDelivr)." >&2
  exit 1
fi
# shellcheck disable=SC1090
if ! source "$_build_func_tmp"; then
  echo "ERROR: Failed to source community-scripts build.func." >&2
  exit 1
fi
if ! declare -f is_incus_lxc_backend >/dev/null 2>&1 || ! declare -f header_info >/dev/null 2>&1; then
  echo "ERROR: community-scripts build.func did not load completely." >&2
  echo "       Set COMMUNITY_SCRIPTS_MIRROR to a reachable ProxmoxVED raw base and retry." >&2
  exit 1
fi

# Install script lives in the public deploy repo; prefetch for _cs_fetch_text via COMMUNITY_SCRIPTS_ROOT.
_mcc_install_root="$(mktemp -d /tmp/mcc-cs-root.XXXXXX)"
mkdir -p "${_mcc_install_root}/install"
if ! mcc_fetch "${_mcc_install_root}/install/mycontrol-centre-install.sh" \
  "${MCC_DEPLOY_RAW}/${MCC_INSTALL_REL}" \
  "https://cdn.jsdelivr.net/gh/womail/MycontrolCentre-deploy@main/${MCC_INSTALL_REL}"; then
  echo "ERROR: Failed to download install script from deploy repo." >&2
  exit 1
fi
MCC_TARBALL_DEFAULT="${MCC_DEPLOY_RAW}/artifacts/mycontrol-centre.tar.gz"
_mcc_install_tmp="$(mktemp "${_mcc_install_root}/install/mycontrol-centre-install.XXXXXX")"
{
  printf 'export MCC_TARBALL_URL=%q\n' "${MCC_TARBALL_URL:-${MCC_TARBALL_DEFAULT}}"
  printf 'export MCC_GIT_URL=%q\n' "${MCC_GIT_URL:-https://github.com/womail/MycontrolCentre.git}"
  printf 'export MCC_GIT_BRANCH=%q\n' "${MCC_GIT_BRANCH:-main}"
  printf 'export MCC_USE_GIT=%q\n' "${MCC_USE_GIT:-0}"
  cat "${_mcc_install_root}/install/mycontrol-centre-install.sh"
} >"${_mcc_install_tmp}"
mv "${_mcc_install_tmp}" "${_mcc_install_root}/install/mycontrol-centre-install.sh"
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
