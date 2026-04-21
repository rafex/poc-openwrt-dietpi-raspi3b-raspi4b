#!/bin/sh
# openwrt-reserve-raspi.sh — Reserva permanente de IP para la Raspberry Pi en OpenWrt
#
# Uso:
#   sh scripts/openwrt-reserve-raspi.sh
#   sh scripts/openwrt-reserve-raspi.sh --mac AA:BB:CC:DD:EE:FF  # MAC manual
#
# Qué hace:
#   1. Detecta la MAC de la Pi desde el ARP del router (o la recibe por argumento)
#   2. Valida que la IP 192.168.1.167 no esté ya reservada a otra MAC
#   3. Crea una reserva DHCP estática permanente via UCI (leasetime=infinite)
#   4. Configura dnsmasq para que los clientes WiFi usen el router como DNS
#      (el router ya redirige los dominios de captive portal a la Pi)
#   5. Reinicia dnsmasq
#
# Por qué es necesario:
#   Todos los scripts y manifiestos k8s usan 192.168.1.167 como IP fija de la Pi.
#   Sin esta reserva, si la Pi se reinicia podría obtener otra IP y todo el
#   captive portal dejaría de funcionar.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

# Constantes
RASPI_HOSTNAME="RafexPi"
RASPI_IP="$PORTAL_IP"       # 192.168.1.167 (de common.sh)
MANUAL_MAC=""

# =============================================================================
# Argumentos
# =============================================================================
while [ $# -gt 0 ]; do
    case "$1" in
        --mac)
            shift
            MANUAL_MAC="$1"
            ;;
        --mac=*)
            MANUAL_MAC="${1#--mac=}"
            ;;
        --help|-h)
            sed -n '2,18p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            die "Argumento desconocido: '$1'"
            ;;
    esac
    shift
done

# =============================================================================
# Pre-flight
# =============================================================================
check_ssh_key
test_router_ssh

# =============================================================================
# PASO 1: Obtener la MAC de la Pi
# =============================================================================
log_info "--- PASO 1: Obteniendo MAC de la Pi ($RASPI_IP) ---"

if [ -n "$MANUAL_MAC" ]; then
    RASPI_MAC="$MANUAL_MAC"
    log_info "MAC proporcionada manualmente: $RASPI_MAC"
else
    # Intentar desde la tabla ARP del router (más fiable — la Pi habla con el router)
    RASPI_MAC=$(router_ssh \
        "ip neigh show $RASPI_IP 2>/dev/null | awk '{print \$5}' | head -1" 2>/dev/null)

    # Fallback: buscar en /tmp/dhcp.leases (solo si la Pi usa DHCP)
    if [ -z "$RASPI_MAC" ] || [ "$RASPI_MAC" = "FAILED" ]; then
        log_warn "ARP no devolvió resultado — buscando en /tmp/dhcp.leases..."
        RASPI_MAC=$(router_ssh \
            "awk '\$3==\"$RASPI_IP\" {print \$2}' /tmp/dhcp.leases 2>/dev/null | head -1" \
            2>/dev/null)
    fi

    # Fallback 2: arp -n
    if [ -z "$RASPI_MAC" ]; then
        log_warn "dhcp.leases sin resultado — intentando arp -n..."
        RASPI_MAC=$(router_ssh \
            "arp -n $RASPI_IP 2>/dev/null | awk 'NR==2{print \$3}'" 2>/dev/null)
    fi
fi

# Validar formato MAC (XX:XX:XX:XX:XX:XX)
if [ -z "$RASPI_MAC" ]; then
    die "No se pudo detectar la MAC de $RASPI_IP.
  Opciones:
    1. Asegúrate de que la Pi está encendida y conectada al router
    2. Proporciona la MAC manualmente:
       sh $0 --mac AA:BB:CC:DD:EE:FF
    3. Para ver la MAC en la Pi:
       ip link show eth0 | awk '/ether/{print \$2}'"
fi

case "$RASPI_MAC" in
    *:*:*:*:*:*) log_ok "MAC detectada: $RASPI_MAC" ;;
    *) die "Formato de MAC inválido: '$RASPI_MAC' (esperado XX:XX:XX:XX:XX:XX)" ;;
esac

# =============================================================================
# PASO 2: Verificar si ya existe una reserva para esta IP o MAC
# =============================================================================
log_info "--- PASO 2: Verificando reservas existentes ---"

# Listar todas las reservas DHCP en el router via UCI
EXISTING_BY_IP=$(router_ssh \
    "uci show dhcp 2>/dev/null | grep -i \"ip='$RASPI_IP'\"" 2>/dev/null)
EXISTING_BY_MAC=$(router_ssh \
    "uci show dhcp 2>/dev/null | grep -i \"mac='$RASPI_MAC'\"" 2>/dev/null)

if [ -n "$EXISTING_BY_IP" ] || [ -n "$EXISTING_BY_MAC" ]; then
    log_warn "Ya existe una reserva DHCP relacionada:"
    [ -n "$EXISTING_BY_IP" ]  && printf '  Por IP:  %s\n' "$EXISTING_BY_IP"
    [ -n "$EXISTING_BY_MAC" ] && printf '  Por MAC: %s\n' "$EXISTING_BY_MAC"

    # Verificar si apunta a la MAC correcta
    if [ -n "$EXISTING_BY_IP" ]; then
        RESERVED_MAC=$(router_ssh \
            "uci show dhcp 2>/dev/null | grep -A5 \"ip='$RASPI_IP'\" | grep mac | head -1" \
            2>/dev/null | grep -oE "([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}")
        if [ -n "$RESERVED_MAC" ] && [ "$RESERVED_MAC" != "$RASPI_MAC" ]; then
            die "La IP $RASPI_IP ya está reservada para otra MAC: $RESERVED_MAC
  La MAC de la Pi es: $RASPI_MAC
  Conflicto — revisar manualmente: ssh root@$ROUTER_IP 'uci show dhcp'"
        fi
    fi

    log_info "La reserva ya apunta correctamente a $RASPI_MAC — actualizando para garantizar configuración..."
fi

# =============================================================================
# PASO 3: Crear / actualizar la reserva DHCP estática
# =============================================================================
log_info "--- PASO 3: Configurando reserva DHCP estática ---"

# En OpenWrt, las reservas DHCP se gestionan via UCI como dhcp.@host[N]
# Si ya existe una entrada con esta IP o MAC la reusamos; si no, añadimos una nueva.
router_ssh "
    # Buscar índice existente por IP o MAC
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

log_ok "Reserva DHCP creada: $RASPI_HOSTNAME  $RASPI_MAC → $RASPI_IP (leasetime=infinite)"

# =============================================================================
# PASO 4: Verificar que dnsmasq está configurado como DNS local
# =============================================================================
log_info "--- PASO 4: Verificando configuración DNS ---"

# En OpenWrt, dnsmasq ya es el servidor DNS de los clientes por defecto.
# Verificar que DHCP option 6 (DNS) apunta al router (no a la Pi directamente).
# La Pi NO es servidor DNS — el router hace la redirección de dominios de captive portal.

DNS_OPTION=$(router_ssh \
    "uci show dhcp 2>/dev/null | grep 'dhcp_option' | grep -i '6,'" 2>/dev/null)

if [ -n "$DNS_OPTION" ]; then
    log_info "DHCP option 6 (DNS) ya configurada: $DNS_OPTION"
    # Advertir si apunta a algo que no sea el router
    if ! printf '%s' "$DNS_OPTION" | grep -q "$ROUTER_IP"; then
        log_warn "DHCP option 6 no apunta al router ($ROUTER_IP) — los clientes pueden usar otro DNS"
    fi
else
    log_info "Sin DHCP option 6 explícita — los clientes usarán el router ($ROUTER_IP) como DNS por defecto"
    log_info "(comportamiento correcto: dnsmasq en el router resuelve y redirige dominios de captive portal)"
fi

# =============================================================================
# PASO 5: Reiniciar dnsmasq para aplicar la reserva
# =============================================================================
log_info "--- PASO 5: Reiniciando dnsmasq ---"

router_ssh "/etc/init.d/dnsmasq reload 2>/dev/null || /etc/init.d/dnsmasq restart" \
    && log_ok "dnsmasq reiniciado" \
    || log_warn "No se pudo recargar dnsmasq automáticamente"

# =============================================================================
# PASO 6: Verificación final
# =============================================================================
log_info "--- PASO 6: Verificación ---"

# Mostrar la reserva creada
log_info "Reservas DHCP actuales en el router:"
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

# Verificar que la reserva quedó guardada correctamente
VERIFY=$(router_ssh \
    "uci show dhcp 2>/dev/null | grep -c \"ip='$RASPI_IP'\"" 2>/dev/null || echo "0")

if [ "$VERIFY" -gt 0 ]; then
    log_ok "Reserva verificada en UCI"
else
    log_warn "No se pudo verificar la reserva en UCI — revisar manualmente:"
    log_warn "  ssh root@$ROUTER_IP 'uci show dhcp'"
fi

# =============================================================================
# Resumen
# =============================================================================
printf '\n'
log_ok "=== Reserva DHCP configurada ==="
printf '\n'
printf '  Hostname:   %s\n' "$RASPI_HOSTNAME"
printf '  MAC:        %s\n' "$RASPI_MAC"
printf '  IP:         %s (permanente)\n' "$RASPI_IP"
printf '  Leasetime:  infinite\n'
printf '\n'
log_info "La Pi siempre obtendrá $RASPI_IP al conectarse al router."
log_info "Todos los scripts y manifiestos k8s siguen funcionando sin cambios."
