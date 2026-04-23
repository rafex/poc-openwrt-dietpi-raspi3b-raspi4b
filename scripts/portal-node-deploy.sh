#!/bin/bash
# Despliega frontend de portal en Raspi 3B #2 usando podman + nginx.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=./lib/raspi4b-common.sh
. "$SCRIPT_DIR/lib/raspi4b-common.sh"
# shellcheck source=./lib/topology-common.sh
. "$SCRIPT_DIR/lib/topology-common.sh"

parse_common_flags "$@"
init_log_dir "portal-node"
need_root
load_topology
ensure_topology_value >/dev/null || die "TOPOLOGY inválida: $TOPOLOGY"
[ "${#REM_ARGS[@]}" -eq 0 ] || die "Argumentos no soportados: ${REM_ARGS[*]}"

ensure_cmd podman curl cp mkdir cat

BASE_DIR="/opt/demo-openwrt/portal-node"
WEB_DIR="$BASE_DIR/www"
CONF_DIR="$BASE_DIR/nginx"
CONTAINER_NAME="captive-portal-node"
IMAGE_NAME="docker.io/library/nginx:alpine"

AI_ENDPOINT="${AI_IP:-$RASPI4B_IP}"

prepare_files() {
  run_cmd mkdir -p "$WEB_DIR" "$CONF_DIR" "$WEB_DIR/blocked-art"
  run_cmd cp "$REPO_DIR/backend/captive-portal-lentium/portal.html" "$WEB_DIR/portal.html"
  run_cmd cp "$REPO_DIR/backend/captive-portal-lentium/services.html" "$WEB_DIR/services.html"
  run_cmd cp "$REPO_DIR/backend/captive-portal-lentium/blocked.html" "$WEB_DIR/blocked.html"
  run_cmd cp "$REPO_DIR/backend/captive-portal-lentium/blocked-art/"*.svg "$WEB_DIR/blocked-art/"
}

write_nginx_conf() {
  cat > "$CONF_DIR/default.conf" <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    root /usr/share/nginx/html;

    location = / {
        return 302 /portal;
    }

    location = /portal { try_files /portal.html =404; }
    location = /services { try_files /services.html =404; }
    location = /blocked { try_files /blocked.html =404; }
    location /blocked-art/ { try_files \$uri =404; }

    location = /dashboard { proxy_pass http://${AI_ENDPOINT}/dashboard; proxy_set_header Host \$host; proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto \$scheme; }
    location = /terminal { proxy_pass http://${AI_ENDPOINT}/terminal; proxy_set_header Host \$host; proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto \$scheme; }
    location = /rulez { proxy_pass http://${AI_ENDPOINT}/rulez; proxy_set_header Host \$host; proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto \$scheme; }
    location = /accepted { proxy_pass http://${AI_ENDPOINT}/accepted; proxy_set_header Host \$host; proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto \$scheme; }
    location = /people { proxy_pass http://${AI_ENDPOINT}/people; proxy_set_header Host \$host; proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto \$scheme; }
    location = /health { proxy_pass http://${AI_ENDPOINT}/health; proxy_set_header Host \$host; proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto \$scheme; }

    location /api/ {
        proxy_pass http://${AI_ENDPOINT}/api/;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
    }
}
EOF
}

deploy_container() {
  run_cmd podman rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  # DietPi en algunas Raspi no trae nftables userspace por defecto.
  # netavark (red bridge de podman) depende de `nft`; con host network evitamos ese requisito.
  run_cmd podman run -d --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    --network host \
    -v "$WEB_DIR:/usr/share/nginx/html:ro" \
    -v "$CONF_DIR/default.conf:/etc/nginx/conf.d/default.conf:ro" \
    "$IMAGE_NAME"
}

show_port80_debug() {
  if command -v ss >/dev/null 2>&1; then
    log_info "Listeners en :80 (ss):"
    ss -ltnp '( sport = :80 )' || true
  elif command -v netstat >/dev/null 2>&1; then
    log_info "Listeners en :80 (netstat):"
    netstat -ltnp 2>/dev/null | grep ':80 ' || true
  fi
}

check_container_running() {
  local running
  running="$(podman inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || echo false)"
  if [[ "$running" != "true" ]]; then
    log_error "Contenedor $CONTAINER_NAME no está running"
    podman ps -a --filter "name=$CONTAINER_NAME" || true
    log_info "Logs del contenedor:"
    podman logs "$CONTAINER_NAME" 2>/dev/null || true
    show_port80_debug
    die "El contenedor no levantó correctamente"
  fi
}

verify_local() {
  local ep code
  for ep in /portal /services /blocked /api/history /health; do
    code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "http://127.0.0.1${ep}" 2>/dev/null)" || code="000"
    case "$code" in
      200|301|302|307|308) log_ok "${ep} local HTTP ${code}" ;;
      *)
        log_error "Verificación fallida ${ep}: HTTP ${code}"
        podman ps -a --filter "name=$CONTAINER_NAME" || true
        log_info "Logs del contenedor:"
        podman logs "$CONTAINER_NAME" 2>/dev/null || true
        show_port80_debug
        die "Portal node sin respuesta en ${ep}"
        ;;
    esac
  done
}

log_info "--- portal-node-deploy ---"
log_info "Topología: $TOPOLOGY (ai_ip=${AI_ENDPOINT} portal_ip=${PORTAL_IP})"

if ! $ONLY_VERIFY; then
  prepare_files
  write_nginx_conf
  deploy_container
  check_container_running
fi

if ! $DRY_RUN; then
  verify_local
fi

log_ok "portal-node-deploy completado"
