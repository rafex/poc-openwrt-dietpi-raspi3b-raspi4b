#!/bin/bash
# setup-raspi4b-ai-analyzer-java.sh — Despliega ai-analyzer (Java nativo + Rust .so)
#
# Descarga los binarios precompilados para arm64 desde GitHub Releases y
# los instala directamente en la Pi4B (sin podman, sin k3s, sin JVM).
#
# Artefactos que descarga:
#   ai-analyzer-linux-arm64         → binario GraalVM nativo
#   libanalyzer_db-linux-arm64.so   → wrapper SQLite Rust (bundled)
#
# Qué hace:
#   1. Instala age + sops si no están (para descifrar secretos)
#   2. Descifra secrets/raspi4b.yaml → GROQ_API_KEY en memoria
#   3. Descarga los binarios del último GitHub Release (o --release=vXXX)
#   4. Instala en /opt/ai-analyzer/{bin,lib}
#   5. Escribe /etc/ai-analyzer.env  (chmod 600)
#   6. Instala servicio systemd (Type=simple, reinicio automático)
#   7. Verifica /health
#
# Ventajas sobre el modo podman/Python:
#   - Sin JVM, sin Python, sin contenedor — 1 proceso nativo ~80MB RAM
#   - Arranque <100ms (GraalVM native image)
#   - SQLite via Rust (.so bundled, sin dependencias del sistema)
#
# Uso:
#   bash scripts/setup-raspi4b-ai-analyzer-java.sh
#   bash scripts/setup-raspi4b-ai-analyzer-java.sh --release=v20250425-abc1234
#   bash scripts/setup-raspi4b-ai-analyzer-java.sh --only-verify
#   bash scripts/setup-raspi4b-ai-analyzer-java.sh --dry-run

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=./lib/raspi4b-common.sh
. "$SCRIPT_DIR/lib/raspi4b-common.sh"
# shellcheck source=./lib/topology-common.sh
. "$SCRIPT_DIR/lib/topology-common.sh"
# shellcheck source=./lib/raspi4b-deps.sh
. "$SCRIPT_DIR/lib/raspi4b-deps.sh"

# ─── Flags extra (además de los comunes) ─────────────────────────────────────
RELEASE_TAG="latest"

_parse_extra_flags() {
    local -a extra=()
    for arg in "$@"; do
        case "$arg" in
            --release=*) RELEASE_TAG="${arg#--release=}" ;;
            *) extra+=("$arg") ;;
        esac
    done
    # Pasar el resto a parse_common_flags
    parse_common_flags "${extra[@]+"${extra[@]}"}"
}
_parse_extra_flags "$@"

init_log_dir "ai-analyzer-java"
need_root

log_info "--- setup-raspi4b-ai-analyzer-java (binario nativo) ---"
ensure_cmd bash curl systemctl
load_topology

# ─── Variables ────────────────────────────────────────────────────────────────
INSTALL_DIR="/opt/ai-analyzer"
BIN_DIR="${INSTALL_DIR}/bin"
LIB_DIR="${INSTALL_DIR}/lib"
HTML_DIR="${INSTALL_DIR}/html"
DATA_DIR="/opt/analyzer/data"
KEYS_DIR="/opt/keys"
ENV_FILE="/etc/ai-analyzer.env"
SYSTEMD_UNIT="/etc/systemd/system/ai-analyzer.service"
PI_IP="${AI_IP:-${RASPI4B_IP:-192.168.1.167}}"

GITHUB_REPO="rafex/presentaciones-cursos-talleres"  # ajustar si es diferente
BIN_NAME="ai-analyzer-linux-arm64"
LIB_NAME="libanalyzer_db-linux-arm64.so"

# ─── Instalar age + sops si no están (via lib/raspi4b-deps.sh) ───────────────
install_raspi4b_age_sops
command -v age  &>/dev/null || die "age no pudo instalarse"
command -v sops &>/dev/null || die "sops no pudo instalarse"

# ─── Descifrar secretos ───────────────────────────────────────────────────────
SECRETS_FILE="$REPO_DIR/secrets/raspi4b.yaml"
AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-/root/.config/sops/age/keys.txt}"
GROQ_API_KEY=""
GROQ_MODEL_VAL="qwen/qwen3-32b"

if [[ -f "$SECRETS_FILE" && -f "$AGE_KEY_FILE" ]]; then
    log_info "Descifrando secretos con sops+age..."
    _STMP=$(mktemp /dev/shm/sops-XXXXXX 2>/dev/null || mktemp)
    chmod 600 "$_STMP"
    trap "rm -f '$_STMP'" EXIT

    if SOPS_AGE_KEY_FILE="$AGE_KEY_FILE" \
       sops -d --output-type dotenv "$SECRETS_FILE" > "$_STMP" 2>/dev/null; then
        GROQ_API_KEY="$(grep '^GROQ_API_KEY=' "$_STMP" | head -1 | cut -d= -f2- | tr -d '"' || echo '')"
        GROQ_MODEL_VAL="$(grep '^GROQ_MODEL=' "$_STMP" | head -1 | cut -d= -f2- | tr -d '"' || echo 'qwen/qwen3-32b')"
        rm -f "$_STMP"; trap - EXIT
        [[ -n "$GROQ_API_KEY" ]] && log_ok "GROQ_API_KEY: ${#GROQ_API_KEY} chars" \
                                   || log_info "GROQ_API_KEY vacío — solo llama.cpp"
    else
        rm -f "$_STMP"; trap - EXIT
        log_warn "sops no pudo descifrar — desplegando sin Groq"
    fi
elif [[ ! -f "$SECRETS_FILE" ]]; then
    log_info "secrets/raspi4b.yaml no encontrado — sin Groq"
elif [[ ! -f "$AGE_KEY_FILE" ]]; then
    log_warn "Clave age no encontrada: $AGE_KEY_FILE"
    log_warn "Ejecuta: bash scripts/secrets-push-key.sh"
fi

if $ONLY_VERIFY; then
    log_info "Modo --only-verify: saltando instalación"
else
    # ─── Crear directorios ───────────────────────────────────────────────────
    run_cmd mkdir -p "$BIN_DIR" "$LIB_DIR" "$HTML_DIR" "$DATA_DIR" "$KEYS_DIR"
    log_ok "Directorios creados"

    # ─── Descargar binarios desde GitHub Releases ────────────────────────────
    log_info "Descargando binarios (tag: ${RELEASE_TAG})..."

    _gh_release_url() {
        local repo="$1" tag="$2" asset="$3"
        if [[ "$tag" == "latest" ]]; then
            echo "https://github.com/${repo}/releases/latest/download/${asset}"
        else
            echo "https://github.com/${repo}/releases/download/${tag}/${asset}"
        fi
    }

    BIN_URL="$(_gh_release_url "$GITHUB_REPO" "$RELEASE_TAG" "$BIN_NAME")"
    LIB_URL="$(_gh_release_url "$GITHUB_REPO" "$RELEASE_TAG" "$LIB_NAME")"

    log_info "Binario: $BIN_URL"
    log_info "Librería: $LIB_URL"

    if ! $DRY_RUN; then
        run_cmd curl -fsSL "$BIN_URL" -o "${BIN_DIR}/ai-analyzer"
        run_cmd chmod +x "${BIN_DIR}/ai-analyzer"
        run_cmd curl -fsSL "$LIB_URL" -o "${LIB_DIR}/libanalyzer_db.so"
        log_ok "Binarios descargados en $INSTALL_DIR"
        # Nota: los HTMLs (dashboard, chat, terminal, rulez, reports) los sirve
        # el frontend Node.js/Vite compilado — no se copian aquí.
    else
        log_info "[dry-run] descargar binarios"
    fi

    # ─── Escribir /etc/ai-analyzer.env ──────────────────────────────────────
    log_info "Escribiendo $ENV_FILE ..."

    _MQTT_HOST="${RASPI4B_IP:-192.168.1.167}"
    _ROUTER_IP="${ROUTER_IP:-192.168.1.1}"
    _PORTAL_IP="${PORTAL_IP:-192.168.1.167}"
    _RASPI3B_IP="${RASPI3B_IP:-192.168.1.181}"
    _PORTAL_NODE_IP="${PORTAL_NODE_IP:-192.168.1.182}"
    _AP_EXT_IP="${AP_EXTENDER_IP:-192.168.1.183}"
    _ADMIN_IP="${ADMIN_IP:-192.168.1.113}"

    if ! $DRY_RUN; then
        cat > "$ENV_FILE" <<ENVEOF
# /etc/ai-analyzer.env — Generado por setup-raspi4b-ai-analyzer-java.sh
# $(date '+%Y-%m-%d %H:%M:%S')  |  Permisos: 600

MQTT_HOST=${_MQTT_HOST}
MQTT_PORT=1883
MQTT_TOPIC=rafexpi/sensor/batch

DB_PATH=/opt/analyzer/data/sensor.db

LLAMA_URL=http://${_MQTT_HOST}:8081
MODEL_FORMAT=tinyllama
N_PREDICT=256

GROQ_API_KEY=${GROQ_API_KEY}
GROQ_MODEL=${GROQ_MODEL_VAL}
GROQ_MAX_TOKENS=1024

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

SOCIAL_BLOCK_ENABLED=true
SOCIAL_POLICY_START_HOUR=9
SOCIAL_POLICY_END_HOUR=17
SOCIAL_POLICY_TZ=America/Mexico_City
SOCIAL_MIN_HITS=3
PORN_BLOCK_ENABLED=true

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

LOG_LEVEL=INFO
SUMMARY_INTERVAL_S=60
ENVEOF
        chmod 600 "$ENV_FILE"
        log_ok "$ENV_FILE escrito (chmod 600)"
    else
        log_info "[dry-run] escribir $ENV_FILE"
    fi

    # ─── Parar servicio anterior ─────────────────────────────────────────────
    if systemctl is-active --quiet ai-analyzer.service 2>/dev/null; then
        log_info "Parando servicio anterior..."
        run_cmd systemctl stop ai-analyzer.service
    fi

    # ─── Instalar servicio systemd ───────────────────────────────────────────
    log_info "Instalando $SYSTEMD_UNIT ..."
    if ! $DRY_RUN; then
        cat > "$SYSTEMD_UNIT" <<UNITEOF
[Unit]
Description=AI Analyzer — Red WiFi con IA (Java nativo + Rust SQLite)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${HTML_DIR}
EnvironmentFile=${ENV_FILE}
Environment=LD_LIBRARY_PATH=${LIB_DIR}
Environment=ANALYZER_DB_LIB=${LIB_DIR}/libanalyzer_db.so
ExecStart=${BIN_DIR}/ai-analyzer
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=ai-analyzer

# Limitar memoria (GraalVM nativo ~80MB base)
MemoryMax=300M
MemorySwapMax=0

[Install]
WantedBy=multi-user.target
UNITEOF
    else
        log_info "[dry-run] escribir $SYSTEMD_UNIT"
    fi

    run_cmd systemctl daemon-reload
    run_cmd systemctl enable ai-analyzer.service
    run_cmd systemctl start  ai-analyzer.service
    log_ok "ai-analyzer.service iniciado"
fi

# ─── Verificar endpoints ──────────────────────────────────────────────────────
if $DRY_RUN; then
    log_ok "Dry-run completado"
    exit 0
fi

log_info "Esperando que el servicio arranque..."
WAIT=0
until curl -sf "http://127.0.0.1:5000/health" >/dev/null 2>&1; do
    sleep 2; WAIT=$((WAIT + 2))
    [[ $WAIT -ge 30 ]] && {
        log_info "Health check lento — logs del servicio:"
        journalctl -u ai-analyzer --no-pager -n 20 2>/dev/null || true
        die "ai-analyzer no respondió en 30s en :5000"
    }
done
log_ok "ai-analyzer responde en :5000 (${WAIT}s)"

for ep in /health /dashboard /terminal /rulez /chat /reports; do
    code="$(curl -s -o /dev/null -w '%{http_code}' \
        --connect-timeout 5 --max-time 10 \
        "http://${PI_IP}:5000${ep}" 2>/dev/null || echo 000)"
    case "$code" in
        200|301|302) log_ok "${ep}  HTTP ${code}" ;;
        *)           log_warn "${ep}  HTTP ${code} (inesperado)" ;;
    esac
done

if [[ -n "${GROQ_API_KEY:-}" ]]; then
    GROQ_STATUS="$(curl -sf "http://127.0.0.1:5000/health" 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('groq_enabled','?'))" \
        2>/dev/null || echo '?')"
    [[ "$GROQ_STATUS" == "True" || "$GROQ_STATUS" == "true" ]] \
        && log_ok "Groq habilitado (${GROQ_MODEL_VAL})" \
        || log_warn "Groq no reportado como habilitado — revisa $ENV_FILE"
fi

printf "\n"
log_ok "setup-raspi4b-ai-analyzer-java completado"
printf "\n"
printf "  Binario nativo (GraalVM arm64):\n"
printf "    %s/ai-analyzer\n" "$BIN_DIR"
printf "    %s/libanalyzer_db.so\n" "$LIB_DIR"
printf "\n"
printf "  Acceso:\n"
printf "    http://%s:5000/dashboard\n" "$PI_IP"
printf "    http://%s:5000/chat\n"      "$PI_IP"
printf "    http://%s:5000/health\n"    "$PI_IP"
printf "\n"
printf "  Gestión:\n"
printf "    systemctl status ai-analyzer\n"
printf "    journalctl -u ai-analyzer -f\n"
printf "    systemctl restart ai-analyzer\n"
printf "\n"
