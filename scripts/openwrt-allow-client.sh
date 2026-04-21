#!/bin/sh
# openwrt-allow-client.sh — Autoriza una IP en el captive portal de OpenWrt
#
# Uso: sh scripts/openwrt-allow-client.sh <IP>
#
# Ejemplo:
#   sh scripts/openwrt-allow-client.sh 192.168.1.55
#
# Efecto: La IP puede navegar libremente sin pasar por el portal.
# Los cambios son inmediatos y persisten hasta que se haga flush del set
# o se ejecute openwrt-reset-firewall.sh.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

# =============================================================================
# Validar argumentos
# =============================================================================
IP="$1"

if [ -z "$IP" ]; then
    log_error "Uso: $0 <IP>"
    printf 'Ejemplo: sh %s 192.168.1.55\n' "$0"
    exit 1
fi

validate_ip "$IP" || die "IP invalida: '$IP'
  Formato esperado: A.B.C.D (ej: 192.168.1.55)"

# =============================================================================
# Pre-flight checks
# =============================================================================
check_ssh_key
test_router_ssh

# Verificar que el set existe (requiere setup-openwrt.sh previo)
router_set_exists || die "El set '$NFT_SET' no existe en el router.
  Ejecuta primero: sh scripts/setup-openwrt.sh"

# =============================================================================
# Autorizar IP
# =============================================================================
# Verificar si ya esta autorizada
if router_ip_in_set "$IP"; then
    log_info "$IP ya esta autorizada en $NFT_SET (no se requiere accion)"
    exit 0
fi

log_info "Autorizando $IP en $NFT_SET..."
router_add_ip "$IP" || die "No se pudo agregar $IP al set $NFT_SET"

# Verificar que se agrego correctamente
router_ip_in_set "$IP" || die "Verificacion fallo: $IP no aparece en $NFT_SET despues de agregar"

log_ok "$IP autorizada — puede navegar libremente"
