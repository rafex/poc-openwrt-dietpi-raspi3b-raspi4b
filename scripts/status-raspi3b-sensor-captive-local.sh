#!/bin/bash
# status-raspi3b-sensor-captive-local.sh
# Estado local en Raspi3B que corre:
#   - sensor (network-sensor)
#   - portal cautivo directo (captive-portal-direct)

set -euo pipefail

PASS=0
WARN=0
FAIL=0

ok()   { printf '[OK]    %s\n' "$*"; PASS=$((PASS + 1)); }
warn() { printf '[WARN]  %s\n' "$*"; WARN=$((WARN + 1)); }
fail() { printf '[ERROR] %s\n' "$*"; FAIL=$((FAIL + 1)); }
info() { printf '[INFO]  %s\n' "$*"; }

PORT="${PORT:-8080}"
SENSOR_LOG="${SENSOR_LOG:-/var/log/network-sensor.log}"
SERVICE_PORTAL="captive-portal-direct"
SERVICE_SENSOR="network-sensor"

printf '\n============================================================\n'
printf ' Raspi3B Sensor + Captive Local Status  |  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
printf '============================================================\n\n'

info "Host: $(hostname)  IPs: $(hostname -I 2>/dev/null || echo 'n/a')"

if systemctl is-enabled "$SERVICE_PORTAL" >/dev/null 2>&1; then
  ok "systemd $SERVICE_PORTAL habilitado"
else
  warn "systemd $SERVICE_PORTAL no habilitado"
fi

if systemctl is-active "$SERVICE_PORTAL" >/dev/null 2>&1; then
  ok "systemd $SERVICE_PORTAL activo"
else
  fail "systemd $SERVICE_PORTAL inactivo"
fi

if [ -x "/etc/init.d/$SERVICE_SENSOR" ]; then
  if /etc/init.d/"$SERVICE_SENSOR" status >/dev/null 2>&1; then
    ok "init.d $SERVICE_SENSOR activo"
  else
    fail "init.d $SERVICE_SENSOR inactivo"
  fi
else
  fail "No existe /etc/init.d/$SERVICE_SENSOR"
fi

if [ -f "$SENSOR_LOG" ]; then
  ok "Log sensor presente: $SENSOR_LOG"
  info "Últimas 5 líneas de $SENSOR_LOG:"
  tail -5 "$SENSOR_LOG" || true
else
  warn "No existe log sensor en $SENSOR_LOG"
fi

for ep in /portal /services /people /api/portal/context /health; do
  code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 10 "http://127.0.0.1:${PORT}${ep}" 2>/dev/null || echo 000)"
  case "$code" in
    200|201|204|301|302|307|308) ok "HTTP ${ep} -> $code" ;;
    *) fail "HTTP ${ep} -> $code" ;;
  esac
done

if command -v ss >/dev/null 2>&1; then
  if ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":${PORT}$"; then
    ok "Puerto $PORT en LISTEN"
  else
    fail "Puerto $PORT no está en LISTEN"
  fi
fi

printf '\nRESUMEN status-local PASS=%d WARN=%d FAIL=%d\n' "$PASS" "$WARN" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi

