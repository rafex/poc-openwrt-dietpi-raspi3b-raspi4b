#!/bin/bash
# setup-raspi3b-sensor-captive-backend.sh
# Despliega SOLO backend cautivo Lentium en la Raspi3B-sensor usando Podman.
# La BD SQLite persiste en host: /opt/captive-portal/lentium-data/lentium.db
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=./lib/raspi4b-common.sh
. "$SCRIPT_DIR/lib/raspi4b-common.sh"
# shellcheck source=./lib/topology-common.sh
. "$SCRIPT_DIR/lib/topology-common.sh"

parse_common_flags "$@"
init_log_dir "raspi3b-sensor-backend"
need_root
load_topology
ensure_topology_value >/dev/null || die "TOPOLOGY inválida: $TOPOLOGY"
[ "${#REM_ARGS[@]}" -eq 0 ] || die "Argumentos no soportados: ${REM_ARGS[*]}"

ensure_cmd podman curl

CONTAINER_NAME="captive-backend-sensor"
IMAGE_NAME="localhost/captive-backend-lentium-sensor:latest"
BACKEND_PORT="${BACKEND_PORT:-5000}"
DB_HOST_DIR="${DB_HOST_DIR:-/opt/captive-portal/lentium-data}"
AI_ENDPOINT="${AI_IP:-$RASPI4B_IP}"
BACKEND_SSH_KEY_PATH="/opt/keys/sensor"

log_info "--- setup-raspi3b-sensor-captive-backend ---"
log_info "router=${ROUTER_IP} ai=${AI_ENDPOINT} sensor_ip=${RASPI3B_IP} backend_port=${BACKEND_PORT}"

if ! $ONLY_VERIFY; then
  apt_install_pkgs podman curl ca-certificates
  run_cmd mkdir -p "$DB_HOST_DIR" /opt/keys

  if [[ ! -f /opt/keys/sensor ]]; then
    log_warn "No existe /opt/keys/sensor; backend usará fallback /opt/keys/captive-portal si existe."
    BACKEND_SSH_KEY_PATH="/opt/keys/captive-portal"
  fi
  if [[ ! -f /opt/keys/sensor && ! -f /opt/keys/captive-portal ]]; then
    die "Faltan llaves SSH para autorizar clientes en OpenWrt (/opt/keys/sensor o /opt/keys/captive-portal)."
  fi

  run_cmd podman build \
    --runtime=runc \
    --network=host \
    -t "$IMAGE_NAME" \
    "$REPO_DIR/backend/captive-portal-lentium"

  run_cmd podman rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  run_cmd podman run -d --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    --network host \
    -e ROUTER_IP="${ROUTER_IP}" \
    -e PORTAL_IP="${ROUTER_IP}" \
    -e DB_PATH="/data/lentium.db" \
    -e PORT="${BACKEND_PORT}" \
    -e SSH_KEY="${BACKEND_SSH_KEY_PATH}" \
    -e REPO_PATH="$REPO_DIR" \
    -e AI_ANALYZER_URL="http://${AI_ENDPOINT}:5000" \
    -v "$DB_HOST_DIR:/data" \
    -v "/opt/keys:/opt/keys:ro" \
    "$IMAGE_NAME"

  cat > /etc/systemd/system/captive-backend-sensor.service <<EOF
[Unit]
Description=Captive Backend (Sensor Node)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/podman start ${CONTAINER_NAME}
ExecStop=/usr/bin/podman stop -t 10 ${CONTAINER_NAME}
Restart=no

[Install]
WantedBy=multi-user.target
EOF

  run_cmd systemctl daemon-reload
  run_cmd systemctl enable captive-backend-sensor.service
fi

if $DRY_RUN; then
  log_ok "Dry-run completado"
  exit 0
fi

code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 8 "http://127.0.0.1:${BACKEND_PORT}/health" 2>/dev/null || echo 000)"
case "$code" in
  200|301|302|307|308)
    log_ok "Backend cautivo local OK: http://127.0.0.1:${BACKEND_PORT}/health (HTTP $code)"
    ;;
  *)
    log_error "Backend no responde correctamente: HTTP $code"
    podman ps -a --filter "name=$CONTAINER_NAME" || true
    podman logs --tail 120 "$CONTAINER_NAME" || true
    die "No se pudo validar backend cautivo en Raspi3B-sensor"
    ;;
esac

log_ok "setup-raspi3b-sensor-captive-backend completado"
log_info "SQLite persistente: ${DB_HOST_DIR}/lentium.db"
