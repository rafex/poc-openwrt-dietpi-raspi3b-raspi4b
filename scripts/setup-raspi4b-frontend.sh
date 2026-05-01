#!/bin/bash
# setup-raspi4b-frontend.sh — Despliega frontend + nginx proxy en podman
#
# Qué hace:
#   1. Construye el frontend (npm install + npm run build) en la Pi o copia dist/
#   2. Construye imagen podman ai-analyzer-frontend (nginx:alpine + dist/)
#   3. Construye imagen podman ai-analyzer-proxy   (nginx:alpine + proxy config)
#   4. Crea red podman ai-net si no existe
#   5. Arranca/reemplaza contenedores frontend y proxy
#   6. Verifica que :80 responde
#
# Uso:
#   bash scripts/setup-raspi4b-frontend.sh
#   bash scripts/setup-raspi4b-frontend.sh --skip-build   # solo redesplegar
#   bash scripts/setup-raspi4b-frontend.sh --dry-run

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=./lib/raspi4b-common.sh
. "$SCRIPT_DIR/lib/raspi4b-common.sh"
# shellcheck source=./lib/topology-common.sh
. "$SCRIPT_DIR/lib/topology-common.sh"

# ── Flags extra ───────────────────────────────────────────────────────────────
SKIP_BUILD=false

_parse_extra_flags() {
    local -a extra=()
    for arg in "$@"; do
        case "$arg" in
            --skip-build) SKIP_BUILD=true ;;
            *) extra+=("$arg") ;;
        esac
    done
    parse_common_flags "${extra[@]+"${extra[@]}"}"
}
_parse_extra_flags "$@"

init_log_dir "frontend"
load_topology

PI_IP="${AI_IP:-${RASPI4B_IP:-192.168.1.167}}"
BACKEND_HOST="${BACKEND_HOST:-host.containers.internal}"
BACKEND_PORT="${BACKEND_PORT:-5000}"

FRONTEND_DIR="$REPO_DIR/frontend"
NGINX_FRONTEND_DIR="$REPO_DIR/nginx/frontend"
NGINX_PROXY_DIR="$REPO_DIR/nginx/proxy"

NET_NAME="ai-net"
CTR_FRONTEND="ai-analyzer-frontend"
CTR_PROXY="ai-analyzer-proxy"
IMG_FRONTEND="ai-analyzer-frontend:latest"
IMG_PROXY="ai-analyzer-proxy:latest"

log_info "--- setup-raspi4b-frontend ---"

# ── Asegurar Node.js >= 20 si vamos a compilar ────────────────────────────────
_need_node() {
    command -v node &>/dev/null || return 1
    local ver; ver="$(node --version 2>/dev/null)"
    [[ "$ver" =~ ^v(2[0-9]|[3-9][0-9]) ]] || return 1
}

if ! $SKIP_BUILD && ! _need_node; then
    log_info "Node.js >= 20 no encontrado — instalando via NodeSource..."
    apt_update_once
    run_cmd apt-get install -y -q curl
    if ! $DRY_RUN; then
        curl -fsSL "https://deb.nodesource.com/setup_20.x" \
            | env DEBIAN_FRONTEND=noninteractive bash -
        run_cmd env DEBIAN_FRONTEND=noninteractive apt-get install -y -q nodejs
    else
        log_info "[dry-run] instalar Node.js 20 via NodeSource"
    fi
fi

ensure_cmd podman
$SKIP_BUILD || ensure_cmd npm node

# ── 1. Build frontend ─────────────────────────────────────────────────────────
if ! $SKIP_BUILD; then
    log_info "Instalando dependencias npm..."
    run_cmd npm --prefix "$FRONTEND_DIR" install --prefer-offline

    log_info "Compilando frontend (pug + sass + ts + vite build)..."
    run_cmd npm --prefix "$FRONTEND_DIR" run build

    log_ok "dist/ generado en $FRONTEND_DIR/dist"
else
    log_info "--skip-build: usando dist/ existente"
    [[ -d "$FRONTEND_DIR/dist" ]] || die "dist/ no existe, ejecuta sin --skip-build"
fi

if $DRY_RUN; then
    log_ok "[dry-run] build completado"
    exit 0
fi

# ── 2. Copiar dist/ junto al Dockerfile del frontend ─────────────────────────
log_info "Preparando contexto de imagen frontend..."
run_cmd rm -rf  "$NGINX_FRONTEND_DIR/dist"
run_cmd cp -r   "$FRONTEND_DIR/dist" "$NGINX_FRONTEND_DIR/dist"

# ── 3. Construir imágenes ─────────────────────────────────────────────────────
log_info "Construyendo imagen $IMG_FRONTEND ..."
run_cmd podman build -t "$IMG_FRONTEND" "$NGINX_FRONTEND_DIR"

log_info "Construyendo imagen $IMG_PROXY ..."
run_cmd podman build -t "$IMG_PROXY" "$NGINX_PROXY_DIR"

# ── 4. Red podman ─────────────────────────────────────────────────────────────
if ! podman network inspect "$NET_NAME" &>/dev/null; then
    log_info "Creando red podman $NET_NAME ..."
    run_cmd podman network create "$NET_NAME"
fi

# ── 5. Contenedor frontend ────────────────────────────────────────────────────
_stop_rm() {
    local name="$1"
    if podman ps -a --format '{{.Names}}' | grep -q "^${name}$"; then
        log_info "Deteniendo contenedor anterior: $name"
        podman stop  "$name" 2>/dev/null || true
        podman rm    "$name" 2>/dev/null || true
    fi
}

_stop_rm "$CTR_FRONTEND"
log_info "Iniciando $CTR_FRONTEND ..."
run_cmd podman run -d \
    --name "$CTR_FRONTEND" \
    --network "$NET_NAME" \
    --restart unless-stopped \
    "$IMG_FRONTEND"

# ── 6. Contenedor proxy ───────────────────────────────────────────────────────
_stop_rm "$CTR_PROXY"
log_info "Iniciando $CTR_PROXY ..."
run_cmd podman run -d \
    --name "$CTR_PROXY" \
    --network "$NET_NAME" \
    --network host \
    --restart unless-stopped \
    -e "BACKEND_HOST=${BACKEND_HOST}" \
    -e "BACKEND_PORT=${BACKEND_PORT}" \
    -e "FRONTEND_HOST=${CTR_FRONTEND}" \
    -e "FRONTEND_PORT=3000" \
    -p 80:80 \
    "$IMG_PROXY"

# ── 7. Verificar ─────────────────────────────────────────────────────────────
log_info "Esperando que nginx arranque..."
WAIT=0
until curl -sf "http://127.0.0.1:80/proxy-ping" >/dev/null 2>&1; do
    sleep 2; WAIT=$((WAIT + 2))
    [[ $WAIT -ge 20 ]] && {
        podman logs "$CTR_PROXY" 2>&1 | tail -20
        die "proxy nginx no respondió en 20s"
    }
done
log_ok "nginx proxy responde en :80 (${WAIT}s)"

for path in / /dashboard /chat /terminal /rulez /reports /health; do
    code="$(curl -s -o /dev/null -w '%{http_code}' \
        --connect-timeout 5 --max-time 10 \
        "http://${PI_IP}:80${path}" 2>/dev/null || echo 000)"
    case "$code" in
        200|301|302) log_ok "${path}  HTTP ${code}" ;;
        *)           log_warn "${path}  HTTP ${code} (inesperado)" ;;
    esac
done

printf "\n"
log_ok "Frontend desplegado"
printf "\n"
printf "  Acceso:\n"
printf "    http://%s/           → Dashboard\n" "$PI_IP"
printf "    http://%s/chat       → Chat IA\n"   "$PI_IP"
printf "    http://%s/terminal   → Terminal\n"  "$PI_IP"
printf "    http://%s/rulez      → Reglas\n"    "$PI_IP"
printf "    http://%s/reports    → Reportes\n"  "$PI_IP"
printf "    http://%s/health     → Health API\n" "$PI_IP"
printf "\n"
printf "  Gestión:\n"
printf "    podman ps\n"
printf "    podman logs -f %s\n" "$CTR_PROXY"
printf "    podman logs -f %s\n" "$CTR_FRONTEND"
printf "\n"
