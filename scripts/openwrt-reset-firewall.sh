#!/bin/sh
# openwrt-reset-firewall.sh — HERRAMIENTA DE EMERGENCIA
# Resetea las reglas del captive portal al estado inicial (sin bloqueos)
#
# Uso: sh scripts/openwrt-reset-firewall.sh
#
# Efecto:
#   - Elimina la tabla 'ip captive' (redireccion HTTP + bloqueo de forward)
#   - Elimina /etc/nftables.d/captive-portal.nft (persistencia)
#   - Elimina la configuracion dnsmasq del captive portal
#   - Limpia conntrack
#   - Todos los clientes WiFi quedan con acceso libre
#   - NO toca la configuracion base de fw4 de OpenWrt
#
# Despues de ejecutar este script, el portal queda INACTIVO.
# Para reactivarlo: sh scripts/setup-openwrt.sh
#
# SEGURIDAD: El admin (192.168.1.113) siempre tiene acceso independientemente
# de este script (fw4 base lo permite).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

# =============================================================================
# Confirmacion de seguridad
# =============================================================================
printf '\n'
log_warn "=== RESET DE FIREWALL — HERRAMIENTA DE EMERGENCIA ==="
printf '\n'
log_warn "Este script eliminara TODAS las reglas del captive portal."
log_warn "Todos los clientes WiFi tendran acceso libre a internet."
printf '\n'
printf 'Continuar? [s/N]: '
read -r CONFIRM

case "$CONFIRM" in
    s|S|si|SI|yes|YES)
        log_info "Continuando con el reset..."
        ;;
    *)
        log_info "Cancelado."
        exit 0
        ;;
esac

# =============================================================================
# Pre-flight checks
# =============================================================================
check_ssh_key
test_router_ssh

# =============================================================================
# PASO 1: Eliminar tabla nftables del captive portal
# =============================================================================
log_info "--- PASO 1: Eliminando tabla nftables '$NFT_TABLE' ---"

if router_table_exists; then
    router_ssh "nft delete table $NFT_TABLE" && \
        log_ok "Tabla '$NFT_TABLE' eliminada" || \
        log_warn "No se pudo eliminar la tabla (puede ya no existir)"
else
    log_info "Tabla '$NFT_TABLE' no existe (skip)"
fi

# Verificar que la tabla fue eliminada
if router_table_exists; then
    log_warn "La tabla '$NFT_TABLE' sigue existiendo — intentando flush forzado..."
    router_ssh "nft flush table $NFT_TABLE 2>/dev/null; nft delete table $NFT_TABLE 2>/dev/null"
fi

# =============================================================================
# PASO 2: Eliminar archivos de persistencia nftables
# =============================================================================
log_info "--- PASO 2: Eliminando archivos de persistencia ---"

# /etc/nftables.d/captive-portal.nft
router_ssh "
    if [ -f /etc/nftables.d/captive-portal.nft ]; then
        rm -f /etc/nftables.d/captive-portal.nft
        echo 'Eliminado: /etc/nftables.d/captive-portal.nft'
    else
        echo 'No existe: /etc/nftables.d/captive-portal.nft (OK)'
    fi
"

# /etc/captive-portal.nft (fallback)
router_ssh "
    if [ -f /etc/captive-portal.nft ]; then
        rm -f /etc/captive-portal.nft
        echo 'Eliminado: /etc/captive-portal.nft'
    fi
"

# Limpiar linea de /etc/firewall.user si existe
router_ssh "
    if grep -q 'captive-portal.nft' /etc/firewall.user 2>/dev/null; then
        sed -i '/captive-portal.nft/d' /etc/firewall.user
        echo 'Linea de captive portal eliminada de /etc/firewall.user'
    fi
"
log_ok "Archivos de persistencia eliminados"

# =============================================================================
# PASO 3: Eliminar configuracion dnsmasq del captive portal
# =============================================================================
log_info "--- PASO 3: Eliminando configuracion dnsmasq ---"

# /etc/dnsmasq.d/captive-portal.conf
router_ssh "
    if [ -f /etc/dnsmasq.d/captive-portal.conf ]; then
        rm -f /etc/dnsmasq.d/captive-portal.conf
        echo 'Eliminado: /etc/dnsmasq.d/captive-portal.conf'
    else
        echo 'No existe: /etc/dnsmasq.d/captive-portal.conf (OK)'
    fi
"

# Limpiar bloque en /etc/dnsmasq.conf (fallback)
router_ssh "
    if grep -q '# --- captive-portal begin ---' /etc/dnsmasq.conf 2>/dev/null; then
        sed -i '/# --- captive-portal begin ---/,/# --- captive-portal end ---/d' /etc/dnsmasq.conf
        echo 'Bloque captive portal eliminado de /etc/dnsmasq.conf'
    fi
"

# Recargar dnsmasq para aplicar cambios
log_info "Recargando dnsmasq..."
if router_ssh "/etc/init.d/dnsmasq reload 2>/dev/null || /etc/init.d/dnsmasq restart 2>/dev/null"; then
    # Verificar que el proceso esté vivo
    if router_ssh "pidof dnsmasq >/dev/null 2>&1"; then
        # Verificar resolución local en el router
        if router_ssh "nslookup openwrt.org 127.0.0.1 >/dev/null 2>&1"; then
            log_ok "dnsmasq recargado y resolución DNS local OK"
        else
            log_warn "dnsmasq está corriendo, pero nslookup local falló"
            log_warn "Revisa en router: logread | tail -80"
        fi
    else
        log_warn "dnsmasq no quedó corriendo tras recarga/restart"
        log_warn "Intenta manualmente: /etc/init.d/dnsmasq restart"
    fi
else
    log_warn "No se pudo recargar/reiniciar dnsmasq automáticamente"
    log_warn "Intenta manualmente en router: /etc/init.d/dnsmasq restart"
fi

# =============================================================================
# PASO 4: Limpiar conntrack
# =============================================================================
log_info "--- PASO 4: Limpiando conntrack ---"

router_ssh "
    if command -v conntrack > /dev/null 2>&1; then
        conntrack -F && echo 'conntrack flush OK'
    else
        echo 'conntrack no disponible (las conexiones expiraran naturalmente)'
    fi
" || true
log_ok "Conntrack limpiado (o no disponible)"

# =============================================================================
# PASO 5: Verificacion final
# =============================================================================
log_info "--- PASO 5: Verificacion final ---"

# Verificar que fw4 (firewall base de OpenWrt) sigue funcionando
log_info "Verificando que fw4 esta intacto..."
router_ssh "nft list table inet fw4 > /dev/null 2>&1" && \
    log_ok "fw4 base de OpenWrt esta intacto" || \
    log_warn "No se pudo verificar fw4 (puede estar en estado degradado — reinicia el firewall con: /etc/init.d/firewall restart)"

# Confirmar que NO hay tabla captive activa
if router_table_exists; then
    log_warn "ATENCION: La tabla '$NFT_TABLE' sigue existiendo — puede requerir intervencion manual"
    log_warn "Conecate directamente: ssh root@$ROUTER_IP"
    log_warn "Y ejecuta: nft delete table $NFT_TABLE"
else
    log_ok "Tabla '$NFT_TABLE' no existe — captive portal completamente desactivado"
fi

printf '\n'
log_ok "=== Reset de firewall completado ==="
printf '\n'
log_info "Estado actual:"
printf '  - Captive portal:  INACTIVO\n'
printf '  - Redireccion HTTP: DESACTIVADA\n'
printf '  - Bloqueo WiFi:     DESACTIVADO\n'
printf '  - dnsmasq:         Restaurado al estado base\n'
printf '  - fw4 base:        INTACTO\n'
printf '\n'
log_info "Para reactivar el captive portal:"
printf '  sh scripts/setup-openwrt.sh\n'
