#!/bin/bash
# secrets-push-key.sh — Copia la clave privada age a la Raspi 4B (una sola vez)
#
# La Pi4B necesita la clave privada age para descifrar secrets/raspi4b.yaml
# durante el deploy. Este script la copia de forma segura via SSH y la instala
# con los permisos correctos (chmod 600, solo root).
#
# Uso:
#   bash scripts/secrets-push-key.sh
#   bash scripts/secrets-push-key.sh --host 192.168.1.167
#   bash scripts/secrets-push-key.sh --host 192.168.1.167 --user dietpi
#
# Solo necesitas ejecutarlo una vez por Raspberry Pi.
# Si regeneras el keypair (secrets-init.sh --force), vuelve a ejecutarlo.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

hdr()  { printf "\n${BOLD}${CYAN}━━━ %s ━━━${NC}\n" "$*"; }
ok()   { printf "  ${GREEN}✓${NC} %s\n" "$*"; }
warn() { printf "  ${YELLOW}!${NC} %s\n" "$*"; }
info() { printf "  ${BLUE}·${NC} %s\n" "$*"; }
die()  { printf "${RED}ERROR${NC}: %s\n" "$*" >&2; exit 1; }

TARGET_HOST="${RASPI4B_IP:-192.168.1.167}"
TARGET_USER="root"
AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-${HOME}/.config/sops/age/keys.txt}"
REMOTE_KEY_DIR="/root/.config/sops/age"
REMOTE_KEY_FILE="${REMOTE_KEY_DIR}/keys.txt"

for arg in "$@"; do
    case "$arg" in
        --host=*) TARGET_HOST="${arg#--host=}" ;;
        --host)   shift; TARGET_HOST="${1:-}" ;;
        --user=*) TARGET_USER="${arg#--user=}" ;;
        --user)   shift; TARGET_USER="${1:-}" ;;
        --help|-h)
            sed -n '2,22p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *) die "Argumento desconocido: $arg" ;;
    esac
done

# ─── Cabecera ─────────────────────────────────────────────────────────────────
printf "\n${BOLD}╔══════════════════════════════════════════════════╗${NC}\n"
printf   "${BOLD}║  secrets-push-key (age → Pi4B)       %-11s║${NC}\n" "$(date '+%H:%M:%S')"
printf   "${BOLD}╚══════════════════════════════════════════════════╝${NC}\n"
printf "  Destino   : %s@%s\n" "$TARGET_USER" "$TARGET_HOST"
printf "  Key local : %s\n"    "$AGE_KEY_FILE"
printf "  Key remota: %s\n"    "$REMOTE_KEY_FILE"

# ─── Pre-checks ───────────────────────────────────────────────────────────────
hdr "Verificaciones previas"

[[ -f "$AGE_KEY_FILE" ]] || die "Clave privada age no encontrada: $AGE_KEY_FILE
  Ejecuta primero: bash scripts/secrets-init.sh"

# Extraer pubkey para mostrar
PUBKEY="$(grep '^# public key:' "$AGE_KEY_FILE" | head -1 | awk '{print $NF}' || echo 'n/a')"
ok "Clave local encontrada"
info "Clave pública: $PUBKEY"

# Verificar conectividad SSH
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -o BatchMode=yes -o ConnectTimeout=8 -o LogLevel=ERROR"

if ! ping -c1 -W3 "$TARGET_HOST" &>/dev/null; then
    die "Host $TARGET_HOST no responde a ping"
fi
ok "Ping a $TARGET_HOST OK"

# shellcheck disable=SC2086
if ! ssh $SSH_OPTS "${TARGET_USER}@${TARGET_HOST}" "echo pong" 2>/dev/null | grep -q pong; then
    die "SSH a ${TARGET_USER}@${TARGET_HOST} falló"
fi
ok "SSH OK"

# ─── Verificar si ya existe en destino ────────────────────────────────────────
hdr "Instalando clave en la Pi4B"

# shellcheck disable=SC2086
REMOTE_PUBKEY="$(ssh $SSH_OPTS "${TARGET_USER}@${TARGET_HOST}" \
    "grep '^# public key:' '$REMOTE_KEY_FILE' 2>/dev/null | awk '{print \$NF}' || echo ''" 2>/dev/null || echo "")"

if [[ -n "$REMOTE_PUBKEY" ]] && [[ "$REMOTE_PUBKEY" == "$PUBKEY" ]]; then
    ok "La clave ya está instalada en la Pi4B (misma pubkey)"
    info "Para forzar reinstalación borra $REMOTE_KEY_FILE en la Pi y vuelve a ejecutar"
    exit 0
elif [[ -n "$REMOTE_PUBKEY" ]]; then
    warn "Hay una clave diferente en la Pi — sobreescribiendo"
    info "Clave remota actual: $REMOTE_PUBKEY"
fi

# Copiar via SSH (pipe directo, sin escribir en disco temporal)
info "Copiando clave privada via SSH..."
# shellcheck disable=SC2086
ssh $SSH_OPTS "${TARGET_USER}@${TARGET_HOST}" "
    mkdir -p '$REMOTE_KEY_DIR'
    chmod 700 '$REMOTE_KEY_DIR'
    cat > '$REMOTE_KEY_FILE'
    chmod 600 '$REMOTE_KEY_FILE'
    echo OK
" < "$AGE_KEY_FILE" | grep -q OK || die "No se pudo copiar la clave a la Pi4B"

ok "Clave instalada en ${TARGET_HOST}:${REMOTE_KEY_FILE}"

# ─── Verificar descifrado remoto ──────────────────────────────────────────────
hdr "Verificando descifrado en la Pi4B"

# Comprobar que age y sops existen en la Pi
# shellcheck disable=SC2086
AGE_OK="$(ssh $SSH_OPTS "${TARGET_USER}@${TARGET_HOST}" \
    "command -v age 2>/dev/null && echo yes || echo no" 2>/dev/null || echo no)"
# shellcheck disable=SC2086
SOPS_OK="$(ssh $SSH_OPTS "${TARGET_USER}@${TARGET_HOST}" \
    "command -v sops 2>/dev/null && echo yes || echo no" 2>/dev/null || echo no)"

if [[ "$AGE_OK" != "yes" ]] || [[ "$SOPS_OK" != "yes" ]]; then
    warn "age o sops no están instalados en la Pi4B"
    warn "El setup script los instalará automáticamente al desplegar"
    info "O instálalos manualmente: apt install age  &&  bash scripts/secrets-init.sh (desde la Pi)"
else
    ok "age y sops disponibles en la Pi4B"
    # Intentar descifrar el archivo de secretos si el repo está en la Pi
    # shellcheck disable=SC2086
    REPO_ON_PI="$(ssh $SSH_OPTS "${TARGET_USER}@${TARGET_HOST}" \
        "ls /opt/repository/poc-openwrt-dietpi-raspi3b-raspi4b/secrets/raspi4b.yaml 2>/dev/null && echo yes || echo no" \
        2>/dev/null || echo no)"
    if [[ "$REPO_ON_PI" == "yes" ]]; then
        # shellcheck disable=SC2086
        DECRYPT_TEST="$(ssh $SSH_OPTS "${TARGET_USER}@${TARGET_HOST}" \
            "SOPS_AGE_KEY_FILE='$REMOTE_KEY_FILE' sops -d \
            /opt/repository/poc-openwrt-dietpi-raspi3b-raspi4b/secrets/raspi4b.yaml \
            >/dev/null 2>&1 && echo OK || echo FAIL" 2>/dev/null || echo FAIL)"
        if [[ "$DECRYPT_TEST" == "OK" ]]; then
            ok "Descifrado remoto verificado"
        else
            warn "Descifrado remoto falló — el repo puede no estar sincronizado aún"
        fi
    else
        info "Repo no encontrado en la Pi — sincroniza el repo y prueba el descifrado"
    fi
fi

# ─── Resumen ──────────────────────────────────────────────────────────────────
printf "\n${BOLD}${GREEN}✓ Clave age instalada en la Pi4B.${NC}\n\n"
printf "  La Pi puede descifrar secretos en cada deploy.\n"
printf "\n"
printf "  Próximo paso:\n"
printf "    bash scripts/setup-raspi4b-ai-analyzer.sh\n"
printf "\n"
printf "  Para verificar manualmente en la Pi:\n"
printf "    ssh root@%s 'SOPS_AGE_KEY_FILE=%s sops -d /ruta/repo/secrets/raspi4b.yaml'\n" \
    "$TARGET_HOST" "$REMOTE_KEY_FILE"
printf "\n"
