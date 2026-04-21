#!/bin/sh
# openwrt-allow-client.sh — Autoriza una IP en el captive portal de OpenWrt
#
# Uso:
#   sh scripts/openwrt-allow-client.sh <IP>              # expira en 30 min (por defecto)
#   sh scripts/openwrt-allow-client.sh <IP> --permanent  # no expira nunca
#
# Ejemplos:
#   sh scripts/openwrt-allow-client.sh 192.168.1.55
#   sh scripts/openwrt-allow-client.sh 192.168.1.55 --permanent
#
# Por defecto, la autorizacion expira en 30 minutos (timeout del set nftables).
# Con --permanent, la IP se agrega con timeout 0 y nunca expira.

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

# =============================================================================
# Autorizar IP
# =============================================================================
if router_ip_in_set "$IP"; then
    if [ "$PERMANENT" -eq 1 ]; then
        # Puede estar en el set pero con timeout — re-agregar con timeout 0
        log_info "$IP ya esta en el set — re-agregando como permanente..."
        router_ssh "nft add element $NFT_TABLE $NFT_SET { $IP timeout 0 }" || \
            die "No se pudo re-agregar $IP con timeout 0"
        log_ok "$IP marcada como permanente (timeout 0)"
    else
        log_info "$IP ya esta autorizada en $NFT_SET"
        # Mostrar tiempo restante si el set tiene timeout
        REMAINING=$(router_ssh \
            "nft list set $NFT_TABLE $NFT_SET 2>/dev/null | grep '$IP'" 2>/dev/null || echo "")
        [ -n "$REMAINING" ] && log_info "Estado actual: $REMAINING"
    fi
    exit 0
fi

log_info "Autorizando $IP en $NFT_SET..."

if [ "$PERMANENT" -eq 1 ]; then
    # timeout 0 = nunca expira
    router_ssh "nft add element $NFT_TABLE $NFT_SET { $IP timeout 0 }" || \
        die "No se pudo agregar $IP con timeout 0 al set $NFT_SET"
    MSG="$IP autorizada permanentemente (no expira)"
else
    # Sin timeout explícito → hereda el timeout del set (30 minutos)
    router_add_ip "$IP" || die "No se pudo agregar $IP al set $NFT_SET"
    MSG="$IP autorizada por 30 minutos — luego volvera al portal"
fi

router_ip_in_set "$IP" || die "Verificacion fallo: $IP no aparece en $NFT_SET despues de agregar"

log_ok "$MSG"
