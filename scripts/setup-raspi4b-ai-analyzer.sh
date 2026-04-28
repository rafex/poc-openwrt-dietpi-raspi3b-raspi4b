#!/bin/bash
# setup-raspi4b-ai-analyzer.sh — Construye y despliega ai-analyzer con podman (sin k3s)
#
# Qué hace:
#   1. Instala age + sops si no están presentes
#   2. Descifra secrets/raspi4b.yaml con sops+age → extrae secretos en memoria
#   3. Construye la imagen con podman
#   4. Escribe /etc/ai-analyzer.env (chmod 600) con variables + secretos descifrados
#   5. Crea/recrea el contenedor podman con --restart=unless-stopped --network host
#   6. Instala un servicio systemd para autostart tras reboot
#   7. Verifica que los endpoints responden
#
# El contenedor usa --network host: expone el puerto 5000 directamente
# en la IP de la Raspi, sin necesidad de Traefik ni k3s.
#
# Secretos (GROQ_API_KEY, etc.) gestionados con age+sops:
#   Editar en admin:  bash scripts/secrets-edit.sh
#   Copiar key a Pi:  bash scripts/secrets-push-key.sh
#
# Uso:
#   bash scripts/setup-raspi4b-ai-analyzer.sh
#   bash scripts/setup-raspi4b-ai-analyzer.sh --no-build    # saltar build
#   bash scripts/setup-raspi4b-ai-analyzer.sh --only-verify # solo verificar endpoints
#   bash scripts/setup-raspi4b-ai-analyzer.sh --dry-run

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=./lib/raspi4b-common.sh
. "$SCRIPT_DIR/lib/raspi4b-common.sh"
# shellcheck source=./lib/topology-common.sh
. "$SCRIPT_DIR/lib/topology-common.sh"

parse_common_flags "$@"
init_log_dir "ai-analyzer"
need_root

[ "${#REM_ARGS[@]}" -eq 0 ] || die "Argumentos no soportados: ${REM_ARGS[*]}"

log_info "--- setup-raspi4b-ai-analyzer (podman) ---"
ensure_cmd bash curl podman
load_topology

# ─── Instalar age + sops si no están ─────────────────────────────────────────
_install_sops_tools() {
    local need_age=false need_sops=false
    command -v age  &>/dev/null || need_age=true
    command -v sops &>/dev/null || need_sops=true

    if ! $need_age && ! $need_sops; then
        return 0
    fi

    log_info "Instalando herramientas de secretos (age/sops)..."
    apt_update_once

    $need_age  && run_cmd apt-get install -y -q age
    if $need_sops; then
        if apt-cache show sops &>/dev/null 2>&1; then
            run_cmd apt-get install -y -q sops
        else
            # Descargar binario oficial (arm64 para Raspi4)
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

# ─── Descifrar secretos con sops+age ─────────────────────────────────────────
SECRETS_FILE="$REPO_DIR/secrets/raspi4b.yaml"
AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-/root/.config/sops/age/keys.txt}"
GROQ_API_KEY=""
GROQ_MODEL_VAL="qwen/qwen3-32b"

if [[ -f "$SECRETS_FILE" ]]; then
    if [[ ! -f "$AGE_KEY_FILE" ]]; then
        log_warn "Clave age no encontrada: $AGE_KEY_FILE"
        log_warn "Ejecuta en el admin: bash scripts/secrets-push-key.sh"
        log_warn "Desplegando sin secretos (Groq deshabilitado)"
    else
        log_info "Descifrando secretos con sops+age..."
        # Descifrar a archivo temporal en memoria (tmpfs en Linux)
        _STMP=$(mktemp /dev/shm/sops-XXXXXX 2>/dev/null || mktemp)
        chmod 600 "$_STMP"
        trap "rm -f '$_STMP'" EXIT

        if SOPS_AGE_KEY_FILE="$AGE_KEY_FILE" \
           sops -d --output-type dotenv "$SECRETS_FILE" > "$_STMP" 2>/dev/null; then
            # Leer valores específicos sin hacer eval del archivo completo
            GROQ_API_KEY="$(grep '^GROQ_API_KEY=' "$_STMP" | head -1 | cut -d= -f2- | tr -d '"' || echo '')"
            GROQ_MODEL_VAL="$(grep '^GROQ_MODEL=' "$_STMP" | head -1 | cut -d= -f2- | tr -d '"' || echo 'qwen/qwen3-32b')"
            rm -f "$_STMP"
            trap - EXIT

            if [[ -n "$GROQ_API_KEY" ]]; then
                log_ok "Secretos descifrados — GROQ_API_KEY: ${#GROQ_API_KEY} chars"
            else
                log_info "Secretos descifrados — GROQ_API_KEY vacío (Groq deshabilitado)"
            fi
        else
            rm -f "$_STMP"
            trap - EXIT
            log_warn "sops no pudo descifrar $SECRETS_FILE — desplegando sin Groq"
            log_warn "Verifica: SOPS_AGE_KEY_FILE=$AGE_KEY_FILE sops -d $SECRETS_FILE"
        fi
    fi
else
    log_info "secrets/raspi4b.yaml no encontrado — desplegando sin Groq"
    log_info "Para habilitar Groq: bash scripts/secrets-init.sh  (en el admin)"
fi

# ─── Configuración ────────────────────────────────────────────────────────────
CONTAINER_NAME="ai-analyzer"
IMAGE_NAME="localhost/ai-analyzer:latest"
DATA_DIR="/opt/analyzer/data"
KEYS_DIR="/opt/keys"
ENV_FILE="/etc/ai-analyzer.env"
SYSTEMD_UNIT="/etc/systemd/system/ai-analyzer.service"
PI_IP="${AI_IP:-${RASPI4B_IP:-192.168.1.167}}"

# ─── PASO 1: Construir imagen ─────────────────────────────────────────────────
if ! $ONLY_VERIFY; then
  if ! $NO_BUILD; then
    log_info "Construyendo imagen $IMAGE_NAME ..."
    run_cmd podman build \
        --cgroup-manager=cgroupfs \
        --platform linux/arm64 \
        -t "$IMAGE_NAME" \
        "$REPO_DIR/backend/ai-analyzer/"
    log_ok "Imagen construida: $IMAGE_NAME"
  else
    log_info "Saltando build (--no-build)"
    podman image exists "$IMAGE_NAME" || die "Imagen $IMAGE_NAME no existe — elimina --no-build"
  fi

  # ─── PASO 2: Escribir /etc/ai-analyzer.env ────────────────────────────────
  log_info "Escribiendo $ENV_FILE ..."

  # GROQ_API_KEY y GROQ_MODEL_VAL ya fueron extraídos del bloque sops arriba
  GROQ_KEY_VAL="${GROQ_API_KEY:-}"

  if [ -n "$GROQ_KEY_VAL" ]; then
    log_ok "GROQ_API_KEY presente (${#GROQ_KEY_VAL} chars) — Groq habilitado"
  else
    log_info "GROQ_API_KEY vacío — modo llama.cpp local (fallback)"
  fi

  if ! $DRY_RUN; then
    # Leer IPs desde topology si está disponible
    _MQTT_HOST="${RASPI4B_IP:-192.168.1.167}"
    _ROUTER_IP="${ROUTER_IP:-192.168.1.1}"
    _PORTAL_IP="${PORTAL_IP:-192.168.1.167}"
    _RASPI3B_IP="${RASPI3B_IP:-192.168.1.181}"
    _PORTAL_NODE_IP="${PORTAL_NODE_IP:-192.168.1.182}"
    _AP_EXT_IP="${AP_EXTENDER_IP:-192.168.1.183}"
    _ADMIN_IP="${ADMIN_IP:-192.168.1.113}"

    cat > "$ENV_FILE" <<ENVEOF
# /etc/ai-analyzer.env — Variables de entorno para el contenedor ai-analyzer
# Generado por setup-raspi4b-ai-analyzer.sh el $(date '+%Y-%m-%d %H:%M:%S')
# Permisos: 600 (solo root puede leer GROQ_API_KEY)

# ── MQTT ──────────────────────────────────────────────────────────────────────
MQTT_HOST=${_MQTT_HOST}
MQTT_PORT=1883
MQTT_TOPIC=rafexpi/sensor/batch

# ── Base de datos ─────────────────────────────────────────────────────────────
DB_PATH=/data/sensor.db

# ── llama.cpp (fallback local) ────────────────────────────────────────────────
LLAMA_URL=http://${_MQTT_HOST}:8081
MODEL_FORMAT=tinyllama
N_PREDICT=256

# ── Groq API ──────────────────────────────────────────────────────────────────
GROQ_API_KEY=${GROQ_KEY_VAL}
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

    # GROQ_API_KEY no debe ser legible por otros usuarios
    chmod 600 "$ENV_FILE"
    log_ok "$ENV_FILE escrito (chmod 600)"
  else
    log_info "[dry-run] escribir $ENV_FILE"
  fi

  # ─── PASO 3: Preparar directorio de datos y llaves ─────────────────────────
  run_cmd mkdir -p "$DATA_DIR"
  run_cmd mkdir -p "$KEYS_DIR"
  log_ok "Directorios: $DATA_DIR  $KEYS_DIR"

  # ─── PASO 4: Parar y eliminar contenedor anterior ─────────────────────────
  if podman container exists "$CONTAINER_NAME" 2>/dev/null; then
    log_info "Parando contenedor anterior: $CONTAINER_NAME"
    run_cmd podman stop -t 10 "$CONTAINER_NAME" 2>/dev/null || true
    run_cmd podman rm -f "$CONTAINER_NAME" 2>/dev/null || true
    log_ok "Contenedor anterior eliminado"
  fi

  # ─── PASO 5: Crear contenedor ─────────────────────────────────────────────
  log_info "Creando contenedor $CONTAINER_NAME ..."
  run_cmd podman create \
      --name "$CONTAINER_NAME" \
      --restart unless-stopped \
      --network host \
      --env-file "$ENV_FILE" \
      -v "${DATA_DIR}:/data:z" \
      -v "${KEYS_DIR}:/opt/keys:ro,z" \
      "$IMAGE_NAME"

  run_cmd podman start "$CONTAINER_NAME"
  log_ok "Contenedor $CONTAINER_NAME iniciado"

  # ─── PASO 6: Servicio systemd para autostart ──────────────────────────────
  log_info "Instalando servicio systemd $SYSTEMD_UNIT ..."
  if ! $DRY_RUN; then
    cat > "$SYSTEMD_UNIT" <<UNITEOF
[Unit]
Description=AI Analyzer — sensor de red WiFi con IA
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
UNITEOF
  else
    log_info "[dry-run] escribir $SYSTEMD_UNIT"
  fi

  run_cmd systemctl daemon-reload
  run_cmd systemctl enable ai-analyzer.service
  log_ok "ai-analyzer.service habilitado (autostart en reboot)"
fi

# ─── PASO 7: Verificar endpoints ──────────────────────────────────────────────
if $DRY_RUN; then
    log_ok "Dry-run completado"
    exit 0
fi

log_info "Esperando que el contenedor arranque..."
WAIT=0
until curl -sf "http://127.0.0.1:5000/health" >/dev/null 2>&1; do
    sleep 3; WAIT=$((WAIT + 3))
    [[ $WAIT -ge 60 ]] && {
        log_info "Health check lento — revisando logs:"
        podman logs --tail=20 "$CONTAINER_NAME" 2>/dev/null || true
        die "ai-analyzer no respondió en 60s en :5000"
    }
done
log_ok "ai-analyzer responde en :5000 (${WAIT}s)"

# Verificar endpoints principales
for ep in /health /dashboard /terminal /rulez /chat /reports; do
    code="$(curl -s -o /dev/null -w '%{http_code}' \
        --connect-timeout 5 --max-time 10 \
        "http://${PI_IP}:5000${ep}" 2>/dev/null || echo 000)"
    case "$code" in
        200|301|302) log_ok "${ep}  HTTP ${code}" ;;
        *)           log_warn "${ep}  HTTP ${code} (inesperado)" ;;
    esac
done

# Verificar que Groq está configurado si se pasó la clave
if [ -n "${GROQ_API_KEY:-}" ]; then
    GROQ_ENABLED="$(curl -sf "http://127.0.0.1:5000/health" 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('groq_enabled','?'))" \
        2>/dev/null || echo '?')"
    if [[ "$GROQ_ENABLED" == "True" ]] || [[ "$GROQ_ENABLED" == "true" ]]; then
        log_ok "Groq habilitado (modelo: ${GROQ_MODEL:-qwen/qwen3-32b})"
    else
        log_warn "Groq no reportado como habilitado — revisa GROQ_API_KEY en $ENV_FILE"
    fi
fi

printf "\n"
log_ok "setup-raspi4b-ai-analyzer completado"
printf "\n"
printf "  Acceso directo (sin Traefik):\n"
printf "    http://%s:5000/dashboard\n" "$PI_IP"
printf "    http://%s:5000/chat\n"      "$PI_IP"
printf "    http://%s:5000/health\n"    "$PI_IP"
printf "\n"
printf "  Gestión del contenedor:\n"
printf "    podman logs -f %s\n"           "$CONTAINER_NAME"
printf "    podman restart %s\n"           "$CONTAINER_NAME"
printf "    systemctl status ai-analyzer\n"
printf "    cat %s\n"                       "$ENV_FILE"
printf "\n"
