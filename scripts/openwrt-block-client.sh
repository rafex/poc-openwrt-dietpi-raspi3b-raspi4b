#!/bin/sh
# openwrt-block-client.sh — Bloquea una IP en el captive portal de OpenWrt
#
# Uso: sh scripts/openwrt-block-client.sh <IP>
#
# Ejemplo:
#   sh scripts/openwrt-block-client.sh 192.168.1.55
#
# Efecto: La IP es devuelta al captive portal y bloqueada del acceso libre.
# NUNCA bloquea admin (192.168.1.113), portal/RafexPi4B (192.168.1.167) ni RafexPi3B (192.168.1.181).
#
# Nota: Si el cliente tiene una conexion HTTP activa (ESTABLISHED en conntrack),
# puede seguir navegando hasta que la conexion se cierre. Para forzar el
# bloqueo inmediato se puede ejecutar openwrt-reset-firewall.sh + setup-openwrt.sh.

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
# SEGURIDAD: Nunca bloquear la IP de admin
# =============================================================================
if [ "$IP" = "$ADMIN_IP" ]; then
    die "SEGURIDAD: No se puede bloquear la IP de admin ($ADMIN_IP).
  Esta proteccion es permanente."
fi

# Proteccion adicional: tampoco bloquear la IP del portal mismo
if [ "$IP" = "$PORTAL_IP" ]; then
    die "No se puede bloquear la IP del portal ($PORTAL_IP)."
fi

# Regla de oro: tampoco bloquear la Pi de sensor
if [ "$IP" = "$RASPI3B_IP" ]; then
    die "SEGURIDAD: No se puede bloquear la IP de RafexPi3B ($RASPI3B_IP)."
fi

# =============================================================================
# Pre-flight checks
# =============================================================================
check_ssh_key
test_router_ssh

# Verificar que el set existe
router_set_exists || die "El set '$NFT_SET' no existe en el router.
  Ejecuta primero: sh scripts/setup-openwrt.sh"

# =============================================================================
# Bloquear IP
# =============================================================================
# Verificar si la IP esta actualmente en el set
if ! router_ip_in_set "$IP"; then
    log_info "$IP no estaba en $NFT_SET (ya esta bloqueada o nunca fue autorizada)"
    exit 0
fi

log_info "Bloqueando $IP en $NFT_SET..."
router_del_ip "$IP" || die "No se pudo eliminar $IP del set $NFT_SET"

# Verificar que se elimino
if router_ip_in_set "$IP"; then
    die "Verificacion fallo: $IP sigue apareciendo en $NFT_SET despues de eliminar"
fi

log_ok "$IP bloqueada — sera redirigida al captive portal"
log_info "Nota: conexiones HTTP activas (conntrack ESTABLISHED) expiraran al cerrarse."
