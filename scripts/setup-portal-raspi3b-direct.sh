#!/bin/bash
# setup-portal-raspi3b-direct.sh
# Instala portal cautivo en Raspi3B SIN podman:
#   - frontend y backend servidos por backend/captive-portal-lentium/backend.py
#   - servicio systemd: captive-portal-direct
#   - SQLite persistente en /opt/captive-portal/lentium-data/lentium.db
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=./lib/raspi4b-common.sh
. "$SCRIPT_DIR/lib/raspi4b-common.sh"
# shellcheck source=./lib/topology-common.sh
. "$SCRIPT_DIR/lib/topology-common.sh"

parse_common_flags "$@"
init_log_dir "portal-direct"
need_root
load_topology
ensure_topology_value >/dev/null || die "TOPOLOGY inválida: $TOPOLOGY"
[ "${#REM_ARGS[@]}" -eq 0 ] || die "Argumentos no soportados: ${REM_ARGS[*]}"

ensure_cmd bash curl python3

APP_DIR="$REPO_DIR/backend/captive-portal-lentium"
DB_DIR="/opt/captive-portal/lentium-data"
DB_PATH="$DB_DIR/lentium.db"
PORT="${PORT:-8080}"
SERVICE_NAME="captive-portal-direct"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

[ -f "$APP_DIR/backend.py" ] || die "No encontrado: $APP_DIR/backend.py"
[ -f "$APP_DIR/portal.html" ] || die "No encontrado: $APP_DIR/portal.html"

log_info "--- setup-portal-raspi3b-direct ---"
log_info "app_dir=$APP_DIR port=$PORT db=$DB_PATH router=$ROUTER_IP ai=$AI_IP"

if ! $ONLY_VERIFY; then
  apt_install_pkgs python3 curl ca-certificates openssh-client
  run_cmd mkdir -p "$DB_DIR" /opt/keys

  BACKEND_SSH_KEY="/opt/keys/sensor"
  if [[ ! -f "$BACKEND_SSH_KEY" && -f /opt/keys/captive-portal ]]; then
    BACKEND_SSH_KEY="/opt/keys/captive-portal"
  fi
  [ -f "$BACKEND_SSH_KEY" ] || die "No hay llave SSH para autorizar clientes en OpenWrt (/opt/keys/sensor o /opt/keys/captive-portal)."

  if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    run_cmd systemctl stop "$SERVICE_NAME"
  fi

  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Captive Portal Direct (Raspi3B, no podman)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$APP_DIR
Environment=ROUTER_IP=$ROUTER_IP
Environment=ROUTER_USER=root
Environment=SSH_KEY=$BACKEND_SSH_KEY
Environment=PORTAL_IP=$RASPI3B_IP
Environment=DB_PATH=$DB_PATH
Environment=PORT=$PORT
Environment=SERVICE_RASPI4_HOST=$RASPI4B_IP
Environment=SERVICE_RASPI3_HOST=$RASPI3B_IP
Environment=SERVICE_RASPI3_SSH_KEY=$BACKEND_SSH_KEY
Environment=AI_ANALYZER_URL=http://$AI_IP:5000
ExecStart=/usr/bin/python3 $APP_DIR/backend.py
Restart=always
RestartSec=2
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  run_cmd systemctl daemon-reload
  run_cmd systemctl enable "$SERVICE_NAME"
  run_cmd systemctl restart "$SERVICE_NAME"
fi

if ! $DRY_RUN; then
  CODE="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 10 "http://127.0.0.1:${PORT}/portal" 2>/dev/null || echo 000)"
  case "$CODE" in
    200|301|302|307|308) log_ok "Portal directo local OK: /portal (HTTP $CODE)" ;;
    *)
      log_error "Portal directo no responde: HTTP $CODE"
      systemctl status "$SERVICE_NAME" --no-pager -l 2>/dev/null | tail -80 || true
      journalctl -u "$SERVICE_NAME" -n 80 --no-pager 2>/dev/null || true
      die "Fallo verificación portal directo"
      ;;
  esac
fi

log_ok "setup-portal-raspi3b-direct completado"

