#!/bin/sh
# openwrt-reserve-raspi.sh — Reserva permanente de IP para la Raspberry Pi en OpenWrt
#
# Uso:
#   sh scripts/openwrt-reserve-raspi.sh --auto [IP]
#       Detecta la MAC de esta misma máquina (eth0/eth1/wlan0) y reserva la IP indicada.
#       Si no se pasa IP, usa 192.168.1.167 (PORTAL_IP de common.sh).
#       Pensado para ejecutarse directamente desde la Pi que se quiere reservar.
#
#   sh scripts/openwrt-reserve-raspi.sh --mac AA:BB:CC:DD:EE:FF [--ip 192.168.1.167]
#       MAC manual. IP opcional (por defecto PORTAL_IP).
#
#   sh scripts/openwrt-reserve-raspi.sh [--ip 192.168.1.167]
#       Sin --auto ni --mac: detecta la MAC desde el ARP/leases del router (modo legacy).
#
# Qué hace:
#   1. Obtiene la MAC (local en --auto, por argumento, o desde el router)
#   2. Valida que la IP a reservar no esté ya asignada a otra MAC
#   3. Crea o actualiza la reserva UCI dhcp.@host con leasetime=infinite
#   4. Verifica que la DHCP option 6 (DNS) apunte al router
#   5. Recarga dnsmasq
#   6. Muestra tabla de reservas activas
#
# Por qué es necesario:
#   Todos los scripts y manifiestos k8s usan PORTAL_IP como IP fija de la Pi.
#   Sin esta reserva, tras un reinicio la Pi podría obtener otra IP y el
#   captive portal dejaría de funcionar.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

# =============================================================================
# Constantes
# =============================================================================
RASPI_HOSTNAME="RafexPi"
RASPI_IP="$PORTAL_IP"      # 192.168.1.167 — puede sobreescribirse con --ip
MANUAL_MAC=""
AUTO_MODE=0
EXPLICIT_IP=0

# =============================================================================
# Argumentos
# =============================================================================
while [ $# -gt 0 ]; do
    case "$1" in
        --auto|-a)
            AUTO_MODE=1
            ;;
        --mac)
            shift
            MANUAL_MAC="$1"
            ;;
        --mac=*)
            MANUAL_MAC="${1#--mac=}"
            ;;
        --ip)
            shift
            RASPI_IP="$1"
            EXPLICIT_IP=1
            ;;
        --ip=*)
            RASPI_IP="${1#--ip=}"
            EXPLICIT_IP=1
            ;;
        --hostname)
            shift
            RASPI_HOSTNAME="$1"
            ;;
        --hostname=*)
            RASPI_HOSTNAME="${1#--hostname=}"
            ;;
        --help|-h)
            sed -n '2,25p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        # Compatibilidad: primer argumento posicional como IP
        [0-9]*.[0-9]*.[0-9]*.[0-9]*)
            RASPI_IP="$1"
            EXPLICIT_IP=1
            ;;
        *)
            die "Argumento desconocido: '$1'
  Uso: sh $0 --auto [IP]
       sh $0 --mac AA:BB:CC:DD:EE:FF [--ip IP]
       sh $0 --help"
            ;;
    esac
    shift
done

# Validar la IP objetivo
validate_ip "$RASPI_IP" || die "IP inválida: '$RASPI_IP'"

# =============================================================================
# Pre-flight
# =============================================================================
check_ssh_key
test_router_ssh

# =============================================================================
# Helpers
# =============================================================================
detect_mac_router() {
    _ip="$1"
    _mac="$(router_ssh "ip neigh show $_ip 2>/dev/null | awk '{print \$5}' | head -1" 2>/dev/null)"
    if [ -z "$_mac" ] || [ "$_mac" = "FAILED" ]; then
        _mac="$(router_ssh "awk '\$3==\"$_ip\"{print \$2}' /tmp/dhcp.leases 2>/dev/null | head -1" 2>/dev/null)"
    fi
    if [ -z "$_mac" ]; then
        _mac="$(router_ssh "arp -n $_ip 2>/dev/null | awk 'NR==2{print \$3}'" 2>/dev/null)"
    fi
    printf '%s' "$_mac"
}

reserve_entry() {
    _host="$1"
    _mac="$2"
    _ip="$3"

    case "$_mac" in
        *:*:*:*:*:*) ;;
        *)
            log_warn "MAC inválida para $_host ($_ip): $_mac — se omite"
            return 1
            ;;
    esac

    router_ssh "
        EXISTING_IDX=''
        IDX=0
        while uci get dhcp.@host[\$IDX] > /dev/null 2>&1; do
            CUR_IP=\$(uci get dhcp.@host[\$IDX].ip 2>/dev/null)
            CUR_MAC=\$(uci get dhcp.@host[\$IDX].mac 2>/dev/null)
            if [ \"\$CUR_IP\" = '$_ip' ] || [ \"\$CUR_MAC\" = '$_mac' ]; then
                EXISTING_IDX=\$IDX
                break
            fi
            IDX=\$((IDX + 1))
        done

        if [ -n \"\$EXISTING_IDX\" ]; then
            uci set dhcp.@host[\$EXISTING_IDX].name='$_host'
            uci set dhcp.@host[\$EXISTING_IDX].mac='$_mac'
            uci set dhcp.@host[\$EXISTING_IDX].ip='$_ip'
            uci set dhcp.@host[\$EXISTING_IDX].leasetime='infinite'
        else
            uci add dhcp host >/dev/null
            uci set dhcp.@host[-1].name='$_host'
            uci set dhcp.@host[-1].mac='$_mac'
            uci set dhcp.@host[-1].ip='$_ip'
            uci set dhcp.@host[-1].leasetime='infinite'
        fi
        uci commit dhcp
    " >/dev/null 2>&1
}

# =============================================================================
# Modo batch automático (sin --auto/--mac/--ip)
# Reserva solo equipos detectables en red y omite el resto.
# =============================================================================
if [ "$AUTO_MODE" -eq 0 ] && [ -z "$MANUAL_MAC" ] && [ "$EXPLICIT_IP" -eq 0 ]; then
    log_info "--- MODO BATCH: Reservando solo dispositivos detectados en red ---"
    RESERVED=0
    SKIPPED=0

    while IFS='|' read -r _host _ip; do
        [ -n "$_host" ] || continue
        validate_ip "$_ip" || { log_warn "$_host IP inválida ($_ip) — omitido"; SKIPPED=$((SKIPPED + 1)); continue; }
        _mac="$(detect_mac_router "$_ip")"
        if [ -z "$_mac" ] || [ "$_mac" = "FAILED" ]; then
            log_warn "$_host ($_ip) sin MAC detectable — omitido"
            SKIPPED=$((SKIPPED + 1))
            continue
        fi
        if reserve_entry "$_host" "$_mac" "$_ip"; then
            log_ok "Reserva aplicada: $_host  $_mac → $_ip"
            RESERVED=$((RESERVED + 1))
        else
            log_warn "No se pudo reservar $_host ($_ip) — omitido"
            SKIPPED=$((SKIPPED + 1))
        fi
    done <<EOF
$RASPI4B_HOSTNAME|$RASPI4B_IP
$RASPI3B_HOSTNAME|$RASPI3B_IP
$PORTAL_NODE_HOSTNAME|$PORTAL_NODE_IP
$AP_EXTENDER_HOSTNAME|$AP_EXTENDER_IP
EOF

    router_ssh "/etc/init.d/dnsmasq reload 2>/dev/null || /etc/init.d/dnsmasq restart" >/dev/null 2>&1 || true
    log_ok "Batch terminado. Reservadas: $RESERVED | Omitidas: $SKIPPED"
    if [ "$RESERVED" -eq 0 ]; then
        die "No se pudo reservar ninguna IP (ningún equipo detectable en red)."
    fi
    exit 0
fi

# =============================================================================
# PASO 1: Obtener la MAC
# =============================================================================
log_info "--- PASO 1: Obteniendo MAC para la IP $RASPI_IP ---"

if [ "$AUTO_MODE" -eq 1 ]; then
    # -------------------------------------------------------------------------
    # Modo AUTO: leer la MAC de la interfaz de red local de esta misma máquina.
    # Intentamos eth0, eth1 y wlan0 en ese orden; tomamos la primera que tenga
    # una dirección MAC real (no la loopback 00:00:00:00:00:00).
    # -------------------------------------------------------------------------
    log_info "Modo --auto: detectando MAC desde interfaces locales..."

    for IFACE in eth0 eth1 enp3s0 wlan0 wlan1; do
        CANDIDATE=$(ip link show "$IFACE" 2>/dev/null \
            | awk '/ether/{print $2}' | head -1)
        # Descartar MACs vacías o loopback
        case "$CANDIDATE" in
            ""| "00:00:00:00:00:00") continue ;;
        esac
        RASPI_MAC="$CANDIDATE"
        log_ok "MAC obtenida de interfaz $IFACE: $RASPI_MAC"
        break
    done

    # Fallback: cualquier interfaz ethernet activa
    if [ -z "$RASPI_MAC" ]; then
        log_warn "No se encontró eth0/eth1/wlan0 — buscando cualquier interfaz con MAC..."
        RASPI_MAC=$(ip link show 2>/dev/null \
            | awk '/ether/{print $2}' | grep -v '^00:00:00:00:00:00' | head -1)
        [ -n "$RASPI_MAC" ] && log_ok "MAC obtenida de interfaz desconocida: $RASPI_MAC"
    fi

    if [ -z "$RASPI_MAC" ]; then
        die "No se pudo detectar ninguna MAC local.
  Verifica con: ip link show
  O usa: sh $0 --mac TU:MAC:AQ:UI"
    fi

elif [ -n "$MANUAL_MAC" ]; then
    # -------------------------------------------------------------------------
    # MAC proporcionada explícitamente
    # -------------------------------------------------------------------------
    RASPI_MAC="$MANUAL_MAC"
    log_info "MAC proporcionada manualmente: $RASPI_MAC"

else
    # -------------------------------------------------------------------------
    # Modo legacy: consultar la tabla ARP/leases del router
    # -------------------------------------------------------------------------
    log_info "Detectando MAC desde el router (ARP/leases)..."

    RASPI_MAC=$(detect_mac_router "$RASPI_IP")

    if [ -z "$RASPI_MAC" ]; then
        die "No se pudo detectar la MAC de $RASPI_IP desde el router.
  Opciones:
    1. Ejecuta desde la Pi con: sh $0 --auto $RASPI_IP
    2. Pasa la MAC manualmente: sh $0 --mac AA:BB:CC:DD:EE:FF
    3. Consulta la MAC en la Pi: ip link show eth0 | awk '/ether/{print \$2}'"
    fi
fi

# Validar formato MAC (XX:XX:XX:XX:XX:XX)
case "$RASPI_MAC" in
    *:*:*:*:*:*) log_ok "MAC a reservar: $RASPI_MAC → $RASPI_IP" ;;
    *) die "Formato de MAC inválido: '$RASPI_MAC' (esperado XX:XX:XX:XX:XX:XX)" ;;
esac

# =============================================================================
# PASO 2: Verificar reservas existentes — detectar conflictos
# =============================================================================
log_info "--- PASO 2: Verificando reservas existentes ---"

EXISTING_BY_IP=$(router_ssh \
    "uci show dhcp 2>/dev/null | grep -i \"ip='$RASPI_IP'\"" 2>/dev/null)
EXISTING_BY_MAC=$(router_ssh \
    "uci show dhcp 2>/dev/null | grep -i \"mac='$RASPI_MAC'\"" 2>/dev/null)

if [ -n "$EXISTING_BY_IP" ] || [ -n "$EXISTING_BY_MAC" ]; then
    log_warn "Ya existe una reserva DHCP relacionada:"
    [ -n "$EXISTING_BY_IP" ]  && printf '  Por IP:  %s\n' "$EXISTING_BY_IP"
    [ -n "$EXISTING_BY_MAC" ] && printf '  Por MAC: %s\n' "$EXISTING_BY_MAC"

    # Detectar conflicto: IP reservada para MAC distinta
    if [ -n "$EXISTING_BY_IP" ]; then
        RESERVED_MAC=$(router_ssh \
            "uci show dhcp 2>/dev/null | grep -A5 \"ip='$RASPI_IP'\" | grep mac | head -1" \
            2>/dev/null | grep -oE "([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}")
        if [ -n "$RESERVED_MAC" ] && [ "$RESERVED_MAC" != "$RASPI_MAC" ]; then
            die "CONFLICTO: La IP $RASPI_IP ya está reservada para otra MAC: $RESERVED_MAC
  La MAC de esta Pi es: $RASPI_MAC
  Revisar manualmente: ssh root@$ROUTER_IP 'uci show dhcp'
  Para forzar: elimina la reserva existente primero."
        fi
    fi

    log_info "La reserva ya apunta a $RASPI_MAC — actualizando para garantizar configuración..."
else
    log_info "No hay reservas previas para $RASPI_IP ni para $RASPI_MAC — se creará una nueva."
fi

# =============================================================================
# PASO 3: Crear / actualizar la reserva DHCP estática via UCI
# =============================================================================
log_info "--- PASO 3: Configurando reserva DHCP estática ---"

router_ssh "
    # Buscar índice existente por IP o MAC para reusar la entrada
    EXISTING_IDX=''
    IDX=0
    while uci get dhcp.@host[\$IDX] > /dev/null 2>&1; do
        CUR_IP=\$(uci get dhcp.@host[\$IDX].ip 2>/dev/null)
        CUR_MAC=\$(uci get dhcp.@host[\$IDX].mac 2>/dev/null)
        if [ \"\$CUR_IP\" = '$RASPI_IP' ] || [ \"\$CUR_MAC\" = '$RASPI_MAC' ]; then
            EXISTING_IDX=\$IDX
            break
        fi
        IDX=\$((IDX + 1))
    done

    if [ -n \"\$EXISTING_IDX\" ]; then
        echo \"Actualizando reserva existente en índice \$EXISTING_IDX...\"
        uci set dhcp.@host[\$EXISTING_IDX].name='$RASPI_HOSTNAME'
        uci set dhcp.@host[\$EXISTING_IDX].mac='$RASPI_MAC'
        uci set dhcp.@host[\$EXISTING_IDX].ip='$RASPI_IP'
        uci set dhcp.@host[\$EXISTING_IDX].leasetime='infinite'
    else
        echo 'Creando nueva reserva DHCP...'
        uci add dhcp host
        uci set dhcp.@host[-1].name='$RASPI_HOSTNAME'
        uci set dhcp.@host[-1].mac='$RASPI_MAC'
        uci set dhcp.@host[-1].ip='$RASPI_IP'
        uci set dhcp.@host[-1].leasetime='infinite'
    fi

    uci commit dhcp
    echo 'UCI commit OK'
" || die "Falló la configuración de la reserva DHCP via UCI"

log_ok "Reserva DHCP configurada: $RASPI_HOSTNAME  $RASPI_MAC → $RASPI_IP  (leasetime=infinite)"

# =============================================================================
# PASO 4: Verificar configuración DNS
# =============================================================================
log_info "--- PASO 4: Verificando configuración DNS ---"

# La Pi NO actúa como servidor DNS. El router (dnsmasq) resuelve los dominios
# de detección de captive portal y los redirige a la Pi. Los clientes WiFi
# deben usar el router como DNS — que es el comportamiento por defecto en OpenWrt.

DNS_OPTION=$(router_ssh \
    "uci show dhcp 2>/dev/null | grep 'dhcp_option' | grep -i '6,'" 2>/dev/null)

if [ -n "$DNS_OPTION" ]; then
    log_info "DHCP option 6 (DNS) configurada: $DNS_OPTION"
    if ! printf '%s' "$DNS_OPTION" | grep -q "$ROUTER_IP"; then
        log_warn "DHCP option 6 no apunta al router ($ROUTER_IP) — los clientes pueden usar otro DNS"
        log_warn "Para corregir: ssh root@$ROUTER_IP 'uci del dhcp.lan.dhcp_option && uci commit dhcp'"
    fi
else
    log_info "Sin DHCP option 6 explícita — dnsmasq asignará el router ($ROUTER_IP) como DNS por defecto"
    log_info "(comportamiento correcto para el captive portal)"
fi

# =============================================================================
# PASO 5: Recargar dnsmasq para aplicar la reserva
# =============================================================================
log_info "--- PASO 5: Recargando dnsmasq ---"

router_ssh "/etc/init.d/dnsmasq reload 2>/dev/null || /etc/init.d/dnsmasq restart" \
    && log_ok "dnsmasq recargado" \
    || log_warn "No se pudo recargar dnsmasq — la reserva se aplicará en el próximo lease"

# =============================================================================
# PASO 6: Verificación final
# =============================================================================
log_info "--- PASO 6: Verificación ---"

log_info "Reservas DHCP estáticas en el router:"
router_ssh "
    IDX=0
    printf '  %-20s  %-20s  %-16s  %s\n' NOMBRE MAC IP LEASETIME
    printf '  %-20s  %-20s  %-16s  %s\n' '--------------------' '--------------------' '----------------' '---------'
    while uci get dhcp.@host[\$IDX] > /dev/null 2>&1; do
        NAME=\$(uci get dhcp.@host[\$IDX].name 2>/dev/null || echo '-')
        MAC=\$(uci get dhcp.@host[\$IDX].mac 2>/dev/null || echo '-')
        IP=\$(uci get dhcp.@host[\$IDX].ip 2>/dev/null || echo '-')
        LEASE=\$(uci get dhcp.@host[\$IDX].leasetime 2>/dev/null || echo '-')
        printf '  %-20s  %-20s  %-16s  %s\n' \"\$NAME\" \"\$MAC\" \"\$IP\" \"\$LEASE\"
        IDX=\$((IDX + 1))
    done
" 2>/dev/null

VERIFY=$(router_ssh \
    "uci show dhcp 2>/dev/null | grep -c \"ip='$RASPI_IP'\"" 2>/dev/null || echo "0")

if [ "$VERIFY" -gt 0 ]; then
    log_ok "Reserva verificada en UCI"
else
    log_warn "No se pudo verificar la reserva — revisar: ssh root@$ROUTER_IP 'uci show dhcp'"
fi

# =============================================================================
# Resumen
# =============================================================================
printf '\n'
log_ok "=== Reserva DHCP permanente configurada ==="
printf '\n'
printf '  Hostname:   %s\n' "$RASPI_HOSTNAME"
printf '  MAC:        %s\n' "$RASPI_MAC"
printf '  IP:         %s (permanente)\n' "$RASPI_IP"
printf '  Leasetime:  infinite\n'
printf '  Modo:       %s\n' "$([ "$AUTO_MODE" -eq 1 ] && echo 'auto (MAC local)' || echo 'manual/router')"
printf '\n'
log_info "Esta máquina siempre obtendrá $RASPI_IP al conectarse al router."
log_info "Todos los scripts y manifiestos k8s seguirán funcionando sin cambios."
