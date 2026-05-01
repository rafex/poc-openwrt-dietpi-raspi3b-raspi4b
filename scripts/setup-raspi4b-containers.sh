#!/bin/bash
# setup-raspi4b-containers.sh
#
# Descarga las imágenes publicadas en ghcr.io y despliega el stack completo
# de ai-analyzer en la Raspberry Pi 4B via podman.
#
# Contenedores desplegados:
#   ai-analyzer-java   — backend Java GraalVM arm64  (puerto 5000)
#   ai-analyzer-python — backend Python arm64        (puerto 5000, alternativo)
#   ai-analyzer-web    — nginx + frontend Vite       (puerto 80)
#
# Java y Python son ALTERNATIVOS (ambos usan el puerto 5000). Por defecto
# se despliega Java como backend.
#
# Uso:
#   bash scripts/setup-raspi4b-containers.sh
#   bash scripts/setup-raspi4b-containers.sh --release v1.2.3
#   bash scripts/setup-raspi4b-containers.sh --backend python
#   bash scripts/setup-raspi4b-containers.sh --skip-backend      # solo web
#   bash scripts/setup-raspi4b-containers.sh --skip-web          # solo backend
#   bash scripts/setup-raspi4b-containers.sh --no-pull           # usar imágenes locales
#   bash scripts/setup-raspi4b-containers.sh --build-local       # build desde GitHub Releases
#   bash scripts/setup-raspi4b-containers.sh --only-verify
#   bash scripts/setup-raspi4b-containers.sh --dry-run
#
# Variables de entorno:
#   GHCR_TOKEN   — token para ghcr.io (opcional si los paquetes son públicos)
#   RASPI4B_IP   — IP del nodo (default: 192.168.1.167)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=./lib/raspi4b-common.sh
. "$SCRIPT_DIR/lib/raspi4b-common.sh"
# shellcheck source=./lib/topology-common.sh
. "$SCRIPT_DIR/lib/topology-common.sh"

# ── Flags propios de este script ──────────────────────────────────────────────
RELEASE="latest"
BACKEND="java"           # java | python
SKIP_BACKEND=false
SKIP_WEB=false
NO_PULL=false
BUILD_LOCAL=false
GHCR_USER="${GITHUB_ACTOR:-rafex}"
GHCR_TOKEN="${GHCR_TOKEN:-}"

# parse_common_flags maneja: --dry-run --only-verify --force --no-build
# Los flags restantes los parsea este bucle
_extra_args=()
for arg in "$@"; do
    case "$arg" in
        --release=*)     RELEASE="${arg#--release=}" ;;
        --release)       ;; # manejado con shift en el loop por pares
        --backend=*)     BACKEND="${arg#--backend=}" ;;
        --backend)       ;;
        --skip-backend)  SKIP_BACKEND=true ;;
        --skip-web)      SKIP_WEB=true ;;
        --no-pull)       NO_PULL=true ;;
        --build-local)   BUILD_LOCAL=true ;;
        --ghcr-token=*)  GHCR_TOKEN="${arg#--ghcr-token=}" ;;
        --ghcr-user=*)   GHCR_USER="${arg#--ghcr-user=}" ;;
        *)               _extra_args+=("$arg") ;;
    esac
done

# Manejar pares --flag valor
_i=0
while [[ $_i -lt ${#_extra_args[@]} ]]; do
    case "${_extra_args[$_i]}" in
        --release)    RELEASE="${_extra_args[$((_i+1))]}";    _i=$((_i+2)) ;;
        --backend)    BACKEND="${_extra_args[$((_i+1))]}";    _i=$((_i+2)) ;;
        --ghcr-token) GHCR_TOKEN="${_extra_args[$((_i+1))]}"; _i=$((_i+2)) ;;
        --ghcr-user)  GHCR_USER="${_extra_args[$((_i+1))]}";  _i=$((_i+2)) ;;
        *) _i=$((_i+1)) ;;
    esac
done

# Delegar flags comunes al parser de la librería
parse_common_flags "$@"
init_log_dir "containers"
need_root

# ── Validaciones ──────────────────────────────────────────────────────────────
case "$BACKEND" in
    java|python) ;;
    *) die "--backend debe ser 'java' o 'python' (recibido: $BACKEND)" ;;
esac

log_info "─── setup-raspi4b-containers ─────────────────────────────────────────"
log_info "  Release   : $RELEASE"
log_info "  Backend   : $BACKEND"
log_info "  Skip-backend: $SKIP_BACKEND"
log_info "  Skip-web  : $SKIP_WEB"
log_info "  No-pull   : $NO_PULL"
log_info "  Build-local: $BUILD_LOCAL"

ensure_cmd bash curl podman
load_topology

# DietPi suele ejecutarse sin systemd como PID 1; forzamos cgroupfs para evitar
# errores de crun/sd-bus al crear/iniciar contenedores.
PODMAN_BIN="podman --cgroup-manager=cgroupfs"

# ── Configuración de imágenes ─────────────────────────────────────────────────
GHCR_REGISTRY="ghcr.io"
IMAGE_JAVA="${GHCR_REGISTRY}/${GHCR_USER}/poc-ai-analyzer-java:${RELEASE}"
IMAGE_PYTHON="${GHCR_REGISTRY}/${GHCR_USER}/poc-ai-analyzer-python:${RELEASE}"
IMAGE_WEB="${GHCR_REGISTRY}/${GHCR_USER}/poc-ai-analyzer-web:${RELEASE}"

# Nombres de los contenedores (si ya existe uno del otro backend, se eliminará)
CONTAINER_BACKEND="ai-analyzer"   # nombre unificado (java o python, no ambos)
CONTAINER_WEB="ai-analyzer-web"

# Directorios y archivos
DATA_DIR="/opt/analyzer/data"
KEYS_DIR="/opt/keys"
ENV_FILE="/etc/ai-analyzer.env"
SYSTEMD_BACKEND="/etc/systemd/system/ai-analyzer.service"
SYSTEMD_WEB="/etc/systemd/system/ai-analyzer-web.service"
HOST_LOG_DIR="/var/log/ai-analyzer"
BACKEND_CONTAINER_LOG="${HOST_LOG_DIR}/ai-analyzer.container.log"
WEB_CONTAINER_LOG="${HOST_LOG_DIR}/ai-analyzer-web.container.log"
BACKEND_SERVICE_LOG="${HOST_LOG_DIR}/ai-analyzer.service.log"
WEB_SERVICE_LOG="${HOST_LOG_DIR}/ai-analyzer-web.service.log"

PI_IP="${AI_IP:-${RASPI4B_IP:-192.168.1.167}}"

# ── 1. Instalar age + sops si no están ───────────────────────────────────────
_install_sops_tools() {
    local need_age=false need_sops=false
    command -v age  &>/dev/null || need_age=true
    command -v sops &>/dev/null || need_sops=true
    $need_age || $need_sops || return 0

    log_info "Instalando herramientas de secretos (age/sops)..."
    apt_update_once
    $need_age && run_cmd apt-get install -y -q age

    if $need_sops; then
        if apt-cache show sops &>/dev/null 2>&1; then
            run_cmd apt-get install -y -q sops
        else
            local ver="3.9.1"
            run_cmd curl -fsSL \
                "https://github.com/getsops/sops/releases/download/v${ver}/sops-v${ver}.linux.arm64" \
                -o /usr/local/bin/sops
            run_cmd chmod +x /usr/local/bin/sops
        fi
    fi
    command -v age  &>/dev/null || die "age no pudo instalarse"
    command -v sops &>/dev/null || die "sops no pudo instalarse"
    log_ok "age y sops disponibles"
}

_install_sops_tools

# ── 2. Descifrar secretos ────────────────────────────────────────────────────
SECRETS_FILE="$REPO_DIR/secrets/raspi4b.yaml"
AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-/root/.config/sops/age/keys.txt}"
GROQ_API_KEY=""
GROQ_MODEL_VAL="qwen/qwen3-32b"

if [[ -f "$SECRETS_FILE" ]]; then
    if [[ ! -f "$AGE_KEY_FILE" ]]; then
        log_warn "Clave age no encontrada: $AGE_KEY_FILE"
        log_warn "Desplegando sin secretos (Groq deshabilitado)"
    else
        log_info "Descifrando secretos con sops+age..."
        _STMP=$(mktemp /dev/shm/sops-XXXXXX 2>/dev/null || mktemp)
        chmod 600 "$_STMP"
        trap "rm -f '$_STMP'" EXIT

        if SOPS_AGE_KEY_FILE="$AGE_KEY_FILE" \
           sops -d --output-type dotenv "$SECRETS_FILE" > "$_STMP" 2>/dev/null; then
            GROQ_API_KEY="$(grep '^GROQ_API_KEY=' "$_STMP" | head -1 | cut -d= -f2- | tr -d '"' || true)"
            GROQ_MODEL_VAL="$(grep '^GROQ_MODEL=' "$_STMP" | head -1 | cut -d= -f2- | tr -d '"' || echo 'qwen/qwen3-32b')"
            rm -f "$_STMP"; trap - EXIT
            [[ -n "$GROQ_API_KEY" ]] \
                && log_ok "Secretos descifrados — GROQ_API_KEY: ${#GROQ_API_KEY} chars" \
                || log_info "Secretos descifrados — GROQ_API_KEY vacío (modo llama.cpp local)"
        else
            rm -f "$_STMP"; trap - EXIT
            log_warn "sops no pudo descifrar $SECRETS_FILE — continuando sin Groq"
        fi
    fi
else
    log_info "secrets/raspi4b.yaml no encontrado — desplegando sin Groq"
fi

if $ONLY_VERIFY; then
    log_info "─── Verificación de endpoints ────────────────────────────────────────"
    _verify_endpoints
    exit 0
fi

if $DRY_RUN; then
    log_info "─── DRY-RUN ─────────────────────────────────────────────────────────"
    log_info "  Backend image : $( $SKIP_BACKEND && echo '(omitido)' || ( [[ $BACKEND == java ]] && echo "$IMAGE_JAVA" || echo "$IMAGE_PYTHON" ) )"
    log_info "  Web image     : $( $SKIP_WEB && echo '(omitido)' || echo "$IMAGE_WEB" )"
    log_info "  Env file      : $ENV_FILE"
    log_info "  Data dir      : $DATA_DIR"
    log_ok "Dry-run completado. Ejecuta sin --dry-run para aplicar."
    exit 0
fi

# ── 3. Login a ghcr.io ────────────────────────────────────────────────────────
if ! $NO_PULL; then
    if [[ -n "$GHCR_TOKEN" ]]; then
        log_info "Autenticando en ${GHCR_REGISTRY} como ${GHCR_USER}..."
        run_cmd printf '%s' "$GHCR_TOKEN" | \
            $PODMAN_BIN login "$GHCR_REGISTRY" --username "$GHCR_USER" --password-stdin
        log_ok "Login en ${GHCR_REGISTRY} OK"
    else
        log_info "GHCR_TOKEN no definido — intentando pull sin autenticación (paquetes públicos)"
    fi
fi

# ── 4. Escribir /etc/ai-analyzer.env ─────────────────────────────────────────
log_info "Escribiendo ${ENV_FILE}..."

_MQTT_HOST="${RASPI4B_IP:-192.168.1.167}"
_ROUTER_IP="${ROUTER_IP:-192.168.1.1}"
_PORTAL_IP="${PORTAL_IP:-192.168.1.167}"
_RASPI3B_IP="${RASPI3B_IP:-192.168.1.181}"
_PORTAL_NODE_IP="${PORTAL_NODE_IP:-192.168.1.182}"
_AP_EXT_IP="${AP_EXTENDER_IP:-192.168.1.183}"
_ADMIN_IP="${ADMIN_IP:-192.168.1.113}"

cat > "$ENV_FILE" <<ENVEOF
# /etc/ai-analyzer.env — Variables para el contenedor ai-analyzer
# Generado por setup-raspi4b-containers.sh el $(date '+%Y-%m-%d %H:%M:%S')
# chmod 600 — solo root puede leer GROQ_API_KEY

# ── MQTT ──────────────────────────────────────────────────────────────────────
MQTT_HOST=${_MQTT_HOST}
MQTT_PORT=1883
MQTT_TOPIC=rafexpi/sensor/batch

# ── Base de datos ─────────────────────────────────────────────────────────────
DB_PATH=/data/sensor.db

# ── llama.cpp (fallback local en :8081) ───────────────────────────────────────
LLAMA_URL=http://${_MQTT_HOST}:8081
MODEL_FORMAT=tinyllama
N_PREDICT=256

# ── Groq API ──────────────────────────────────────────────────────────────────
GROQ_API_KEY=${GROQ_API_KEY}
GROQ_MODEL=${GROQ_MODEL_VAL}
GROQ_MAX_TOKENS=1024

# ── Red e infraestructura ─────────────────────────────────────────────────────
PORT=5000
ROUTER_IP=${_ROUTER_IP}
ROUTER_USER=root
SSH_KEY=/opt/keys/captive-portal
PORTAL_IP=${_PORTAL_IP}
ADMIN_IP=${_ADMIN_IP}
RASPI4B_IP=${_MQTT_HOST}
RASPI3B_IP=${_RASPI3B_IP}
PORTAL_NODE_IP=${_PORTAL_NODE_IP}
AP_EXTENDER_IP=${_AP_EXT_IP}

# ── Políticas ─────────────────────────────────────────────────────────────────
SOCIAL_BLOCK_ENABLED=true
SOCIAL_POLICY_START_HOUR=9
SOCIAL_POLICY_END_HOUR=17
SOCIAL_POLICY_TZ=America/Mexico_City
SOCIAL_MIN_HITS=3
PORN_BLOCK_ENABLED=true

# ── Features ──────────────────────────────────────────────────────────────────
FEATURE_DOMAIN_CLASSIFIER=true
FEATURE_DOMAIN_CLASSIFIER_LLM=true
DOMAIN_CLASSIFIER_LLM_MAX_NEW_PER_REQUEST=2
DOMAIN_CLASSIFIER_LLM_TIMEOUT_S=8
DOMAIN_CLASSIFIER_LLM_N_PREDICT=48
DOMAIN_CLASSIFIER_LLM_MAX_QUEUE_SIZE=4
FEATURE_CHAT=true
FEATURE_HUMAN_EXPLAIN=true
FEATURE_PORTAL_RISK_MESSAGE=true
FEATURE_DEVICE_PROFILING=true
FEATURE_AUTO_REPORTS=true

# ── Misc ──────────────────────────────────────────────────────────────────────
LOG_LEVEL=INFO
PYTHONUNBUFFERED=1
SUMMARY_INTERVAL_S=60
ENVEOF

chmod 600 "$ENV_FILE"
log_ok "${ENV_FILE} escrito (chmod 600)"

# ── 5. Preparar directorios ───────────────────────────────────────────────────
run_cmd mkdir -p "$DATA_DIR" "$KEYS_DIR"
log_ok "Directorios: $DATA_DIR  $KEYS_DIR"

run_cmd mkdir -p "$HOST_LOG_DIR"
run_cmd chmod 755 "$HOST_LOG_DIR"
run_cmd touch "$BACKEND_CONTAINER_LOG" "$WEB_CONTAINER_LOG" "$BACKEND_SERVICE_LOG" "$WEB_SERVICE_LOG"
run_cmd chmod 644 "$BACKEND_CONTAINER_LOG" "$WEB_CONTAINER_LOG" "$BACKEND_SERVICE_LOG" "$WEB_SERVICE_LOG"
log_ok "Logs de contenedores en host: $HOST_LOG_DIR"

# ── 6. Desplegar backend ──────────────────────────────────────────────────────
_pull_image_with_fallback() {
    local image_name="$1"
    local selected="$image_name"
    local repo_path="${image_name#${GHCR_REGISTRY}/}"
    repo_path="${repo_path%%:*}"

    _list_release_tags() {
        # Lista tags semánticos desde GitHub Releases (no requiere GHCR auth).
        # Se usa como ayuda cuando latest no existe en GHCR.
        curl -fsSL "https://api.github.com/repos/${GHCR_USER}/presentaciones-cursos-talleres/releases?per_page=12" 2>/dev/null \
            | grep -o '"tag_name":[[:space:]]*"[^"]*"' \
            | sed -E 's/.*"([^"]+)"/\1/' \
            | head -6
    }

    log_info "Pulling $image_name ..."
    if run_cmd $PODMAN_BIN pull --platform linux/arm64 "$image_name"; then
        log_ok "Pull completado: $image_name"
        PULLED_IMAGE="$selected"
        return 0
    fi

    # Fallback seguro para GHCR cuando no existe :latest (solo hay previews).
    if [[ "$RELEASE" == "latest" ]]; then
        local fallback="${image_name%:latest}:preview"
        log_warn "Tag latest no disponible en GHCR. Intentando fallback: $fallback"
        if run_cmd $PODMAN_BIN pull --platform linux/arm64 "$fallback"; then
            log_ok "Pull completado con fallback: $fallback"
            log_warn "Se está usando 'preview' porque 'latest' no existe para ${repo_path}"
            PULLED_IMAGE="$fallback"
            return 0
        fi

        log_warn "Tampoco se pudo descargar 'preview' para ${repo_path}"
        local tags
        tags="$(_list_release_tags || true)"
        if [[ -n "$tags" ]]; then
            log_info "Tags sugeridos (GitHub Releases):"
            printf '%s\n' "$tags" | sed 's/^/  - /'
        else
            log_warn "No se pudieron consultar tags sugeridos vía GitHub API"
        fi

        if [[ -t 0 && -t 1 ]]; then
            printf "\nSelecciona un tag para continuar (ej: v1.2.3 o preview), Enter para cancelar: "
            read -r chosen_tag || true
            if [[ -n "${chosen_tag:-}" ]]; then
                local chosen_image="${image_name%:latest}:$chosen_tag"
                log_info "Intentando tag seleccionado: $chosen_image"
                if run_cmd $PODMAN_BIN pull --platform linux/arm64 "$chosen_image"; then
                    log_ok "Pull completado: $chosen_image"
                    PULLED_IMAGE="$chosen_image"
                    return 0
                fi
                log_warn "Falló el pull del tag seleccionado: $chosen_tag"
            fi
        fi
    fi

    die "No se pudo descargar imagen: $image_name
Opciones:
  1) Usar preview: --release=preview
  2) Usar tag explícito: --release=vX.Y.Z
  3) Build local desde release: --build-local --release=vX.Y.Z"
}

_check_image_arch() {
    local image_name="$1"
    local expected="arm64"
    local arch
    arch="$($PODMAN_BIN image inspect "$image_name" --format '{{.Architecture}}' 2>/dev/null || echo unknown)"
    case "$arch" in
        arm64|aarch64)
            log_ok "Arquitectura de imagen OK: $image_name ($arch)"
            return 0
            ;;
        *)
            log_warn "Arquitectura inesperada para $image_name: '$arch' (esperado: arm64)"
            return 1
            ;;
    esac
}

_deploy_backend() {
    local image_name="$1"
    local build_mode="$2"   # pull | local

    log_info "─── Backend ($BACKEND) ──────────────────────────────────────────────"

    # Eliminar contenedor anterior si existe (sea java o python)
    for old_name in ai-analyzer ai-analyzer-java ai-analyzer-python; do
        if $PODMAN_BIN container exists "$old_name" 2>/dev/null; then
            log_info "Eliminando contenedor anterior: $old_name"
            run_cmd $PODMAN_BIN stop -t 10 "$old_name" 2>/dev/null || true
            run_cmd $PODMAN_BIN rm -f "$old_name" 2>/dev/null || true
        fi
    done

    if [[ "$build_mode" == "local" ]]; then
        _build_java_local "$image_name"
    elif ! $NO_PULL; then
        _pull_image_with_fallback "$image_name"
        image_name="$PULLED_IMAGE"
        if ! _check_image_arch "$image_name"; then
            if [[ "$BACKEND" == "java" ]]; then
                die "La imagen Java descargada no es arm64 y fallará con 'exec format error'.
Opciones:
  1) Reintentar con build local arm64:
     bash scripts/setup-raspi4b-containers.sh --backend=java --build-local --release=${RELEASE}
  2) Usar backend Python publicado:
     bash scripts/setup-raspi4b-containers.sh --backend=python --release=${RELEASE}
  3) Usar un tag explícito arm64:
     bash scripts/setup-raspi4b-containers.sh --backend=java --release=vX.Y.Z"
            else
                die "La imagen descargada no es arm64. Usa un tag arm64 válido."
            fi
        fi
    fi

    log_info "Creando contenedor $CONTAINER_BACKEND ..."
    run_cmd $PODMAN_BIN create \
        --name  "$CONTAINER_BACKEND" \
        --restart unless-stopped \
        --network host \
        --log-driver k8s-file \
        --log-opt "path=${BACKEND_CONTAINER_LOG}" \
        --env-file "$ENV_FILE" \
        -v "${DATA_DIR}:/data:z" \
        -v "${KEYS_DIR}:/opt/keys:ro,z" \
        "$image_name"

    run_cmd $PODMAN_BIN start "$CONTAINER_BACKEND"
    log_ok "Contenedor $CONTAINER_BACKEND iniciado"

    # Servicio systemd
    log_info "Instalando $SYSTEMD_BACKEND ..."
    cat > "$SYSTEMD_BACKEND" <<UNITEOF
[Unit]
Description=AI Analyzer backend (${BACKEND}) — sensor de red con IA
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/podman start ${CONTAINER_BACKEND}
ExecStop=/usr/bin/podman stop -t 10 ${CONTAINER_BACKEND}
Restart=no
StandardOutput=append:${BACKEND_SERVICE_LOG}
StandardError=append:${BACKEND_SERVICE_LOG}

[Install]
WantedBy=multi-user.target
UNITEOF

    run_cmd systemctl daemon-reload
    run_cmd systemctl enable ai-analyzer.service
    log_ok "ai-analyzer.service habilitado (autostart)"
}

# ── 6b. Build local desde GitHub Releases (fallback sin ghcr.io) ─────────────
_build_java_local() {
    local target_image="$1"
    local repo_url="https://github.com/${GHCR_USER}/presentaciones-cursos-talleres/releases/download"
    local tmpdir
    tmpdir=$(mktemp -d)
    trap "rm -rf '$tmpdir'" RETURN

    log_info "Descargando artefactos de GitHub Releases (tag: ${RELEASE})..."

    run_cmd curl -fsSL \
        "${repo_url}/${RELEASE}/ai-analyzer-linux-arm64" \
        -o "${tmpdir}/ai-analyzer-linux-arm64"

    run_cmd curl -fsSL \
        "${repo_url}/${RELEASE}/libanalyzer_db-linux-arm64.so" \
        -o "${tmpdir}/libanalyzer_db-linux-arm64.so"

    # Dockerfile mínimo embebido (no requiere el repo en el Pi)
    cat > "${tmpdir}/Dockerfile" <<'DOCKEREOF'
FROM debian:bookworm-slim
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends libstdc++6 ca-certificates wget && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /opt/ai-analyzer
COPY ai-analyzer-linux-arm64        ./bin/ai-analyzer
COPY libanalyzer_db-linux-arm64.so  ./lib/libanalyzer_db.so
RUN mkdir -p /data /opt/keys && chmod +x ./bin/ai-analyzer
ENV LD_LIBRARY_PATH=/opt/ai-analyzer/lib PORT=5000 LOG_LEVEL=INFO
EXPOSE 5000
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD wget -qO- http://localhost:${PORT}/health >/dev/null 2>&1 || exit 1
CMD ["/opt/ai-analyzer/bin/ai-analyzer"]
DOCKEREOF

    log_info "Construyendo imagen local: $target_image ..."
    run_cmd podman build \
        --cgroup-manager=cgroupfs \
        --platform linux/arm64 \
        -t "$target_image" \
        "$tmpdir/"

    log_ok "Imagen local construida: $target_image"
}

# ── 7. Desplegar web (nginx + frontend) ──────────────────────────────────────
_deploy_web() {
    local image_name="$1"

    log_info "─── Web (nginx + frontend) ──────────────────────────────────────────"

    if $PODMAN_BIN container exists "$CONTAINER_WEB" 2>/dev/null; then
        log_info "Eliminando contenedor anterior: $CONTAINER_WEB"
        run_cmd $PODMAN_BIN stop -t 10 "$CONTAINER_WEB" 2>/dev/null || true
        run_cmd $PODMAN_BIN rm -f "$CONTAINER_WEB" 2>/dev/null || true
    fi

    if ! $NO_PULL; then
        _pull_image_with_fallback "$image_name"
        image_name="$PULLED_IMAGE"
    fi

    log_info "Creando contenedor $CONTAINER_WEB ..."
    run_cmd $PODMAN_BIN create \
        --name  "$CONTAINER_WEB" \
        --restart unless-stopped \
        --network host \
        --log-driver k8s-file \
        --log-opt "path=${WEB_CONTAINER_LOG}" \
        "$image_name"

    run_cmd $PODMAN_BIN start "$CONTAINER_WEB"
    log_ok "Contenedor $CONTAINER_WEB iniciado"

    log_info "Instalando $SYSTEMD_WEB ..."
    cat > "$SYSTEMD_WEB" <<UNITEOF
[Unit]
Description=AI Analyzer Web — nginx frontend + proxy reverso
After=network-online.target ai-analyzer.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/podman start ${CONTAINER_WEB}
ExecStop=/usr/bin/podman stop -t 10 ${CONTAINER_WEB}
Restart=no
StandardOutput=append:${WEB_SERVICE_LOG}
StandardError=append:${WEB_SERVICE_LOG}

[Install]
WantedBy=multi-user.target
UNITEOF

    run_cmd systemctl daemon-reload
    run_cmd systemctl enable ai-analyzer-web.service
    log_ok "ai-analyzer-web.service habilitado (autostart)"
}

# ── Ejecutar despliegues ──────────────────────────────────────────────────────
if ! $SKIP_BACKEND; then
    if [[ "$BACKEND" == "java" ]]; then
        _BACKEND_IMAGE="$IMAGE_JAVA"
        _BUILD_MODE=$( $BUILD_LOCAL && echo "local" || echo "pull" )
    else
        _BACKEND_IMAGE="$IMAGE_PYTHON"
        _BUILD_MODE="pull"
    fi
    _deploy_backend "$_BACKEND_IMAGE" "$_BUILD_MODE"
fi

if ! $SKIP_WEB; then
    _deploy_web "$IMAGE_WEB"
fi

# ── 8. Verificar endpoints ────────────────────────────────────────────────────
_verify_endpoints() {
    log_info "Esperando que los servicios arranquen..."
    local wait=0
    until curl -sf "http://127.0.0.1:5000/health" >/dev/null 2>&1; do
        sleep 3; wait=$((wait + 3))
        if [[ $wait -ge 60 ]]; then
            log_warn "Health check lento (>60s) — mostrando logs del backend:"
            podman logs --tail=20 "$CONTAINER_BACKEND" 2>/dev/null || true
            die "Backend no respondió en 60s en :5000"
        fi
    done
    log_ok "Backend responde en :5000 (${wait}s)"

    # Endpoints del backend
    for ep in /health /api/stats /api/whitelist; do
        code="$(curl -s -o /dev/null -w '%{http_code}' \
            --connect-timeout 5 --max-time 10 \
            "http://127.0.0.1:5000${ep}" 2>/dev/null || echo 000)"
        case "$code" in
            200) log_ok "backend${ep}  HTTP ${code}" ;;
            *)   log_warn "backend${ep}  HTTP ${code} (inesperado)" ;;
        esac
    done

    # Frontend via nginx si está desplegado
    if ! $SKIP_WEB; then
        local web_wait=0
        until curl -sf "http://127.0.0.1/nginx-health" >/dev/null 2>&1; do
            sleep 2; web_wait=$((web_wait + 2))
            [[ $web_wait -ge 30 ]] && { log_warn "nginx no respondió en 30s"; break; }
        done
        if curl -sf "http://127.0.0.1/nginx-health" >/dev/null 2>&1; then
            log_ok "nginx responde en :80 (${web_wait}s)"
            # Verificar proxy al backend
            code="$(curl -s -o /dev/null -w '%{http_code}' \
                --connect-timeout 5 --max-time 10 \
                "http://127.0.0.1/health" 2>/dev/null || echo 000)"
            [[ "$code" == "200" ]] \
                && log_ok "nginx → backend /health  HTTP ${code}" \
                || log_warn "nginx → backend /health  HTTP ${code}"
        fi
    fi

    # Verificar Groq si está configurado
    if [[ -n "${GROQ_API_KEY:-}" ]]; then
        local groq_status
        groq_status="$(curl -sf "http://127.0.0.1:5000/health" 2>/dev/null \
            | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('groq_enabled','?'))" \
            2>/dev/null || echo '?')"
        [[ "$groq_status" == "True" || "$groq_status" == "true" ]] \
            && log_ok "Groq habilitado (modelo: ${GROQ_MODEL_VAL})" \
            || log_warn "Groq no reportado como habilitado — revisa $ENV_FILE"
    fi
}

_verify_endpoints

# ── Resumen final ─────────────────────────────────────────────────────────────
printf "\n"
log_ok "setup-raspi4b-containers completado"
printf "\n"

if ! $SKIP_WEB; then
    printf "  Frontend (nginx):\n"
    printf "    http://%s/dashboard\n"  "$PI_IP"
    printf "    http://%s/chat\n"       "$PI_IP"
    printf "\n"
fi

if ! $SKIP_BACKEND; then
    printf "  Backend directo:\n"
    printf "    http://%s:5000/health\n"  "$PI_IP"
    printf "    http://%s:5000/api/stats\n" "$PI_IP"
    printf "\n"
fi

printf "  Gestión de contenedores:\n"
! $SKIP_BACKEND && printf "    podman logs -f %s\n"    "$CONTAINER_BACKEND"
! $SKIP_BACKEND && printf "    podman restart %s\n"    "$CONTAINER_BACKEND"
! $SKIP_WEB     && printf "    podman logs -f %s\n"    "$CONTAINER_WEB"
! $SKIP_WEB     && printf "    podman restart %s\n"    "$CONTAINER_WEB"
printf "\n"
printf "  Logs en host:\n"
! $SKIP_BACKEND && printf "    %s\n" "$BACKEND_CONTAINER_LOG"
! $SKIP_BACKEND && printf "    %s\n" "$BACKEND_SERVICE_LOG"
! $SKIP_WEB     && printf "    %s\n" "$WEB_CONTAINER_LOG"
! $SKIP_WEB     && printf "    %s\n" "$WEB_SERVICE_LOG"
printf "\n"
printf "  Imágenes desplegadas:\n"
! $SKIP_BACKEND && printf "    podman images | grep poc-ai-analyzer\n"
printf "\n"
printf "  Releases disponibles:\n"
printf "    https://github.com/%s/presentaciones-cursos-talleres/releases\n" "$GHCR_USER"
printf "\n"
