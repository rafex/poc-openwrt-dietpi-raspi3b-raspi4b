#!/bin/bash
# portal-reset-demo.sh — Limpia la BD del portal y resetea el estado para una nueva demo
#
# Qué hace:
#   1) Trunca las tablas "clientes" e "invitados" en la BD SQLite del portal
#   2) Elimina las IPs de invitados del set nftables allowed_clients en el router
#      (conserva IPs de infraestructura con timeout 0s)
#   3) Reinicia el contenedor backend para que empiece limpio
#
# Uso:
#   bash scripts/portal-reset-demo.sh              # interactivo (pide confirmación)
#   bash scripts/portal-reset-demo.sh --force      # sin confirmación
#   bash scripts/portal-reset-demo.sh --db-only    # solo limpiar BD
#   bash scripts/portal-reset-demo.sh --nft-only   # solo limpiar nftables
#   bash scripts/portal-reset-demo.sh --status     # mostrar estado actual sin borrar
#
# Ejecutar desde: máquina admin (192.168.1.113)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

# ─── Colores ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

hdr()  { printf "\n${BOLD}${CYAN}━━━ %s ━━━${NC}\n" "$*"; }
ok()   { printf "  ${GREEN}✓${NC} %s\n" "$*"; }
fail() { printf "  ${RED}✗${NC} %s\n" "$*" >&2; }
warn() { printf "  ${YELLOW}!${NC} %s\n" "$*"; }
info() { printf "  ${BLUE}·${NC} %s\n" "$*"; }
die()  { printf "${RED}ERROR${NC}: %s\n" "$*" >&2; exit 1; }

# ─── Argumentos ───────────────────────────────────────────────────────────────
FORCE=false
DB_RESET=true
NFT_RESET=true
STATUS_ONLY=false

for arg in "$@"; do
    case "$arg" in
        --force|-f)    FORCE=true ;;
        --db-only)     NFT_RESET=false ;;
        --nft-only)    DB_RESET=false ;;
        --no-nft)      NFT_RESET=false ;;
        --status|-s)   STATUS_ONLY=true ;;
        --help|-h)
            sed -n '2,20p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *) die "Argumento desconocido: $arg" ;;
    esac
done

# ─── Conexiones SSH ───────────────────────────────────────────────────────────
# Portal node (Pi3B-B): usa las llaves propias del admin (~/.ssh/)
PORTAL_SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                 -o BatchMode=yes -o ConnectTimeout=5 -o LogLevel=ERROR"
portal_ssh() { ssh $PORTAL_SSH_OPTS "root@${PORTAL_NODE_IP}" "$@" 2>/dev/null; }

# Router: usa la llave dedicada del captive portal
check_ssh_key
router_ok() { router_ssh "echo pong" 2>/dev/null | grep -q pong; }
portal_ok() { ssh $PORTAL_SSH_OPTS "root@${PORTAL_NODE_IP}" "echo pong" 2>/dev/null | grep -q pong; }

DB_HOST_PATH="/opt/captive-portal/lentium-data/lentium.db"
CONTAINER_BACKEND="captive-portal-node-backend"
CONTAINER_FRONTEND="captive-portal-node"

# ─── Cabecera ─────────────────────────────────────────────────────────────────
printf "\n${BOLD}╔══════════════════════════════════════════════════╗${NC}\n"
printf   "${BOLD}║  Portal Reset Demo                   %-11s║${NC}\n" "$(date '+%H:%M:%S')"
printf   "${BOLD}╚══════════════════════════════════════════════════╝${NC}\n"
printf "  Portal node: %s\n" "${PORTAL_NODE_IP}"
printf "  Router:      %s\n" "${ROUTER_IP}"
printf "  BD:          %s\n" "${DB_HOST_PATH}"
printf "  Acciones:    BD=%s  NFT=%s\n" "$DB_RESET" "$NFT_RESET"

# ─── Verificar conectividad ───────────────────────────────────────────────────
hdr "Verificando conectividad"

if ! ping -c1 -W2 "${PORTAL_NODE_IP}" &>/dev/null; then
    die "Portal node ${PORTAL_NODE_IP} no responde a ping"
fi
ok "Ping a portal node OK"

if ! portal_ok; then
    die "SSH a root@${PORTAL_NODE_IP} sin acceso — verifica ~/.ssh/ o ~/.ssh/config"
fi
ok "SSH a portal node OK"

if ! ping -c1 -W2 "${ROUTER_IP}" &>/dev/null; then
    warn "Router ${ROUTER_IP} no responde — reset de nftables no disponible"
    NFT_RESET=false
elif ! router_ok; then
    warn "SSH al router no disponible — reset de nftables no disponible"
    NFT_RESET=false
else
    ok "SSH al router OK"
fi

# ─── Modo status: solo mostrar estado sin borrar ───────────────────────────────
if $STATUS_ONLY; then
    hdr "Estado actual de la BD"
    portal_ssh "
        if [ -f '$DB_HOST_PATH' ]; then
            sqlite3 '$DB_HOST_PATH' '
                SELECT \"Clientes:  \" || COUNT(*) FROM clientes;
                SELECT \"Invitados: \" || COUNT(*) FROM invitados;
                SELECT \"-- Últimos 5 invitados --\";
                SELECT nombre || \" \" || apellido_paterno || \" | tel:\" || telefono || \" | ip:\" || COALESCE(ip,\"?\") || \" | \" || COALESCE(registrado_en,\"?\")
                FROM invitados ORDER BY id DESC LIMIT 5;
                SELECT \"-- Últimos 5 clientes --\";
                SELECT telefono || \" | ip:\" || COALESCE(ip,\"?\") || \" | \" || COALESCE(ultima_sesion,\"?\")
                FROM clientes ORDER BY id DESC LIMIT 5;
            '
        else
            echo 'BD no encontrada en $DB_HOST_PATH'
        fi
    " | sed 's/^/  /'

    hdr "Set nftables allowed_clients"
    router_ssh "nft list set ip captive allowed_clients 2>/dev/null || echo '(tabla no disponible)'" \
        | sed 's/^/  /'
    exit 0
fi

# ─── Confirmación ─────────────────────────────────────────────────────────────
if ! $FORCE; then
    printf "\n"
    printf "${YELLOW}${BOLD}⚠  ATENCIÓN — Esta operación borrará datos reales:${NC}\n"
    $DB_RESET  && printf "   • Todas las filas de 'clientes' e 'invitados' en la BD SQLite\n"
    $NFT_RESET && printf "   • IPs de invitados del set nftables (infraestructura se conserva)\n"
    printf "\n"
    printf "  Escribe ${BOLD}RESET${NC} para confirmar, cualquier otra cosa cancela: "
    read -r CONFIRM
    if [ "$CONFIRM" != "RESET" ]; then
        printf "\nCancelado.\n"
        exit 0
    fi
fi

# ─── PASO 1: Limpiar BD ───────────────────────────────────────────────────────
if $DB_RESET; then
    hdr "1. Limpiando base de datos"

    # Contar registros actuales antes de borrar
    COUNTS=$(portal_ssh "
        if [ -f '$DB_HOST_PATH' ]; then
            sqlite3 '$DB_HOST_PATH' 'SELECT COUNT(*) FROM clientes;'
            sqlite3 '$DB_HOST_PATH' 'SELECT COUNT(*) FROM invitados;'
        else
            echo 0; echo 0
        fi
    " 2>/dev/null || echo -e "0\n0")

    N_CLI=$(echo "$COUNTS" | head -1)
    N_INV=$(echo "$COUNTS" | tail -1)
    info "Registros actuales: clientes=${N_CLI}  invitados=${N_INV}"

    # Detener backend para evitar escrituras durante el truncado
    info "Deteniendo contenedor backend..."
    portal_ssh "podman stop -t 5 '$CONTAINER_BACKEND' 2>/dev/null || true" && \
        ok "Contenedor backend detenido" || warn "No se pudo detener el backend"

    # Truncar tablas y hacer VACUUM para liberar espacio
    portal_ssh "
        if [ -f '$DB_HOST_PATH' ]; then
            sqlite3 '$DB_HOST_PATH' '
                DELETE FROM clientes;
                DELETE FROM invitados;
                DELETE FROM sqlite_sequence WHERE name IN (\"clientes\",\"invitados\");
                VACUUM;
            '
            echo ok
        else
            echo 'no_db'
        fi
    " 2>/dev/null | grep -q "^ok$" && \
        ok "Tablas limpiadas (clientes=${N_CLI}, invitados=${N_INV} filas eliminadas)" || \
        warn "No se encontró la BD — se creará al reiniciar el backend"

    # Reiniciar backend
    info "Reiniciando contenedor backend..."
    portal_ssh "podman start '$CONTAINER_BACKEND' 2>/dev/null" && \
        ok "Contenedor backend reiniciado" || fail "No se pudo reiniciar el backend"

    # Esperar a que el backend esté listo (máximo 15s)
    info "Esperando que el backend esté listo..."
    WAITED=0
    while [ "$WAITED" -lt 15 ]; do
        HTTP_CODE=$(portal_ssh "curl -sS -o /dev/null -w '%{http_code}' \
            --connect-timeout 2 --max-time 4 \
            'http://127.0.0.1:8080/health' 2>/dev/null" 2>/dev/null || echo "000")
        case "$HTTP_CODE" in
            200|503) ok "Backend listo (HTTP ${HTTP_CODE}) tras ${WAITED}s"; break ;;
        esac
        sleep 2; WAITED=$((WAITED + 2))
    done
    [ "$WAITED" -ge 15 ] && warn "Backend no respondió en 15s — revisa: podman logs $CONTAINER_BACKEND"
fi

# ─── PASO 2: Limpiar nftables ─────────────────────────────────────────────────
if $NFT_RESET; then
    hdr "2. Limpiando set nftables allowed_clients"

    # IPs de infraestructura que NUNCA se eliminan
    PROTECTED_IPS="${ROUTER_IP} ${ADMIN_IP} ${RASPI4B_IP} ${RASPI3B_IP} ${PORTAL_NODE_IP} ${AP_EXTENDER_IP} ${PORTAL_IP}"
    info "IPs protegidas (no se eliminan): ${PROTECTED_IPS}"

    # Obtener IPs actuales del set (solo guest IPs, excluyendo infraestructura)
    GUEST_IPS=$(router_ssh "
        nft list set ip captive allowed_clients 2>/dev/null \
            | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' \
            | sort -u
    " 2>/dev/null || echo "")

    if [ -z "$GUEST_IPS" ]; then
        ok "Set allowed_clients vacío o tabla no disponible — nada que limpiar"
    else
        REMOVED=0
        SKIPPED=0
        for ip in $GUEST_IPS; do
            # Verificar si es IP protegida
            is_protected=false
            for prot in $PROTECTED_IPS; do
                [ "$ip" = "$prot" ] && is_protected=true && break
            done

            if $is_protected; then
                SKIPPED=$((SKIPPED + 1))
                continue
            fi

            # Eliminar IP de invitado
            router_ssh "nft delete element ip captive allowed_clients { $ip } 2>/dev/null || true" \
                2>/dev/null && REMOVED=$((REMOVED + 1)) || true
        done
        ok "IPs de invitados eliminadas: ${REMOVED}  |  IPs protegidas conservadas: ${SKIPPED}"
    fi

    # Re-confirmar que las IPs de infraestructura siguen con timeout 0s
    info "Re-confirmando bypass permanente de infraestructura..."
    for ip in $PROTECTED_IPS; do
        [ -z "$ip" ] && continue
        router_ssh "nft add element ip captive allowed_clients { $ip timeout 0s } 2>/dev/null || true" \
            2>/dev/null || true
    done
    ok "Bypass de infraestructura confirmado"
fi

# ─── Resumen ──────────────────────────────────────────────────────────────────
hdr "Estado final"

if $DB_RESET; then
    FINAL=$(portal_ssh "
        if [ -f '$DB_HOST_PATH' ]; then
            sqlite3 '$DB_HOST_PATH' '
                SELECT \"clientes=\" || COUNT(*) FROM clientes;
                SELECT \"invitados=\" || COUNT(*) FROM invitados;
            '
        else
            echo 'clientes=BD_pendiente'
            echo 'invitados=BD_pendiente'
        fi
    " 2>/dev/null || echo -e "clientes=?\ninvitados=?")
    info "BD: $(echo "$FINAL" | tr '\n' '  ')"
fi

if $NFT_RESET; then
    NFT_COUNT=$(router_ssh "
        nft list set ip captive allowed_clients 2>/dev/null \
            | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | wc -l
    " 2>/dev/null || echo "?")
    info "Set allowed_clients: ${NFT_COUNT} IP(s) (solo infraestructura)"
fi

printf "\n${BOLD}${GREEN}✓ Reset completado. El portal está listo para una nueva demo.${NC}\n\n"
printf "  Puedes verificar el estado con:\n"
printf "    bash scripts/portal-reset-demo.sh --status\n"
printf "    bash scripts/health-raspi3b-portal.sh\n"
printf "\n"
