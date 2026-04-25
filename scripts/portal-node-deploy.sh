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
CONTAINER_NAME_FRONTEND="captive-portal-node"
CONTAINER_NAME_BACKEND="captive-portal-node-backend"
IMAGE_FRONTEND="docker.io/library/nginx:alpine"
IMAGE_BACKEND="localhost/captive-backend-lentium-portal-node:latest"
BACKEND_PORT="8080"
DB_HOST_DIR="/opt/captive-portal/lentium-data"

AI_ENDPOINT="${AI_IP:-$RASPI4B_IP}"

prepare_files() {
  run_cmd mkdir -p "$WEB_DIR" "$CONF_DIR" "$WEB_DIR/blocked-art"
  run_cmd cp "$REPO_DIR/backend/captive-portal-lentium/portal.html" "$WEB_DIR/portal.html"
  run_cmd cp "$REPO_DIR/backend/captive-portal-lentium/services.html" "$WEB_DIR/services.html"
  run_cmd cp "$REPO_DIR/backend/captive-portal-lentium/blocked.html" "$WEB_DIR/blocked.html"
  run_cmd cp "$REPO_DIR/backend/captive-portal-lentium/people.html" "$WEB_DIR/people.html"
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
        return 302 http://\$server_addr/portal;
    }

    # ── Detección de portal cautivo por fabricante / SO ──────────────────────
    # IMPORTANTE: se usa URL absoluta con la IP real del servidor (\$server_addr)
    # en lugar de una ruta relativa.  Con un redirect relativo (/portal) el OS
    # construye "http://connectivitycheck.plataforma-del-fabricante.com/portal"
    # (mismo host) y muchos equipos —especialmente Huawei EMUI / HarmonyOS—
    # NO muestran la notificación de portal cautivo porque interpretan el mismo
    # host como "sin redirección real".  Con la IP del portal en la Location el
    # OS detecta inequívocamente que está siendo redirigido a otro servidor.

    # Android AOSP / Pixel / la mayoría de marcas
    location = /generate_204            { return 302 http://\$server_addr/portal; }

    # Apple iOS / macOS (CaptiveNetworkSupport)
    location = /hotspot-detect.html     { return 302 http://\$server_addr/portal; }
    location = /library/test/success.html { return 302 http://\$server_addr/portal; }
    location = /success.html            { return 302 http://\$server_addr/portal; }

    # Microsoft Windows (NCSI)
    location = /connecttest.txt         { return 302 http://\$server_addr/portal; }
    location = /ncsi.txt                { return 302 http://\$server_addr/portal; }
    location = /redirect                { return 302 http://\$server_addr/portal; }

    # Mozilla Firefox
    location = /canonical.html          { return 302 http://\$server_addr/portal; }
    location = /success.txt             { return 302 http://\$server_addr/portal; }

    # Huawei EMUI / HarmonyOS
    # Usan /generate_204 (ya cubierto arriba) con host connectivitycheck.platform.hicloud.com
    # Algunas versiones EMUI también intentan estas rutas adicionales:
    location = /phone/phone.html        { return 302 http://\$server_addr/portal; }
    location = /generate_204.do        { return 302 http://\$server_addr/portal; }

    # Xiaomi MIUI
    location = /miui/check             { return 302 http://\$server_addr/portal; }

    # Samsung (algunos modelos OneUI)
    location = /wifiAuth.do            { return 302 http://\$server_addr/portal; }

    # ── Páginas reales del portal (mayor prioridad por ser exact match = ) ────
    location = /portal { try_files /portal.html =404; }
    location = /services { try_files /services.html =404; }
    location = /blocked { try_files /blocked.html =404; }
    location = /people { try_files /people.html =404; }
    location /blocked-art/ { try_files \$uri =404; }

    # Endpoints UI de AI (siguen en Raspi4B)
    location = /dashboard { proxy_pass http://${AI_ENDPOINT}/dashboard; proxy_set_header Host \$host; proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto \$scheme; }
    location = /terminal { proxy_pass http://${AI_ENDPOINT}/terminal; proxy_set_header Host \$host; proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto \$scheme; }
    location = /rulez { proxy_pass http://${AI_ENDPOINT}/rulez; proxy_set_header Host \$host; proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto \$scheme; }

    # Endpoints del backend de registro (ahora local en Raspi3BPortal)
    location = /accepted { proxy_pass http://127.0.0.1:${BACKEND_PORT}/accepted; proxy_set_header Host \$host; proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto \$scheme; }
    location = /health { proxy_pass http://127.0.0.1:${BACKEND_PORT}/health; proxy_set_header Host \$host; proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto \$scheme; }
    location = /api/register/client { proxy_pass http://127.0.0.1:${BACKEND_PORT}/api/register/client; proxy_set_header Host \$host; proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto \$scheme; }
    location = /api/register/guest { proxy_pass http://127.0.0.1:${BACKEND_PORT}/api/register/guest; proxy_set_header Host \$host; proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto \$scheme; }
    location = /api/register/quest { proxy_pass http://127.0.0.1:${BACKEND_PORT}/api/register/quest; proxy_set_header Host \$host; proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto \$scheme; }
    location = /api/portal/context { proxy_pass http://127.0.0.1:${BACKEND_PORT}/api/portal/context; proxy_set_header Host \$host; proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto \$scheme; }
    location = /api/registros/clientes { proxy_pass http://127.0.0.1:${BACKEND_PORT}/api/registros/clientes; proxy_set_header Host \$host; proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto \$scheme; }
    location = /api/registros/invitados { proxy_pass http://127.0.0.1:${BACKEND_PORT}/api/registros/invitados; proxy_set_header Host \$host; proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto \$scheme; }
    location = /api/people/dashboard { proxy_pass http://127.0.0.1:${BACKEND_PORT}/api/people/dashboard; proxy_set_header Host \$host; proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto \$scheme; }
    location = /api/demo/dashboard { proxy_pass http://127.0.0.1:${BACKEND_PORT}/api/demo/dashboard; proxy_set_header Host \$host; proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto \$scheme; }
    location = /api/services/status { proxy_pass http://127.0.0.1:${BACKEND_PORT}/api/services/status; proxy_set_header Host \$host; proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto \$scheme; }
    location = /api/services/action { proxy_pass http://127.0.0.1:${BACKEND_PORT}/api/services/action; proxy_set_header Host \$host; proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto \$scheme; }
    location = /accept { proxy_pass http://127.0.0.1:${BACKEND_PORT}/accept; proxy_set_header Host \$host; proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto \$scheme; }

    # APIs restantes de análisis siguen en AI node
    location /api/ {
        proxy_pass http://${AI_ENDPOINT}/api/;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
    }

    # ── Catch-all: cualquier ruta no reconocida → portal ─────────────────────
    # Este bloque atrapa las peticiones de detección captive de fabricantes con
    # paths propios que no estén listados arriba (Honor, Oppo, Vivo, OnePlus…).
    # Prioridad nginx: location = (exact) > location ^~ > location ~ (regex) >
    # location /prefix (longest wins).  Las rutas del portal (=/portal,
    # =/services, =/blocked, =/people, /blocked-art/, /api/) son más específicas
    # que "location /" y no se ven afectadas por este fallback.
    location / {
        return 302 http://\$server_addr/portal;
    }
}
EOF
}

build_backend_image() {
  if $NO_BUILD; then
    log_info "NO_BUILD activo: se omite build de backend portal node"
    return 0
  fi
  run_cmd podman build \
    --runtime=runc \
    --network=host \
    -t "$IMAGE_BACKEND" \
    "$REPO_DIR/backend/captive-portal-lentium"
}

deploy_backend_container() {
  run_cmd mkdir -p "$DB_HOST_DIR" /opt/keys
  run_cmd podman rm -f "$CONTAINER_NAME_BACKEND" >/dev/null 2>&1 || true
  run_cmd podman run -d --name "$CONTAINER_NAME_BACKEND" \
    --restart unless-stopped \
    --network host \
    -e ROUTER_IP="${ROUTER_IP}" \
    -e PORTAL_IP="${PORTAL_IP}" \
    -e DB_PATH="/data/lentium.db" \
    -e PORT="${BACKEND_PORT}" \
    -e SSH_KEY="/opt/keys/captive-portal" \
    -e REPO_PATH="$REPO_DIR" \
    -v "$DB_HOST_DIR:/data" \
    -v "/opt/keys:/opt/keys:ro" \
    "$IMAGE_BACKEND"
}

deploy_frontend_container() {
  run_cmd podman rm -f "$CONTAINER_NAME_FRONTEND" >/dev/null 2>&1 || true
  # DietPi en algunas Raspi no trae nftables userspace por defecto.
  # netavark (red bridge de podman) depende de `nft`; con host network evitamos ese requisito.
  run_cmd podman run -d --name "$CONTAINER_NAME_FRONTEND" \
    --restart unless-stopped \
    --network host \
    -v "$WEB_DIR:/usr/share/nginx/html:ro" \
    -v "$CONF_DIR/default.conf:/etc/nginx/conf.d/default.conf:ro" \
    "$IMAGE_FRONTEND"
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
  running="$(podman inspect -f '{{.State.Running}}' "$CONTAINER_NAME_FRONTEND" 2>/dev/null || echo false)"
  if [[ "$running" != "true" ]]; then
    log_error "Contenedor $CONTAINER_NAME_FRONTEND no está running"
    podman ps -a --filter "name=$CONTAINER_NAME_FRONTEND" || true
    log_info "Logs del contenedor:"
    podman logs "$CONTAINER_NAME_FRONTEND" 2>/dev/null || true
    show_port80_debug
    die "El contenedor no levantó correctamente"
  fi

  running="$(podman inspect -f '{{.State.Running}}' "$CONTAINER_NAME_BACKEND" 2>/dev/null || echo false)"
  if [[ "$running" != "true" ]]; then
    log_error "Contenedor $CONTAINER_NAME_BACKEND no está running"
    podman ps -a --filter "name=$CONTAINER_NAME_BACKEND" || true
    podman inspect "$CONTAINER_NAME_BACKEND" 2>/dev/null | sed -n '1,120p' || true
    log_info "Logs backend:"
    podman logs "$CONTAINER_NAME_BACKEND" 2>/dev/null || true
    die "El backend de registro no levantó correctamente"
  fi
}

wait_backend_ready() {
  local i code
  for i in $(seq 1 25); do
    code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 5 "http://127.0.0.1:${BACKEND_PORT}/api/portal/context" 2>/dev/null)" || code="000"
    case "$code" in
      200|301|302|307|308)
        log_ok "Backend local listo en :${BACKEND_PORT} (HTTP ${code})"
        return 0
        ;;
      500|503)
        # El backend ya está arriba pero puede fallar temporalmente por dependencias externas.
        log_ok "Backend responde en :${BACKEND_PORT} (HTTP ${code})"
        return 0
        ;;
    esac
    sleep 1
  done

  log_error "Backend local no respondió en :${BACKEND_PORT}"
  podman ps -a --filter "name=$CONTAINER_NAME_BACKEND" || true
  log_info "Logs backend:"
  podman logs "$CONTAINER_NAME_BACKEND" 2>/dev/null || true
  die "Backend de registro no disponible"
}

install_autostart_service() {
  # Crea un servicio systemd que arranca los contenedores del portal en cada boot.
  # --restart unless-stopped de podman NO sobrevive reinicios del sistema;
  # solo un servicio de systemd garantiza el arranque automático.
  local SERVICE_FILE="/etc/systemd/system/captive-portal-node.service"

  log_info "Instalando servicio systemd de autoarranque: captive-portal-node"

  run_cmd bash -c "cat > '$SERVICE_FILE'" <<EOF
[Unit]
Description=Captive Portal Node — frontend (nginx) + backend (lentium)
Documentation=https://github.com/rafex/presentaciones-cursos-talleres
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes

# Arranca primero el backend (el frontend hace proxy hacia él)
ExecStart=/usr/bin/podman start ${CONTAINER_NAME_BACKEND}
ExecStart=/usr/bin/podman start ${CONTAINER_NAME_FRONTEND}

# Para en orden inverso
ExecStop=/usr/bin/podman stop -t 10 ${CONTAINER_NAME_FRONTEND}
ExecStop=/usr/bin/podman stop -t 10 ${CONTAINER_NAME_BACKEND}

Restart=no
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  run_cmd systemctl daemon-reload
  run_cmd systemctl enable captive-portal-node.service
  log_ok "Servicio habilitado: captive-portal-node.service"
  log_info "Los contenedores arrancarán automáticamente en el próximo reboot"
}

verify_local() {
  local ep code
  for ep in /portal /services /blocked /people /api/history /api/portal/context; do
    code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "http://127.0.0.1${ep}" 2>/dev/null)" || code="000"
    case "$code" in
      200|301|302|307|308) log_ok "${ep} local HTTP ${code}" ;;
      *)
        log_error "Verificación fallida ${ep}: HTTP ${code}"
        podman ps -a --filter "name=$CONTAINER_NAME_FRONTEND" || true
        podman ps -a --filter "name=$CONTAINER_NAME_BACKEND" || true
        log_info "Logs frontend:"
        podman logs "$CONTAINER_NAME_FRONTEND" 2>/dev/null || true
        log_info "Logs backend:"
        podman logs "$CONTAINER_NAME_BACKEND" 2>/dev/null || true
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
  build_backend_image
  deploy_backend_container
  wait_backend_ready
  deploy_frontend_container
  check_container_running
  install_autostart_service
fi

if ! $DRY_RUN; then
  verify_local
fi

log_ok "portal-node-deploy completado"
