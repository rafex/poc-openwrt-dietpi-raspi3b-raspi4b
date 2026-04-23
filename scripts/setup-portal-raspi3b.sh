#!/bin/bash
# Instala y despliega el nodo de portal liviano en Raspi 3B #2.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=./lib/raspi4b-common.sh
. "$SCRIPT_DIR/lib/raspi4b-common.sh"
# shellcheck source=./lib/topology-common.sh
. "$SCRIPT_DIR/lib/topology-common.sh"

parse_common_flags "$@"
init_log_dir "portal-node"
need_root
load_topology
ensure_topology_value >/dev/null || die "TOPOLOGY inválida: $TOPOLOGY"
[ "${#REM_ARGS[@]}" -eq 0 ] || die "Argumentos no soportados: ${REM_ARGS[*]}"

log_info "--- setup-portal-raspi3b ---"
log_info "Topología: $TOPOLOGY (portal_ip=${PORTAL_IP} ai_ip=${AI_IP})"

ensure_cmd bash

if ! $ONLY_VERIFY; then
  apt_install_pkgs podman curl ca-certificates
  run_cmd mkdir -p /etc/containers
  ensure_portal_ssh_key
  if ssh -i /opt/keys/captive-portal \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o BatchMode=yes \
      -o ConnectTimeout=5 \
      root@"${ROUTER_IP}" "echo ok" >/dev/null 2>&1; then
    log_ok "Llave captive-portal válida contra OpenWrt"
  else
    log_warn "La llave /opt/keys/captive-portal no está autorizada en OpenWrt. El registro podría fallar al autorizar clientes."
    log_warn "Solución: agrega /opt/keys/captive-portal.pub al router o ejecuta setup-openwrt.sh desde esta Raspi."
  fi
fi

if $DRY_RUN; then
  run_cmd env -u SETUP_LOG_INITIALIZED bash "$SCRIPT_DIR/portal-node-deploy.sh" --dry-run
  log_ok "Dry-run completado"
  exit 0
fi

if $ONLY_VERIFY; then
  env -u SETUP_LOG_INITIALIZED bash "$SCRIPT_DIR/portal-node-status.sh"
else
  env -u SETUP_LOG_INITIALIZED bash "$SCRIPT_DIR/portal-node-deploy.sh"
  env -u SETUP_LOG_INITIALIZED bash "$SCRIPT_DIR/portal-node-status.sh"
fi

log_ok "setup-portal-raspi3b completado"
