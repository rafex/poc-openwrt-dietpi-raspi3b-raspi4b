#!/bin/bash
# setup-raspi3b-sensor-captive-full.sh
# Orquesta instalación completa en una Raspi3B:
#   1) Sensor de red (tshark + servicio network-sensor)
#   2) Portal cautivo completo (frontend + backend directo, sin podman)
#
# No reemplaza scripts previos; solo los ejecuta en orden.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=./lib/raspi4b-common.sh
. "$SCRIPT_DIR/lib/raspi4b-common.sh"
# shellcheck source=./lib/topology-common.sh
. "$SCRIPT_DIR/lib/topology-common.sh"

SKIP_SENSOR=false
SKIP_PORTAL=false
SENSOR_NO_SSH=false
SENSOR_NO_WAIT=false
PORTAL_MODE="direct"   # direct|podman|nspawn

parse_common_flags "$@"
ARGS=("${REM_ARGS[@]}")
REM_ARGS=()
for a in "${ARGS[@]}"; do
  case "$a" in
    --skip-sensor) SKIP_SENSOR=true ;;
    --skip-portal) SKIP_PORTAL=true ;;
    --sensor-no-ssh) SENSOR_NO_SSH=true ;;
    --sensor-no-wait) SENSOR_NO_WAIT=true ;;
    --portal-mode=*) PORTAL_MODE="${a#*=}" ;;
    --portal-mode)
      # consume next argument via REM_ARGS parser style:
      die "Usa --portal-mode=direct o --portal-mode=podman o --portal-mode=nspawn"
      ;;
    *) REM_ARGS+=("$a") ;;
  esac
done
[ "${#REM_ARGS[@]}" -eq 0 ] || die "Argumentos no soportados: ${REM_ARGS[*]}"

case "$PORTAL_MODE" in
  direct|podman|nspawn) ;;
  *) die "--portal-mode inválido: $PORTAL_MODE (usar direct|podman|nspawn)" ;;
esac

init_log_dir "raspi3b-full"
need_root
load_topology
ensure_topology_value >/dev/null || die "TOPOLOGY inválida: $TOPOLOGY"

log_info "--- setup-raspi3b-sensor-captive-full ---"
log_info "topología=$TOPOLOGY sensor_ip=${RASPI3B_IP} ai_ip=${AI_IP} portal_ip=${PORTAL_IP}"

if ! $SKIP_SENSOR; then
  log_info "Paso 1/2: Instalando sensor..."
  SENSOR_ARGS=()
  $SENSOR_NO_SSH && SENSOR_ARGS+=(--no-ssh)
  $SENSOR_NO_WAIT && SENSOR_ARGS+=(--no-wait)
  $DRY_RUN && SENSOR_ARGS+=(--dry-run)
  env -u SETUP_LOG_INITIALIZED bash "$SCRIPT_DIR/setup-sensor-raspi3b.sh" "${SENSOR_ARGS[@]}"
  log_ok "Sensor instalado"
else
  log_warn "Sensor omitido (--skip-sensor)"
fi

if ! $SKIP_PORTAL; then
  log_info "Paso 2/2: Instalando portal cautivo completo (modo=$PORTAL_MODE)..."
  PORTAL_ARGS=()
  $DRY_RUN && PORTAL_ARGS+=(--dry-run)
  $ONLY_VERIFY && PORTAL_ARGS+=(--only-verify)
  if [[ "$PORTAL_MODE" == "direct" ]]; then
    env -u SETUP_LOG_INITIALIZED bash "$SCRIPT_DIR/setup-portal-raspi3b-direct.sh" "${PORTAL_ARGS[@]}"
  elif [[ "$PORTAL_MODE" == "nspawn" ]]; then
    env -u SETUP_LOG_INITIALIZED bash "$SCRIPT_DIR/setup-portal-raspi3b-nspawn.sh" "${PORTAL_ARGS[@]}"
  else
    env -u SETUP_LOG_INITIALIZED bash "$SCRIPT_DIR/setup-portal-raspi3b.sh" "${PORTAL_ARGS[@]}"
  fi
  log_ok "Portal cautivo completo instalado"
else
  log_warn "Portal omitido (--skip-portal)"
fi

if ! $DRY_RUN; then
  log_info "Verificación rápida local..."
  curl -sS -o /dev/null -w '  /portal -> HTTP %{http_code}\n' http://127.0.0.1/portal || true
  curl -sS -o /dev/null -w '  /services -> HTTP %{http_code}\n' http://127.0.0.1/services || true
  curl -sS -o /dev/null -w '  /api/portal/context -> HTTP %{http_code}\n' http://127.0.0.1/api/portal/context || true
fi

log_ok "setup-raspi3b-sensor-captive-full completado"
log_info "Siguiente paso (admin): configurar OpenWrt para apuntar a esta Raspi3B."
