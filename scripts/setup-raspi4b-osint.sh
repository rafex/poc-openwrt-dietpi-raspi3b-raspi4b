#!/bin/bash
# setup-raspi4b-osint.sh — Instala y configura el OSINT enricher en la Raspi4B
#
# Instala PHOMBER + dependencias, copia osint_enricher.py a /opt/osint/
# y configura el servicio systemd que corre junto al ai-analyzer.
#
# Uso:
#   sudo bash scripts/setup-raspi4b-osint.sh
#   sudo bash scripts/setup-raspi4b-osint.sh --dry-run
#   sudo bash scripts/setup-raspi4b-osint.sh --only-verify
#   sudo bash scripts/setup-raspi4b-osint.sh --bing-key sk_live_xxx
#   sudo bash scripts/setup-raspi4b-osint.sh --min-severity critical

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/raspi4b-common.sh"

# ── Defaults ──────────────────────────────────────────────────────────────────
INSTALL_DIR="/opt/osint"
DB_PATH="${DB_PATH:-/data/sensor.db}"
LLAMA_URL="${LLAMA_URL:-http://127.0.0.1:8081}"
MIN_SEVERITY="${MIN_SEVERITY:-high}"
POLL_INTERVAL="${POLL_INTERVAL:-30}"
BING_KEY=""
SOURCE_DIR="$(dirname "$SCRIPT_DIR")/backend/osint"

# ── Parseo de args ────────────────────────────────────────────────────────────
parse_common_flags "$@"
ARGS=("${REM_ARGS[@]}")
for arg in "${ARGS[@]}"; do
    case "$arg" in
        --bing-key=*)      BING_KEY="${arg#--bing-key=}" ;;
        --min-severity=*)  MIN_SEVERITY="${arg#--min-severity=}" ;;
        --poll=*)          POLL_INTERVAL="${arg#--poll=}" ;;
        --db-path=*)       DB_PATH="${arg#--db-path=}" ;;
    esac
done

need_root

log_info "─── OSINT Enricher setup ─────────────────────────────────────────────"
log_info "  install-dir : $INSTALL_DIR"
log_info "  db-path     : $DB_PATH"
log_info "  llama-url   : $LLAMA_URL"
log_info "  min-severity: $MIN_SEVERITY"
log_info "  bing-key    : ${BING_KEY:+configurado}${BING_KEY:-no configurado}"

# ── Dependencias Python ───────────────────────────────────────────────────────
log_info "─── Instalando dependencias Python ───────────────────────────────────"

apt_install_pkgs python3 python3-pip python3-venv

# Instalar phomber y requests globalmente (Pi 4B, no necesita venv)
run_cmd pip3 install --break-system-packages phomber requests 2>/dev/null || \
run_cmd pip3 install phomber requests

log_ok "phomber instalado"

# Verificar que phomber está disponible
if command -v phomber &>/dev/null; then
    log_ok "phomber encontrado en PATH: $(command -v phomber)"
else
    log_warn "phomber no está en PATH — puede requerir 'export PATH=\$PATH:\$HOME/.local/bin'"
fi

# Actualizar base de datos OUI de mac-vendor-lookup (solo una vez)
log_info "Actualizando base de datos OUI (MAC vendors)..."
run_cmd python3 -c "
from mac_vendor_lookup import MacLookup
import asyncio
async def update():
    m = MacLookup()
    await m.update_vendors()
asyncio.run(update())
" 2>/dev/null || log_warn "No se pudo actualizar OUI (sin internet o error — continuando)"

# ── Copiar archivos ───────────────────────────────────────────────────────────
log_info "─── Instalando en $INSTALL_DIR ───────────────────────────────────────"

run_cmd mkdir -p "$INSTALL_DIR"
run_cmd cp "$SOURCE_DIR/osint_enricher.py" "$INSTALL_DIR/osint_enricher.py"
run_cmd chmod 755 "$INSTALL_DIR/osint_enricher.py"

log_ok "osint_enricher.py instalado"

# ── Configurar env ────────────────────────────────────────────────────────────
if ! $ONLY_VERIFY; then
    ENV_FILE="/etc/osint-enricher.env"
    log_info "Escribiendo $ENV_FILE"
    run_cmd bash -c "cat > $ENV_FILE << 'ENVEOF'
DB_PATH=$DB_PATH
LLAMA_URL=$LLAMA_URL
MIN_SEVERITY=$MIN_SEVERITY
POLL_INTERVAL=$POLL_INTERVAL
PHOMBER_TIMEOUT=25
LLM_TIMEOUT=60
${BING_KEY:+BING_API_KEY=$BING_KEY}
ENVEOF"
    run_cmd chmod 600 "$ENV_FILE"
    log_ok "$ENV_FILE configurado"
fi

# ── Servicio systemd ──────────────────────────────────────────────────────────
log_info "─── Configurando servicio systemd ────────────────────────────────────"

SERVICE_FILE="/etc/systemd/system/osint-enricher.service"
run_cmd bash -c "cat > $SERVICE_FILE << 'SVCEOF'
[Unit]
Description=OSINT Enricher — sidecar PHOMBER+LLM para ai-analyzer
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=-/etc/ai-analyzer.env
EnvironmentFile=-/etc/osint-enricher.env
ExecStart=/usr/bin/python3 $INSTALL_DIR/osint_enricher.py
Restart=on-failure
RestartSec=15s
StandardOutput=journal
StandardError=journal
SyslogIdentifier=osint-enricher
MemoryMax=256M
CPUQuota=25%

[Install]
WantedBy=multi-user.target
SVCEOF"

if ! $DRY_RUN; then
    systemctl daemon-reload
    systemctl enable osint-enricher.service
    systemctl restart osint-enricher.service
    sleep 3
fi

log_ok "Servicio osint-enricher configurado"

# ── Verificación ──────────────────────────────────────────────────────────────
log_info "─── Verificación ─────────────────────────────────────────────────────"

if ! $DRY_RUN; then
    if systemctl is-active --quiet osint-enricher.service; then
        log_ok "osint-enricher.service ACTIVO"
    else
        log_warn "osint-enricher.service no está activo"
        log_info "Logs: journalctl -u osint-enricher -n 20"
    fi

    if command -v phomber &>/dev/null; then
        log_ok "phomber disponible"
    else
        log_warn "phomber no encontrado en PATH"
        log_warn "Agrega a PATH: export PATH=\$PATH:\$(python3 -m site --user-base)/bin"
    fi

    # Verificar tabla en SQLite
    if [[ -f "$DB_PATH" ]]; then
        TABLES=$(sqlite3 "$DB_PATH" ".tables" 2>/dev/null || echo "")
        if echo "$TABLES" | grep -q "osint_enrichments"; then
            log_ok "Tabla osint_enrichments creada en $DB_PATH"
        else
            log_info "Tabla osint_enrichments aún no creada (se crea al primer arranque)"
        fi
    else
        log_warn "DB no encontrada en $DB_PATH (normal si ai-analyzer aún no inició)"
    fi
fi

printf "\n"
log_ok "OSINT Enricher instalado"
printf "\n"
printf "  Para ver logs en tiempo real:\n"
printf "    journalctl -u osint-enricher -f\n"
printf "\n"
printf "  Para probar manualmente:\n"
printf "    DB_PATH=%s python3 %s/osint_enricher.py\n" "$DB_PATH" "$INSTALL_DIR"
printf "\n"
printf "  Para activar Bing dorks (opcional):\n"
printf "    echo 'BING_API_KEY=tu_clave' >> /etc/osint-enricher.env\n"
printf "    systemctl restart osint-enricher\n"
printf "\n"
printf "  Para ver resultados OSINT en SQLite:\n"
printf "    sqlite3 %s 'SELECT target, risk, summary_es, queried_at FROM osint_enrichments ORDER BY id DESC LIMIT 10;'\n" "$DB_PATH"
printf "\n"
