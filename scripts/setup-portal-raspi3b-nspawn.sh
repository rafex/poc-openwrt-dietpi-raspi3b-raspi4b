#!/bin/bash
# setup-portal-raspi3b-nspawn.sh
# Portal cautivo en Raspi3B con systemd-nspawn (sin podman):
#   - backend Python en :5000 (container nspawn)
#   - nginx frontend+proxy en :8080 (container nspawn)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=./lib/raspi4b-common.sh
. "$SCRIPT_DIR/lib/raspi4b-common.sh"
# shellcheck source=./lib/topology-common.sh
. "$SCRIPT_DIR/lib/topology-common.sh"

BACKEND_PORT="${BACKEND_PORT:-5000}"
PORTAL_PORT="${PORTAL_PORT:-8080}"
ROOTFS="${ROOTFS:-/var/lib/machines/captive-portal}"
MACHINE_BACKEND="${MACHINE_BACKEND:-captive-portal-backend}"
MACHINE_FRONTEND="${MACHINE_FRONTEND:-captive-portal-frontend}"

parse_common_flags "$@"
ARGS=("${REM_ARGS[@]}")
REM_ARGS=()
while [ "${#ARGS[@]}" -gt 0 ]; do
  case "${ARGS[0]}" in
    --backend-port) BACKEND_PORT="${ARGS[1]:-}"; ARGS=("${ARGS[@]:2}") ;;
    --portal-port) PORTAL_PORT="${ARGS[1]:-}"; ARGS=("${ARGS[@]:2}") ;;
    --rootfs) ROOTFS="${ARGS[1]:-}"; ARGS=("${ARGS[@]:2}") ;;
    *) REM_ARGS+=("${ARGS[0]}"); ARGS=("${ARGS[@]:1}") ;;
  esac
done
[ "${#REM_ARGS[@]}" -eq 0 ] || die "Argumentos no soportados: ${REM_ARGS[*]}"

init_log_dir "portal-nspawn"
need_root
load_topology
ensure_topology_value >/dev/null || die "TOPOLOGY inválida: $TOPOLOGY"

APP_DIR="$REPO_DIR/backend/captive-portal-lentium"
DB_DIR="/opt/captive-portal/lentium-data"
DB_PATH="$DB_DIR/lentium.db"
NGINX_CONF_HOST="/opt/captive-portal/nspawn/nginx.conf"
BACKEND_ENV_HOST="/opt/captive-portal/nspawn/backend.env"
SVC_BACKEND="/etc/systemd/system/captive-portal-nspawn-backend.service"
SVC_FRONTEND="/etc/systemd/system/captive-portal-nspawn-frontend.service"
BACKEND_SSH_KEY="/opt/keys/sensor"

ensure_cmd systemctl curl
[ -f "$APP_DIR/backend.py" ] || die "No encontrado: $APP_DIR/backend.py"

log_info "--- setup-portal-raspi3b-nspawn ---"
log_info "rootfs=$ROOTFS portal_port=$PORTAL_PORT backend_port=$BACKEND_PORT router=$ROUTER_IP ai=$AI_IP"

if ! $ONLY_VERIFY; then
  apt_install_pkgs systemd-container debootstrap curl ca-certificates
  ensure_cmd systemd-nspawn debootstrap
  run_cmd mkdir -p "$DB_DIR" /opt/captive-portal/nspawn /opt/keys
  if [[ ! -f "$BACKEND_SSH_KEY" && -f /opt/keys/captive-portal ]]; then
    BACKEND_SSH_KEY="/opt/keys/captive-portal"
  fi
  [ -f "$BACKEND_SSH_KEY" ] || die "No hay llave SSH para OpenWrt (/opt/keys/sensor o /opt/keys/captive-portal)"

  if [ ! -d "$ROOTFS/usr" ]; then
    ARCH="$(dpkg --print-architecture)"
    RELEASE="${NSPAWN_RELEASE:-bookworm}"
    MIRROR="${NSPAWN_MIRROR:-http://deb.debian.org/debian}"
    log_info "Creando rootfs nspawn ($ARCH, $RELEASE)..."
    run_cmd debootstrap --variant=minbase --arch="$ARCH" "$RELEASE" "$ROOTFS" "$MIRROR"
  fi

  log_info "Instalando paquetes dentro del rootfs nspawn..."
  run_cmd systemd-nspawn -q -D "$ROOTFS" /bin/sh -lc \
    "apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends python3 nginx ca-certificates openssh-client && apt-get clean"

  cat > "$BACKEND_ENV_HOST" <<EOF
ROUTER_IP=$ROUTER_IP
ROUTER_USER=root
SSH_KEY=/opt/keys/sensor
PORTAL_IP=$RASPI3B_IP
DB_PATH=/data/lentium.db
PORT=$BACKEND_PORT
SERVICE_RASPI4_HOST=$RASPI4B_IP
SERVICE_RASPI3_HOST=$RASPI3B_IP
SERVICE_RASPI3_SSH_KEY=/opt/keys/sensor
AI_ANALYZER_URL=http://$AI_IP:5000
EOF
  sed -i "s|^SSH_KEY=.*|SSH_KEY=${BACKEND_SSH_KEY}|g; s|^SERVICE_RASPI3_SSH_KEY=.*|SERVICE_RASPI3_SSH_KEY=${BACKEND_SSH_KEY}|g" "$BACKEND_ENV_HOST"

  cat > "$NGINX_CONF_HOST" <<EOF
server {
  listen ${PORTAL_PORT};
  server_name _;
  root /opt/app;
  index portal.html;

  location /api/ {
    proxy_pass http://127.0.0.1:${BACKEND_PORT};
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
  }

  location / {
    try_files \$uri \$uri.html /portal.html;
  }
}
EOF

  cat > "$SVC_BACKEND" <<EOF
[Unit]
Description=Captive Portal Backend (nspawn)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/systemd-nspawn -q --machine=${MACHINE_BACKEND} --directory=${ROOTFS} --network-host --as-pid2 \\
  --bind=${APP_DIR}:/opt/app --bind=${DB_DIR}:/data --bind=/opt/keys:/opt/keys --bind=${BACKEND_ENV_HOST}:/run/backend.env \\
  /bin/sh -lc 'set -a; . /run/backend.env; set +a; exec /usr/bin/python3 /opt/app/backend.py'
ExecStop=/usr/bin/machinectl terminate ${MACHINE_BACKEND}
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

  cat > "$SVC_FRONTEND" <<EOF
[Unit]
Description=Captive Portal Frontend Nginx (nspawn)
After=network-online.target captive-portal-nspawn-backend.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/systemd-nspawn -q --machine=${MACHINE_FRONTEND} --directory=${ROOTFS} --network-host --as-pid2 \\
  --bind=${APP_DIR}:/opt/app --bind=${NGINX_CONF_HOST}:/etc/nginx/conf.d/default.conf \\
  /usr/sbin/nginx -g 'daemon off;'
ExecStop=/usr/bin/machinectl terminate ${MACHINE_FRONTEND}
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

  run_cmd systemctl daemon-reload
  run_cmd systemctl enable captive-portal-nspawn-backend.service
  run_cmd systemctl enable captive-portal-nspawn-frontend.service
  run_cmd systemctl restart captive-portal-nspawn-backend.service
  run_cmd systemctl restart captive-portal-nspawn-frontend.service
fi

if ! $DRY_RUN; then
  CODE="000"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    CODE="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 5 \
      "http://127.0.0.1:${PORTAL_PORT}/portal" 2>/dev/null || echo 000)"
    case "$CODE" in
      200|301|302|307|308) break ;;
    esac
    sleep 1
  done
  case "$CODE" in
    200|301|302|307|308) log_ok "Portal nspawn local OK: /portal (HTTP $CODE)" ;;
    *)
      log_error "Portal nspawn no responde: HTTP $CODE"
      systemctl status captive-portal-nspawn-backend.service --no-pager -l 2>/dev/null | tail -80 || true
      systemctl status captive-portal-nspawn-frontend.service --no-pager -l 2>/dev/null | tail -80 || true
      die "Fallo verificación portal nspawn"
      ;;
  esac
fi

log_ok "setup-portal-raspi3b-nspawn completado"
