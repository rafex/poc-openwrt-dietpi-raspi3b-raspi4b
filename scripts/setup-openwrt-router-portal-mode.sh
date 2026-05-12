#!/bin/bash
# setup-openwrt-router-portal-mode.sh
# Configura modo "portal en router + openNDS + backend remoto en Raspi3B-sensor".
#
# No reemplaza los modos previos; es una alternativa adicional.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=./lib/raspi4b-common.sh
. "$SCRIPT_DIR/lib/raspi4b-common.sh"
# shellcheck source=./lib/topology-common.sh
. "$SCRIPT_DIR/lib/topology-common.sh"
# shellcheck source=./lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

BACKEND_IP=""
RUN_KEYS=true

parse_common_flags "$@"
ARGS=("${REM_ARGS[@]}")
REM_ARGS=()
for a in "${ARGS[@]}"; do
  case "$a" in
    --backend-ip=*) BACKEND_IP="${a#*=}" ;;
    --no-keys) RUN_KEYS=false ;;
    *) REM_ARGS+=("$a") ;;
  esac
done

init_log_dir "openwrt-router-portal-mode"
need_root
load_topology
ensure_topology_value >/dev/null || die "TOPOLOGY inválida: $TOPOLOGY"
[ "${#REM_ARGS[@]}" -eq 0 ] || die "Argumentos no soportados: ${REM_ARGS[*]}"

BACKEND_IP="${BACKEND_IP:-$RASPI3B_IP}"
validate_ip "$BACKEND_IP" || die "IP backend inválida: $BACKEND_IP"

log_info "--- setup-openwrt-router-portal-mode ---"
log_info "router=${ROUTER_IP} backend_ip=${BACKEND_IP}"

if $RUN_KEYS; then
  run_cmd bash "$SCRIPT_DIR/openwrt-push-admin-pubkeys.sh"
fi

run_cmd bash "$SCRIPT_DIR/setup-openwrt-opennds-portal-files.sh"
run_cmd bash "$SCRIPT_DIR/setup-openwrt-opennds-config.sh" \
  --fas-remote-ip "$ROUTER_IP" \
  --fas-path "/portal/portal.html?api_base=http://${BACKEND_IP}:5000"
run_cmd bash "$SCRIPT_DIR/setup-openwrt-opennds-exceptions.sh" \
  --backend-ip "$BACKEND_IP" \
  --backend-ports "5000 80 443" \
  --router-ports "80 443"

log_ok "Modo router-portal configurado."
log_info "Pruebas sugeridas:"
log_info "  wget -O- http://${ROUTER_IP}/portal/portal.html | head"
log_info "  curl -sS http://${ROUTER_IP}:2050/ | head -20   (openNDS listener)"
