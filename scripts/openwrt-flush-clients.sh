#!/bin/sh
# openwrt-flush-clients.sh — Resetea el set allowed_clients a las IPs base
#
# Uso:
#   sh scripts/openwrt-flush-clients.sh          # pide confirmacion
#   sh scripts/openwrt-flush-clients.sh --force   # sin confirmacion (para scripts)
#
# Efecto:
#   - Elimina TODOS los clientes autorizados del set allowed_clients
#   - Conserva SOLO las IPs base: admin (192.168.1.128) y portal (192.168.1.167)
#   - Todos los clientes WiFi vuelven al captive portal inmediatamente
#   - Limpia conntrack para forzar reconexion (evita bypass por ESTABLISHED)
#
# Diferencia con openwrt-reset-firewall.sh:
#   - Este script NO elimina las reglas nftables ni dnsmasq
#   - Solo vacia los clientes autorizados — el portal sigue activo
#   - openwrt-reset-firewall.sh desactiva TODO el captive portal

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

# =============================================================================
# Flags
# =============================================================================
FORCE=0
for arg in "$@"; do
    case "$arg" in
        --force|-f) FORCE=1 ;;
        --help|-h)
            sed -n '2,15p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) die "Argumento desconocido: '$arg'. Opciones: --force" ;;
    esac
done

# =============================================================================
# Pre-flight checks
# =============================================================================
check_ssh_key
test_router_ssh

router_table_exists || die "La tabla '$NFT_TABLE' no existe en el router.
  Ejecuta primero: sh scripts/setup-openwrt.sh"

router_set_exists || die "El set '$NFT_SET' no existe en el router."

# =============================================================================
# Mostrar estado actual antes de limpiar
# =============================================================================
log_info "Estado actual del set $NFT_SET:"
CURRENT=$(router_ssh "nft list set $NFT_TABLE $NFT_SET 2>/dev/null" | \
    grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | sort)

CLIENT_COUNT=0
for ip in $CURRENT; do
    case "$ip" in
        "$ADMIN_IP"|"$PORTAL_IP") ;;
        *) CLIENT_COUNT=$((CLIENT_COUNT + 1)) ;;
    esac
    printf '  %s\n' "$ip"
done

if [ "$CLIENT_COUNT" -eq 0 ]; then
    log_info "No hay clientes autorizados en este momento (solo admin y portal)"
    exit 0
fi

printf '\n'
log_warn "$CLIENT_COUNT cliente(s) seran devueltos al portal"

# =============================================================================
# Confirmacion
# =============================================================================
if [ "$FORCE" -eq 0 ]; then
    printf 'Continuar? [s/N]: '
    read -r CONFIRM
    case "$CONFIRM" in
        s|S|si|SI|yes|YES) ;;
        *) log_info "Cancelado."; exit 0 ;;
    esac
fi

# =============================================================================
# Flush del set y restauracion de IPs base
# =============================================================================
log_info "Limpiando set $NFT_SET..."

# Flush del set completo (elimina todos los elementos incluidos admin y portal)
router_ssh "nft flush set $NFT_TABLE $NFT_SET" || \
    die "No se pudo hacer flush del set $NFT_SET"

# Restaurar IPs base como permanentes (timeout 0s = nunca expiran)
log_info "Restaurando IPs base (admin y portal como permanentes)..."
router_ssh "nft add element $NFT_TABLE $NFT_SET { $ADMIN_IP timeout 0s }" || \
    die "No se pudo restaurar $ADMIN_IP"
router_ssh "nft add element $NFT_TABLE $NFT_SET { $PORTAL_IP timeout 0s }" || \
    die "No se pudo restaurar $PORTAL_IP"

# Verificar que las IPs base estan presentes
router_ip_in_set "$ADMIN_IP" || die "CRITICO: $ADMIN_IP no esta en el set tras el flush"
log_ok "Admin $ADMIN_IP restaurado como permanente"
log_ok "Portal $PORTAL_IP restaurado como permanente"

# Limpiar conntrack para forzar que las conexiones ESTABLISHED no bypaseen el bloqueo
log_info "Limpiando conntrack..."
router_ssh "conntrack -F 2>/dev/null && echo 'conntrack flush OK' || echo 'conntrack no disponible'"

# =============================================================================
# Verificacion final
# =============================================================================
REMAINING=$(router_ssh "nft list set $NFT_TABLE $NFT_SET 2>/dev/null" | \
    grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | sort | tr '\n' ' ')

printf '\n'
log_ok "Set reseteado — IPs actuales: $REMAINING"
log_ok "$CLIENT_COUNT cliente(s) devuelto(s) al captive portal"
log_info "Todos los dispositivos WiFi seran redirigidos al portal al intentar navegar"
