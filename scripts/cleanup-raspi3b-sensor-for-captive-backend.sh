#!/bin/bash
# cleanup-raspi3b-sensor-for-captive-backend.sh
# Limpia la instalación de "sensor" en Raspi3B y la deja lista para backend cautivo.
#
# Qué elimina/desactiva:
#   - servicio network-sensor (init.d + rc)
#   - procesos sensor.py / tshark asociados
#   - /opt/sensor
#   - ajustes persistentes de modo promiscuo agregados por setup-sensor
#
# Qué prepara para backend cautivo:
#   - directorio persistente SQLite: /opt/captive-portal/lentium-data
#   - /opt/keys (NO borra llaves existentes)
#   - dependencias base: podman, curl, ca-certificates
#
# Uso:
#   sudo bash scripts/cleanup-raspi3b-sensor-for-captive-backend.sh
#   sudo bash scripts/cleanup-raspi3b-sensor-for-captive-backend.sh --dry-run
#   sudo bash scripts/cleanup-raspi3b-sensor-for-captive-backend.sh --purge-sensor-packages

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=./lib/raspi4b-common.sh
. "$SCRIPT_DIR/lib/raspi4b-common.sh"

PURGE_SENSOR_PACKAGES=false

parse_common_flags "$@"
ARGS=("${REM_ARGS[@]}")
REM_ARGS=()
for a in "${ARGS[@]}"; do
  case "$a" in
    --purge-sensor-packages) PURGE_SENSOR_PACKAGES=true ;;
    *) REM_ARGS+=("$a") ;;
  esac
done
[ "${#REM_ARGS[@]}" -eq 0 ] || die "Argumentos no soportados: ${REM_ARGS[*]}"

init_log_dir "cleanup-sensor"
need_root

SVC_NAME="network-sensor"
SVC_FILE="/etc/init.d/${SVC_NAME}"
SENSOR_DIR="/opt/sensor"
SENSOR_LOG_DIR="/var/log/network-sensor"
DB_DIR="/opt/captive-portal/lentium-data"
KEYS_DIR="/opt/keys"

log_info "--- cleanup-raspi3b-sensor-for-captive-backend ---"
log_info "dry_run=${DRY_RUN} purge_sensor_packages=${PURGE_SENSOR_PACKAGES}"

stop_sensor_service() {
  if [ -f "$SVC_FILE" ]; then
    log_info "Deteniendo y deshabilitando servicio ${SVC_NAME}..."
    run_cmd "$SVC_FILE" stop || true
    run_cmd update-rc.d -f "$SVC_NAME" remove || true
    run_cmd rm -f "$SVC_FILE"
    log_ok "Servicio ${SVC_NAME} eliminado"
  else
    log_info "Servicio ${SVC_NAME} no existe (skip)"
  fi
}

kill_sensor_processes() {
  log_info "Terminando procesos de sensor/tshark si existen..."
  run_cmd pkill -f "/opt/sensor/sensor.py" || true
  run_cmd pkill -f "tshark.*-i eth0" || true
  run_cmd pkill -f "python3 .*sensor.py" || true
  log_ok "Procesos sensor detenidos (si existían)"
}

remove_sensor_files() {
  if [ -d "$SENSOR_DIR" ]; then
    run_cmd rm -rf "$SENSOR_DIR"
    log_ok "Directorio eliminado: $SENSOR_DIR"
  else
    log_info "No existe $SENSOR_DIR (skip)"
  fi

  if [ -d "$SENSOR_LOG_DIR" ]; then
    run_cmd rm -rf "$SENSOR_LOG_DIR"
    log_ok "Logs de sensor eliminados: $SENSOR_LOG_DIR"
  else
    log_info "No existe $SENSOR_LOG_DIR (skip)"
  fi
}

cleanup_promisc_config() {
  local ifaces="/etc/network/interfaces"
  if [ -f "$ifaces" ] && grep -q "promisc-sensor-eth0" "$ifaces" 2>/dev/null; then
    log_info "Removiendo persistencia de modo promiscuo en $ifaces..."
    run_cmd sed -i '/promisc-sensor-eth0/d' "$ifaces"
    log_ok "Persistencia PROMISC removida de $ifaces"
  else
    log_info "No hay persistencia PROMISC en $ifaces (skip)"
  fi

  if ip link show eth0 >/dev/null 2>&1; then
    log_info "Desactivando modo promiscuo en eth0..."
    run_cmd ip link set eth0 promisc off || true
  fi
}

purge_sensor_packages() {
  $PURGE_SENSOR_PACKAGES || return 0
  log_warn "Purga opcional de paquetes del sensor activada"
  log_info "Eliminando paquetes: tshark tcpdump wireshark-common netcat-openbsd"
  if ! $DRY_RUN; then
    apt_update_once
  fi
  run_cmd env DEBIAN_FRONTEND=noninteractive apt-get -y purge tshark tcpdump wireshark-common netcat-openbsd || true
  run_cmd env DEBIAN_FRONTEND=noninteractive apt-get -y autoremove --purge || true
  log_ok "Purga de paquetes de sensor completada"
}

prepare_backend_base() {
  log_info "Preparando base para backend cautivo..."
  apt_install_pkgs podman curl ca-certificates
  run_cmd mkdir -p "$DB_DIR" "$KEYS_DIR"
  run_cmd chmod 755 "$DB_DIR"
  log_ok "Base lista: DB=$DB_DIR  KEYS=$KEYS_DIR"
}

stop_sensor_service
kill_sensor_processes
remove_sensor_files
cleanup_promisc_config
purge_sensor_packages
prepare_backend_base

log_ok "Limpieza completada. Raspi3B lista para backend cautivo."
log_info "Siguiente paso recomendado:"
log_info "  sudo bash scripts/setup-raspi3b-sensor-captive-backend.sh"

