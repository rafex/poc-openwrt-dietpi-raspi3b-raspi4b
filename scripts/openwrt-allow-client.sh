#!/bin/sh
# openwrt-allow-client.sh — Autoriza una IP en el captive portal de OpenWrt
#
# Uso:
#   sh scripts/openwrt-allow-client.sh <IP>              # expira segun timeout del set (default: 120m)
#   sh scripts/openwrt-allow-client.sh <IP> --permanent  # no expira nunca
#
# Ejemplos:
#   sh scripts/openwrt-allow-client.sh 192.168.1.55
#   sh scripts/openwrt-allow-client.sh 192.168.1.55 --permanent
#
# Por defecto, la autorizacion expira segun timeout del set nftables (PORTAL_TIMEOUT, default 120m).
# Con --permanent, la IP se agrega con timeout 0s y nunca expira.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

# =============================================================================
# Validar argumentos
# =============================================================================
IP="$1"
PERMANENT=0

if [ -z "$IP" ]; then
    log_error "Uso: $0 <IP> [--permanent]"
    printf 'Ejemplo: sh %s 192.168.1.55\n' "$0"
    printf '         sh %s 192.168.1.55 --permanent\n' "$0"
    exit 1
fi

validate_ip "$IP" || die "IP invalida: '$IP'
  Formato esperado: A.B.C.D (ej: 192.168.1.55)"

case "$2" in
    --permanent) PERMANENT=1 ;;
    '')          PERMANENT=0 ;;
    *) die "Argumento desconocido: '$2'. Opciones: --permanent" ;;
esac

# =============================================================================
# Pre-flight checks
# =============================================================================
check_ssh_key
test_router_ssh

router_set_exists || die "El set '$NFT_SET' no existe en el router.
  Ejecuta primero: sh scripts/setup-openwrt.sh"

resolve_mac_for_ip() {
    local ip="$1"
    router_ssh "
        (ip neigh show $ip 2>/dev/null | awk '{print \$5}' | head -1;
         awk '\$3==\"$ip\" {print tolower(\$2)}' /tmp/dhcp.leases 2>/dev/null | head -1) \
        | grep -m1 -E '^[0-9a-f]{2}(:[0-9a-f]{2}){5}\$'
    " 2>/dev/null || true
}

unblock_mac_if_blocked() {
    local ip="$1"
    local mac
    mac=$(resolve_mac_for_ip "$ip")
    [ -z "$mac" ] && return 0

    # Si el set blocked_macs no existe, no hay nada que limpiar.
    router_ssh "nft list set $NFT_TABLE blocked_macs > /dev/null 2>&1" || return 0

    # Intentar borrar la MAC del bloqueo (no falla si no estaba).
    if router_ssh "nft delete element $NFT_TABLE blocked_macs { $mac }" 2>/dev/null; then
        log_ok "MAC $mac removida de blocked_macs (IP $ip ya puede navegar)"
    fi
}

# =============================================================================
# Autorizar IP
# =============================================================================
if router_ip_in_set "$IP"; then
    if [ "$PERMANENT" -eq 1 ]; then
        # Puede estar en el set pero con timeout — re-agregar con timeout 0
        log_info "$IP ya esta en el set — re-agregando como permanente..."
        router_ssh "nft add element $NFT_TABLE $NFT_SET { $IP timeout 0s }" || \
            die "No se pudo re-agregar $IP con timeout 0s"
        unblock_mac_if_blocked "$IP"
        log_ok "$IP marcada como permanente (timeout 0s)"
    else
        log_info "$IP ya esta autorizada en $NFT_SET"
        # Mostrar tiempo restante si el set tiene timeout
        REMAINING=$(router_ssh \
            "nft list set $NFT_TABLE $NFT_SET 2>/dev/null | grep '$IP'" 2>/dev/null || echo "")
        [ -n "$REMAINING" ] && log_info "Estado actual: $REMAINING"
        unblock_mac_if_blocked "$IP"
    fi
    exit 0
fi

log_info "Autorizando $IP en $NFT_SET..."

if [ "$PERMANENT" -eq 1 ]; then
    # timeout 0s = nunca expira
    router_ssh "nft add element $NFT_TABLE $NFT_SET { $IP timeout 0s }" || \
        die "No se pudo agregar $IP con timeout 0 al set $NFT_SET"
    MSG="$IP autorizada permanentemente (no expira)"
else
    # Sin timeout explícito → hereda el timeout del set (PORTAL_TIMEOUT, default 120m)
    router_add_ip "$IP" || die "No se pudo agregar $IP al set $NFT_SET"
    MSG="$IP autorizada por $PORTAL_TIMEOUT — luego volvera al portal"
fi

router_ip_in_set "$IP" || die "Verificacion fallo: $IP no aparece en $NFT_SET despues de agregar"
unblock_mac_if_blocked "$IP"

log_ok "$MSG"
