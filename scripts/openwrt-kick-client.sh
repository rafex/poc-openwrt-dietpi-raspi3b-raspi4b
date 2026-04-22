#!/bin/sh
# openwrt-kick-client.sh — Expulsa un cliente de la red WiFi por IP o MAC.
#
# Uso:
#   sh scripts/openwrt-kick-client.sh <IP>                # expulsar por IP
#   sh scripts/openwrt-kick-client.sh <MAC>               # expulsar por MAC
#   sh scripts/openwrt-kick-client.sh <IP>  --permanente  # expulsar y bloquear para siempre
#   sh scripts/openwrt-kick-client.sh <MAC> --permanente  # expulsar y bloquear para siempre
#   sh scripts/openwrt-kick-client.sh --lista             # ver clientes bloqueados permanentemente
#   sh scripts/openwrt-kick-client.sh --desbloquear <IP|MAC>  # quitar bloqueo permanente
#
# Ejemplos:
#   sh scripts/openwrt-kick-client.sh 192.168.1.55
#   sh scripts/openwrt-kick-client.sh aa:bb:cc:dd:ee:ff --permanente
#
# Qué hace:
#   1. Detecta si el argumento es IP o MAC.
#   2. Resuelve el par IP↔MAC usando ARP y leases de dnsmasq.
#   3. Elimina la IP del set nftables allowed_clients (vuelve al portal cautivo).
#   4. Desautentica el cliente del WiFi con hostapd_cli (corta conexión inmediata).
#   5. Con --permanente: añade la MAC a un set nftables blocked_macs persistente.
#
# Protecciones:
#   - Nunca expulsa al admin ($ADMIN_IP), las Raspis ni la IP del portal.
#   - Nunca bloquea MACs protegidas ($RASPI4B_MAC, $RASPI3B_MAC).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

# =============================================================================
# Constantes de este script
# =============================================================================
NFT_BLOCKED_SET="blocked_macs"              # set de MACs permanentemente bloqueadas
LEASES_FILE="/tmp/dhcp.leases"              # dnsmasq leases en el router
WIFI_IFACE="phy0-ap0"                       # interfaz WiFi (hostapd)
WIFI_IFACE_ALT="wlan0"                      # nombre alternativo si phy0-ap0 no funciona

PROTECTED_IPS="$ADMIN_IP $PORTAL_IP $RASPI4B_IP $RASPI3B_IP"
PROTECTED_MACS="$RASPI4B_MAC $RASPI3B_MAC"

# =============================================================================
# Helpers de formato
# =============================================================================
is_ip() {
    case "$1" in
        *.*.*.*) validate_ip "$1" && return 0 ;;
    esac
    return 1
}

is_mac() {
    # Acepta XX:XX:XX:XX:XX:XX (mayúsculas o minúsculas)
    case "$1" in
        ??:??:??:??:??:??) return 0 ;;
    esac
    return 1
}

normalize_mac() {
    # Convierte a minúsculas para comparar
    printf '%s' "$1" | tr 'A-F' 'a-f'
}

# =============================================================================
# Resolver IP → MAC usando ARP y leases del router
# =============================================================================
resolve_mac_from_ip() {
    local ip="$1"
    local mac

    # Intentar por ARP primero (más actualizado)
    mac=$(router_ssh "ip neigh show $ip 2>/dev/null | awk '{print \$5}' | head -1")
    if is_mac "$mac"; then
        printf '%s' "$mac"
        return 0
    fi

    # Fallback: leases de dnsmasq
    mac=$(router_ssh "awk '\$3==\"$ip\" {print \$2}' $LEASES_FILE 2>/dev/null | head -1")
    if is_mac "$mac"; then
        printf '%s' "$mac"
        return 0
    fi

    return 1
}

# =============================================================================
# Resolver MAC → IP usando ARP y leases del router
# =============================================================================
resolve_ip_from_mac() {
    local mac
    mac=$(normalize_mac "$1")
    local ip

    # Intentar por ARP
    ip=$(router_ssh "ip neigh show | awk '\$5==\"$mac\" {print \$1}' | head -1")
    if is_ip "$ip"; then
        printf '%s' "$ip"
        return 0
    fi

    # Fallback: leases de dnsmasq
    ip=$(router_ssh "awk 'tolower(\$2)==\"$mac\" {print \$3}' $LEASES_FILE 2>/dev/null | head -1")
    if is_ip "$ip"; then
        printf '%s' "$ip"
        return 0
    fi

    return 1
}

# =============================================================================
# Verificar si la IP/MAC es protegida
# =============================================================================
is_protected_ip() {
    local ip="$1"
    for p in $PROTECTED_IPS; do
        [ "$ip" = "$p" ] && return 0
    done
    return 1
}

is_protected_mac() {
    local mac
    mac=$(normalize_mac "$1")
    for m in $PROTECTED_MACS; do
        [ "$mac" = "$(normalize_mac "$m")" ] && return 0
    done
    return 1
}

# =============================================================================
# Asegurar que el set blocked_macs existe en nftables del router
# =============================================================================
ensure_blocked_set() {
    router_ssh "nft list set $NFT_TABLE $NFT_BLOCKED_SET > /dev/null 2>&1" && return 0

    log_info "Creando set $NFT_TABLE $NFT_BLOCKED_SET..."
    router_ssh "nft add set $NFT_TABLE $NFT_BLOCKED_SET { type ether_addr\; flags persistent\; }" || \
    router_ssh "nft add set $NFT_TABLE $NFT_BLOCKED_SET { type ether_addr\; }" || \
        die "No se pudo crear el set $NFT_BLOCKED_SET en el router"

    # Regla de bloqueo: DROP en forward si MAC origen está en blocked_macs
    router_ssh "nft add rule $NFT_TABLE forward \
        ether saddr @$NFT_BLOCKED_SET drop" 2>/dev/null || true
    # Y también en input (evita que accedan al propio router)
    router_ssh "nft add rule $NFT_TABLE input \
        ether saddr @$NFT_BLOCKED_SET drop" 2>/dev/null || true

    log_ok "Set $NFT_BLOCKED_SET creado con reglas de DROP"
}

# =============================================================================
# Operaciones de bloqueo permanente
# =============================================================================
mac_in_blocked_set() {
    local mac
    mac=$(normalize_mac "$1")
    router_ssh "nft list set $NFT_TABLE $NFT_BLOCKED_SET 2>/dev/null" | grep -qi "$mac"
}

block_mac_permanently() {
    local mac
    mac=$(normalize_mac "$1")
    ensure_blocked_set
    router_ssh "nft add element $NFT_TABLE $NFT_BLOCKED_SET { $mac }" || \
        die "No se pudo añadir $mac a $NFT_BLOCKED_SET"
    log_ok "MAC $mac bloqueada permanentemente en $NFT_BLOCKED_SET"
}

unblock_mac() {
    local mac
    mac=$(normalize_mac "$1")
    if ! mac_in_blocked_set "$mac"; then
        log_warn "$mac no está en $NFT_BLOCKED_SET (nada que desbloquear)"
        return 0
    fi
    router_ssh "nft delete element $NFT_TABLE $NFT_BLOCKED_SET { $mac }" || \
        die "No se pudo eliminar $mac de $NFT_BLOCKED_SET"
    log_ok "MAC $mac desbloqueada de $NFT_BLOCKED_SET"
}

# =============================================================================
# Desautenticar cliente del WiFi (corte inmediato de la conexión)
# =============================================================================
deauth_client() {
    local mac
    mac=$(normalize_mac "$1")

    # hostapd_cli puede usar el nombre de interfaz o el socket
    local result
    result=$(router_ssh "
        for iface in $WIFI_IFACE $WIFI_IFACE_ALT wlan1 wlan0-1; do
            if hostapd_cli -i \"\$iface\" deauthenticate $mac 2>/dev/null | grep -q OK; then
                echo \"OK:\$iface\"
                break
            fi
        done
    " 2>/dev/null)

    if printf '%s' "$result" | grep -q '^OK:'; then
        local iface
        iface=$(printf '%s' "$result" | cut -d: -f2)
        log_ok "Cliente desautenticado del WiFi (iface=$iface)"
        return 0
    fi

    log_warn "No se pudo desautenticar $mac via hostapd_cli"
    log_warn "El cliente perderá acceso cuando su sesión expire (timeout del portal)"
    return 0  # no fatal — el bloqueo nftables ya funciona
}

# =============================================================================
# Listar clientes bloqueados permanentemente
# =============================================================================
list_blocked() {
    check_ssh_key
    test_router_ssh

    router_ssh "nft list set $NFT_TABLE $NFT_BLOCKED_SET 2>/dev/null" | \
        grep -v 'set\|table\|type\|flags\|{' | \
        grep -v '^$' | grep -v '^}' | \
        sed 's/,/\n/g' | tr -d '\t ' | grep -v '^$' | sort \
    > /tmp/blocked_list_$$.tmp

    if [ ! -s /tmp/blocked_list_$$.tmp ]; then
        log_info "No hay MACs bloqueadas permanentemente."
        rm -f /tmp/blocked_list_$$.tmp
        exit 0
    fi

    printf '\n%-20s  %-15s  %-20s\n' "MAC" "IP actual" "Hostname"
    printf '%-20s  %-15s  %-20s\n' "--------------------" "---------------" "--------------------"

    while read -r mac; do
        [ -z "$mac" ] && continue
        local ip hostname
        ip=$(router_ssh "awk 'tolower(\$2)==\"$mac\" {print \$3}' $LEASES_FILE 2>/dev/null | head -1")
        hostname=$(router_ssh "awk 'tolower(\$2)==\"$mac\" {print \$4}' $LEASES_FILE 2>/dev/null | head -1")
        printf '%-20s  %-15s  %-20s\n' "$mac" "${ip:--}" "${hostname:--}"
    done < /tmp/blocked_list_$$.tmp

    rm -f /tmp/blocked_list_$$.tmp
    printf '\n'
    exit 0
}

# =============================================================================
# Desbloquear — acepta IP o MAC
# =============================================================================
do_unblock() {
    local target="$1"
    check_ssh_key
    test_router_ssh

    if is_mac "$target"; then
        unblock_mac "$target"
    elif is_ip "$target"; then
        local mac
        mac=$(resolve_mac_from_ip "$target")
        if [ -z "$mac" ]; then
            die "No se encontró MAC para la IP $target (cliente desconectado?)"
        fi
        log_info "IP $target → MAC $mac"
        unblock_mac "$mac"
        # También reautorizar en el portal cautivo
        if ! router_ip_in_set "$target"; then
            router_add_ip "$target"
            log_ok "IP $target reautorizada en el portal cautivo"
        fi
    else
        die "Argumento inválido: '$target'. Usa una IP o MAC."
    fi
    exit 0
}

# =============================================================================
# Parseo de argumentos
# =============================================================================
TARGET=""
PERMANENTE=0

# Opciones especiales sin TARGET
case "${1:-}" in
    --lista|--list|-l)
        list_blocked
        ;;
    --desbloquear|--unblock|-u)
        [ -z "${2:-}" ] && die "Uso: $0 --desbloquear <IP|MAC>"
        do_unblock "$2"
        ;;
    --ayuda|--help|-h)
        sed -n '2,20p' "$0" | sed 's/^# \?//'
        exit 0
        ;;
esac

TARGET="${1:-}"
[ -z "$TARGET" ] && {
    log_error "Uso: $0 <IP|MAC> [--permanente]"
    printf 'Ejemplos:\n'
    printf '  sh %s 192.168.1.55\n' "$0"
    printf '  sh %s aa:bb:cc:dd:ee:ff --permanente\n' "$0"
    printf '  sh %s --lista\n' "$0"
    exit 1
}

[ "${2:-}" = "--permanente" ] && PERMANENTE=1

# =============================================================================
# Detectar tipo de argumento y resolver par IP↔MAC
# =============================================================================
if is_ip "$TARGET"; then
    KICK_IP="$TARGET"
    log_info "Entrada: IP $KICK_IP"
    validate_ip "$KICK_IP" || die "IP inválida: $KICK_IP"

    check_ssh_key
    test_router_ssh

    log_info "Resolviendo MAC para $KICK_IP..."
    KICK_MAC=$(resolve_mac_from_ip "$KICK_IP")
    if [ -z "$KICK_MAC" ]; then
        log_warn "No se encontró MAC para $KICK_IP (cliente offline o fuera del ARP cache)"
        log_warn "Se procederá sin desautenticación WiFi"
    else
        log_info "IP $KICK_IP → MAC $KICK_MAC"
    fi

elif is_mac "$TARGET"; then
    KICK_MAC=$(normalize_mac "$TARGET")
    log_info "Entrada: MAC $KICK_MAC"

    check_ssh_key
    test_router_ssh

    log_info "Resolviendo IP para $KICK_MAC..."
    KICK_IP=$(resolve_ip_from_mac "$KICK_MAC")
    if [ -z "$KICK_IP" ]; then
        log_warn "No se encontró IP para $KICK_MAC (cliente desconectado o IP expirada)"
        if [ "$PERMANENTE" -eq 0 ]; then
            die "Sin IP no se puede quitar del portal cautivo. Usa --permanente para bloquear la MAC."
        fi
    else
        log_info "MAC $KICK_MAC → IP $KICK_IP"
    fi
else
    die "Argumento no reconocido: '$TARGET'
  Usa una IP (ej: 192.168.1.55) o MAC (ej: aa:bb:cc:dd:ee:ff)"
fi

# =============================================================================
# Protecciones de seguridad
# =============================================================================
if [ -n "$KICK_IP" ] && is_protected_ip "$KICK_IP"; then
    die "PROTECCIÓN: No se puede expulsar la IP $KICK_IP (es una IP protegida del sistema)"
fi
if [ -n "$KICK_MAC" ] && is_protected_mac "$KICK_MAC"; then
    die "PROTECCIÓN: No se puede expulsar la MAC $KICK_MAC (es una MAC protegida del sistema)"
fi

# Verificar que el set del portal existe
router_set_exists || die "El set '$NFT_SET' no existe. Ejecuta primero: sh scripts/setup-openwrt.sh"

# =============================================================================
# EXPULSIÓN
# =============================================================================
printf '\n'
log_info "========================================"
log_info "  EXPULSANDO CLIENTE"
[ -n "$KICK_IP"  ] && log_info "  IP : $KICK_IP"
[ -n "$KICK_MAC" ] && log_info "  MAC: $KICK_MAC"
[ "$PERMANENTE" -eq 1 ] && log_info "  MODO: PERMANENTE"
log_info "========================================"
printf '\n'

# Paso 1: quitar del portal cautivo (si tiene IP)
if [ -n "$KICK_IP" ]; then
    if router_ip_in_set "$KICK_IP"; then
        log_info "Eliminando $KICK_IP de $NFT_SET..."
        router_del_ip "$KICK_IP" || die "No se pudo eliminar $KICK_IP de $NFT_SET"
        log_ok "$KICK_IP eliminada del set (volverá al portal cautivo)"
    else
        log_info "$KICK_IP no estaba en $NFT_SET (ya estaba sin acceso)"
    fi
fi

# Paso 2: desautenticar del WiFi (si tenemos MAC)
if [ -n "$KICK_MAC" ]; then
    log_info "Desautenticando $KICK_MAC del WiFi..."
    deauth_client "$KICK_MAC"
fi

# Paso 3: bloqueo permanente (si --permanente)
if [ "$PERMANENTE" -eq 1 ]; then
    if [ -z "$KICK_MAC" ]; then
        log_warn "No se pudo bloquear permanentemente: MAC desconocida"
    else
        log_info "Añadiendo $KICK_MAC a $NFT_BLOCKED_SET (bloqueo permanente)..."
        block_mac_permanently "$KICK_MAC"
    fi
fi

# =============================================================================
# Resumen
# =============================================================================
printf '\n'
log_ok "========================================"
log_ok "  CLIENTE EXPULSADO"
[ -n "$KICK_IP"  ] && log_ok "  IP : $KICK_IP → devuelta al portal"
[ -n "$KICK_MAC" ] && log_ok "  MAC: $KICK_MAC → desautenticada del WiFi"
[ "$PERMANENTE" -eq 1 ] && log_ok "  Bloqueo permanente activo"
log_ok "========================================"
printf '\n'

if [ "$PERMANENTE" -eq 0 ]; then
    log_info "Nota: el cliente podrá volver a conectarse y ver el portal cautivo."
    log_info "      Para bloquearlo permanentemente: $0 $TARGET --permanente"
fi
