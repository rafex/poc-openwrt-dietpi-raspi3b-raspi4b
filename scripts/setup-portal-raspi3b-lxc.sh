#!/bin/bash
# setup-portal-raspi3b-lxc.sh
# Despliega portal cautivo (backend+frontend) usando LXC (sin LXD).
# - Un solo contenedor LXC con python backend (:5000) + nginx frontend (:8080)
# - Comparte red de host para exponer directamente 127.0.0.1:8080

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=./lib/raspi4b-common.sh
. "$SCRIPT_DIR/lib/raspi4b-common.sh"
# shellcheck source=./lib/topology-common.sh
. "$SCRIPT_DIR/lib/topology-common.sh"

PORTAL_PORT="${PORTAL_PORT:-8080}"
BACKEND_PORT="${BACKEND_PORT:-5000}"
LXC_NAME="${LXC_NAME:-captive-portal}"
LXC_PATH="${LXC_PATH:-/var/lib/lxc}"
ROOTFS_RELEASE="${ROOTFS_RELEASE:-bookworm}"
FALLBACK_DIRECT="${FALLBACK_DIRECT:-true}"

parse_common_flags "$@"
ARGS=("${REM_ARGS[@]}")
REM_ARGS=()
while [ "${#ARGS[@]}" -gt 0 ]; do
  case "${ARGS[0]}" in
    --portal-port) PORTAL_PORT="${ARGS[1]:-}"; ARGS=("${ARGS[@]:2}") ;;
    --backend-port) BACKEND_PORT="${ARGS[1]:-}"; ARGS=("${ARGS[@]:2}") ;;
    --lxc-name) LXC_NAME="${ARGS[1]:-}"; ARGS=("${ARGS[@]:2}") ;;
    --rootfs-release) ROOTFS_RELEASE="${ARGS[1]:-}"; ARGS=("${ARGS[@]:2}") ;;
    --no-fallback-direct) FALLBACK_DIRECT="false"; ARGS=("${ARGS[@]:1}") ;;
    *) REM_ARGS+=("${ARGS[0]}"); ARGS=("${ARGS[@]:1}") ;;
  esac
done
[ "${#REM_ARGS[@]}" -eq 0 ] || die "Argumentos no soportados: ${REM_ARGS[*]}"

init_log_dir "portal-lxc"
need_root
load_topology
ensure_topology_value >/dev/null || die "TOPOLOGY inválida: $TOPOLOGY"

APP_DIR="$REPO_DIR/backend/captive-portal-lentium"
DB_DIR="/opt/captive-portal/lentium-data"
DB_PATH="$DB_DIR/lentium.db"
LXC_DIR="${LXC_PATH}/${LXC_NAME}"
LXC_ROOTFS="${LXC_DIR}/rootfs"
LXC_CONFIG="${LXC_DIR}/config"
UNIT_FILE="/etc/systemd/system/captive-portal-lxc.service"
BACKEND_ENV_HOST="/opt/captive-portal/lxc/backend.env"
LXC_START_SCRIPT_HOST="/opt/captive-portal/lxc/start-services.sh"
LXC_NGINX_CONF_HOST="/opt/captive-portal/lxc/nginx.conf"

ensure_cmd curl ss systemctl
[ -f "$APP_DIR/backend.py" ] || die "No encontrado: $APP_DIR/backend.py"
[ -f "$APP_DIR/portal.html" ] || die "No encontrado: $APP_DIR/portal.html"

fallback_to_direct() {
  if [[ "$FALLBACK_DIRECT" == "true" ]]; then
    log_warn "LXC no fue viable en este host; fallback automático a modo direct."
    env -u SETUP_LOG_INITIALIZED bash "$SCRIPT_DIR/setup-portal-raspi3b-direct.sh"
    exit 0
  fi
  die "LXC no fue viable y --no-fallback-direct está activo"
}

kill_port_listeners() {
  local p="$1"
  local pids
  pids="$(ss -ltnp 2>/dev/null | awk -v port=":${p}" '$4 ~ port"$" {print $NF}' | sed -n 's/.*pid=\([0-9]\+\).*/\1/p' | sort -u)"
  [ -n "$pids" ] || return 0
  log_warn "Liberando puerto ${p} (PIDs: $pids)"
  # shellcheck disable=SC2086
  kill -TERM $pids 2>/dev/null || true
  sleep 1
  pids="$(ss -ltnp 2>/dev/null | awk -v port=":${p}" '$4 ~ port"$" {print $NF}' | sed -n 's/.*pid=\([0-9]\+\).*/\1/p' | sort -u)"
  if [ -n "$pids" ]; then
    # shellcheck disable=SC2086
    kill -KILL $pids 2>/dev/null || true
  fi
}

log_info "--- setup-portal-raspi3b-lxc ---"
log_info "lxc=$LXC_NAME release=$ROOTFS_RELEASE portal_port=$PORTAL_PORT backend_port=$BACKEND_PORT router=$ROUTER_IP ai=$AI_IP"

if ! $ONLY_VERIFY; then
  apt_install_pkgs lxc lxc-templates debootstrap curl ca-certificates openssh-client
  ensure_cmd lxc-create lxc-start lxc-stop lxc-attach

  run_cmd mkdir -p "$DB_DIR" /opt/captive-portal/lxc /opt/keys

  BACKEND_SSH_KEY="/opt/keys/sensor"
  if [[ ! -f "$BACKEND_SSH_KEY" && -f /opt/keys/captive-portal ]]; then
    BACKEND_SSH_KEY="/opt/keys/captive-portal"
  fi
  [ -f "$BACKEND_SSH_KEY" ] || die "No hay llave SSH para OpenWrt (/opt/keys/sensor o /opt/keys/captive-portal)"

  # Limpieza de modos previos/conflictos.
  run_cmd systemctl stop captive-portal-direct.service 2>/dev/null || true
  run_cmd systemctl disable captive-portal-direct.service 2>/dev/null || true
  run_cmd systemctl stop captive-portal-nspawn-backend.service 2>/dev/null || true
  run_cmd systemctl stop captive-portal-nspawn-frontend.service 2>/dev/null || true
  run_cmd systemctl disable captive-portal-nspawn-backend.service 2>/dev/null || true
  run_cmd systemctl disable captive-portal-nspawn-frontend.service 2>/dev/null || true
  run_cmd systemctl stop captive-portal-lxc.service 2>/dev/null || true
  kill_port_listeners "$PORTAL_PORT"
  kill_port_listeners "$BACKEND_PORT"

  # Crea/actualiza contenedor base Debian.
  if [ ! -d "$LXC_DIR" ]; then
    ARCH="$(dpkg --print-architecture)"
    run_cmd lxc-create -n "$LXC_NAME" -P "$LXC_PATH" -t download -- -d debian -r "$ROOTFS_RELEASE" -a "$ARCH"
  fi

  cat > "$LXC_CONFIG" <<EOF
lxc.include = /usr/share/lxc/config/common.conf
lxc.arch = $(uname -m)
lxc.rootfs.path = dir:${LXC_ROOTFS}
lxc.uts.name = ${LXC_NAME}
lxc.net.0.type = empty
lxc.namespace.keep = net
lxc.mount.auto = proc:mixed sys:ro cgroup:mixed
lxc.apparmor.profile = unconfined
lxc.cap.drop =
EOF

  # Archivos de runtime dentro del contenedor.
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

  cat > "$LXC_NGINX_CONF_HOST" <<EOF
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

  cat > "$LXC_START_SCRIPT_HOST" <<'EOF'
#!/bin/sh
set -eu
set -a
. /run/backend.env
set +a
/usr/bin/python3 /opt/app/backend.py >/var/log/captive-backend.log 2>&1 &
exec /usr/sbin/nginx -g 'daemon off;'
EOF
  chmod +x "$LXC_START_SCRIPT_HOST"

  # Arranca temporal para provisionar paquetes.
  run_cmd lxc-stop -n "$LXC_NAME" -P "$LXC_PATH" 2>/dev/null || true
  run_cmd lxc-start -n "$LXC_NAME" -P "$LXC_PATH" -d
  sleep 2
  run_cmd lxc-attach -n "$LXC_NAME" -P "$LXC_PATH" -- /bin/sh -lc \
    "apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends python3 nginx ca-certificates openssh-client && apt-get clean"
  run_cmd lxc-stop -n "$LXC_NAME" -P "$LXC_PATH" || true

  cat > "$UNIT_FILE" <<EOF
[Unit]
Description=Captive Portal LXC (backend+frontend)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=/bin/sh -lc 'lxc-stop -n ${LXC_NAME} -P ${LXC_PATH} 2>/dev/null || true'
ExecStart=/usr/bin/lxc-start -n ${LXC_NAME} -P ${LXC_PATH} -F -- \\
  /bin/sh -lc 'mount --bind ${APP_DIR} /opt/app; mkdir -p /data /opt/keys /run; mount --bind ${DB_DIR} /data; mount --bind /opt/keys /opt/keys; cp ${BACKEND_ENV_HOST} /run/backend.env; cp ${LXC_NGINX_CONF_HOST} /etc/nginx/conf.d/default.conf; exec ${LXC_START_SCRIPT_HOST}'
ExecStop=/usr/bin/lxc-stop -n ${LXC_NAME} -P ${LXC_PATH}
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

  run_cmd systemctl daemon-reload
  run_cmd systemctl enable captive-portal-lxc.service
  run_cmd systemctl restart captive-portal-lxc.service
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
    200|301|302|307|308) log_ok "Portal LXC local OK: /portal (HTTP $CODE)" ;;
    *)
      log_error "Portal LXC no responde: HTTP $CODE"
      systemctl status captive-portal-lxc.service --no-pager -l 2>/dev/null | tail -120 || true
      journalctl -u captive-portal-lxc.service -n 120 --no-pager 2>/dev/null || true
      fallback_to_direct
      ;;
  esac
fi

log_ok "setup-portal-raspi3b-lxc completado"
