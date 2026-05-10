#!/bin/bash
# status-raspi3b-sensor-captive-admin.sh
# Estado remoto desde máquina admin:
#   - OpenWrt/openNDS apuntando al portal de Raspi3B
#   - Raspi3B con sensor + portal directo activos

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib/topology-common.sh
. "$SCRIPT_DIR/lib/topology-common.sh"

load_topology

ROUTER_IP="${ROUTER_IP:-192.168.1.1}"
PI3_IP="${RASPI3B_IP:-192.168.1.181}"
PORTAL_PORT="${PORTAL_PORT:-8080}"
SSH_KEY="${SSH_KEY:-/opt/keys/captive-portal}"
ROUTER_KEY="${ROUTER_KEY:-/opt/keys/captive-portal}"

while [ $# -gt 0 ]; do
  case "$1" in
    --router-ip) ROUTER_IP="$2"; shift 2;;
    --pi3-ip) PI3_IP="$2"; shift 2;;
    --portal-port) PORTAL_PORT="$2"; shift 2;;
    --ssh-key) SSH_KEY="$2"; shift 2;;
    --router-key) ROUTER_KEY="$2"; shift 2;;
    --help|-h)
      cat <<EOF
Uso: $0 [opciones]
  --router-ip <ip>     Router OpenWrt (default: $ROUTER_IP)
  --pi3-ip <ip>        Raspi3B sensor+portal (default: $PI3_IP)
  --portal-port <n>    Puerto backend/frontend portal (default: $PORTAL_PORT)
  --ssh-key <path>     Llave SSH para Raspi3B
  --router-key <path>  Llave SSH para OpenWrt
EOF
      exit 0;;
    *) echo "Argumento desconocido: $1"; exit 2;;
  esac
done

PASS=0
WARN=0
FAIL=0
ok()   { printf '[OK]    %s\n' "$*"; PASS=$((PASS + 1)); }
warn() { printf '[WARN]  %s\n' "$*"; WARN=$((WARN + 1)); }
fail() { printf '[ERROR] %s\n' "$*"; FAIL=$((FAIL + 1)); }
info() { printf '[INFO]  %s\n' "$*"; }

SSH_OPTS_PI3=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -i "$SSH_KEY")
SSH_OPTS_ROUTER=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -i "$ROUTER_KEY")

printf '\n============================================================\n'
printf ' Admin Status Raspi3B Sensor+Portal  |  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
printf '============================================================\n\n'

info "Router: $ROUTER_IP  |  Raspi3B: $PI3_IP:$PORTAL_PORT"

if ssh "${SSH_OPTS_ROUTER[@]}" "root@$ROUTER_IP" "echo ok" >/dev/null 2>&1; then
  ok "SSH OpenWrt OK"
else
  fail "SSH OpenWrt falló"
fi

PI3_SSH_OK=false
if ssh "${SSH_OPTS_PI3[@]}" "root@$PI3_IP" "echo ok" >/dev/null 2>&1; then
  ok "SSH Raspi3B OK"
  PI3_SSH_OK=true
else
  warn "SSH Raspi3B falló (llave/credenciales). Se continuará con verificación HTTP."
fi

if [ "$FAIL" -eq 0 ]; then
  info "--- OpenWrt / openNDS ---"
  O_NDS="$(ssh "${SSH_OPTS_ROUTER[@]}" "root@$ROUTER_IP" "uci -q get opennds.@opennds[0].enabled 2>/dev/null || true")"
  [ "$O_NDS" = "1" ] && ok "openNDS enabled=1" || warn "openNDS enabled=$O_NDS"

  FAS_IP="$(ssh "${SSH_OPTS_ROUTER[@]}" "root@$ROUTER_IP" "uci -q get opennds.@opennds[0].fasremoteip 2>/dev/null || true")"
  FAS_PORT="$(ssh "${SSH_OPTS_ROUTER[@]}" "root@$ROUTER_IP" "uci -q get opennds.@opennds[0].fasport 2>/dev/null || true")"
  FAS_PATH="$(ssh "${SSH_OPTS_ROUTER[@]}" "root@$ROUTER_IP" "uci -q get opennds.@opennds[0].faspath 2>/dev/null || true")"
  [ "$FAS_IP" = "$PI3_IP" ] && ok "fasremoteip=$FAS_IP" || fail "fasremoteip=$FAS_IP (esperado $PI3_IP)"
  [ "$FAS_PORT" = "$PORTAL_PORT" ] && ok "fasport=$FAS_PORT" || warn "fasport=$FAS_PORT (esperado $PORTAL_PORT)"
  [ -n "$FAS_PATH" ] && ok "faspath=$FAS_PATH" || warn "faspath vacío"
fi

info "--- Raspi3B servicios ---"
if $PI3_SSH_OK; then
  if ssh "${SSH_OPTS_PI3[@]}" "root@$PI3_IP" "systemctl is-active captive-portal-direct >/dev/null"; then
    ok "captive-portal-direct activo"
  else
    fail "captive-portal-direct inactivo"
  fi

  if ssh "${SSH_OPTS_PI3[@]}" "root@$PI3_IP" "/etc/init.d/network-sensor status >/dev/null 2>&1"; then
    ok "network-sensor activo"
  else
    fail "network-sensor inactivo"
  fi
else
  warn "Saltando validación de servicios por SSH (sin acceso a Raspi3B)"
fi

info "--- HTTP portal desde admin ---"
for ep in /portal /services /people /api/portal/context /health; do
  code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 10 "http://${PI3_IP}:${PORTAL_PORT}${ep}" 2>/dev/null || echo 000)"
  case "$code" in
    200|201|204|301|302|307|308) ok "HTTP ${ep} -> $code" ;;
    *) fail "HTTP ${ep} -> $code" ;;
  esac
done

printf '\nRESUMEN status-admin PASS=%d WARN=%d FAIL=%d\n' "$PASS" "$WARN" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
