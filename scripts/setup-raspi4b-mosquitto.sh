#!/bin/bash
# Instala y configura solo Mosquitto en Raspi4B.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib/raspi4b-common.sh
. "$SCRIPT_DIR/lib/raspi4b-common.sh"

parse_common_flags "$@"
init_log_dir "mosquitto"
need_root

[ "${#REM_ARGS[@]}" -eq 0 ] || die "Argumentos no soportados: ${REM_ARGS[*]}"

log_info "--- setup-raspi4b-mosquitto ---"

ensure_cmd bash

if $ONLY_VERIFY; then
  log_info "Modo only-verify"
else
  apt_install_pkgs mosquitto mosquitto-clients

  MOSQUITTO_CONF="/etc/mosquitto/conf.d/rafexpi.conf"
  run_cmd mkdir -p /etc/mosquitto/conf.d
  if ! $DRY_RUN; then
    cat > "$MOSQUITTO_CONF" << 'CFG'
# RafexPi — Mosquitto MQTT broker
listener 1883 0.0.0.0
allow_anonymous true
CFG
  else
    log_info "[dry-run] escribir $MOSQUITTO_CONF"
  fi
  log_ok "Configuración aplicada: $MOSQUITTO_CONF"

  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    run_cmd systemctl enable mosquitto || true
    run_cmd systemctl restart mosquitto
  else
    run_cmd update-rc.d mosquitto defaults || true
    if [ -x /etc/init.d/mosquitto ]; then
      run_cmd /etc/init.d/mosquitto restart || run_cmd /etc/init.d/mosquitto start
    fi
  fi
fi

if $DRY_RUN; then
  log_ok "Dry-run completado"
  exit 0
fi

sleep 2
if mosquitto_pub -h 127.0.0.1 -t "test/ping" -m "pong" >/dev/null 2>&1; then
  log_ok "Mosquitto activo en :1883"
else
  die "Mosquitto no responde en localhost:1883"
fi

log_ok "setup-raspi4b-mosquitto completado"
