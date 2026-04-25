#!/bin/sh
# setup-openwrt.sh — Configura el router OpenWrt para el captive portal
# Idempotente: puede ejecutarse multiples veces sin efectos secundarios
#
# Uso:
#   sh scripts/setup-openwrt.sh
#   sh scripts/setup-openwrt.sh --topology legacy
#   sh scripts/setup-openwrt.sh --topology split_portal --portal-ip 192.168.1.182
#      (ejecutar desde la Raspberry Pi)
#
# Requisitos:
#   - /opt/keys/captive-portal.pub debe existir (generada por setup-raspi.sh)
#   - Conectividad de red entre la Pi y el router (192.168.1.1)
#
# SEGURIDAD:
#   - La IP 192.168.1.113 (admin) NUNCA sera bloqueada
#   - En caso de emergencia: ssh root@192.168.1.1 y ejecutar:
#       nft delete table ip captive
#
# Variables opcionales:
#   CAPTIVE_DOMAIN=captive.rafex.dev    # dominio principal del portal (DHCP opt114 + dnsmasq)
#   CAPTIVE_DOMAIN2=captive.localhost   # dominio secundario (fallback offline)
#   PEOPLE_DOMAIN=people.localhost.com  # subdominio para dashboard de registros/conectados
#   TOPOLOGY_FILE=/etc/demo-openwrt/topology.env

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Logging global a archivo + consola
SCRIPT_NAME="$(basename "$0" .sh)"
DEFAULT_LOG_DIR="/var/log/demo-openwrt/setup"
if mkdir -p "$DEFAULT_LOG_DIR" 2>/dev/null && [ -w "$DEFAULT_LOG_DIR" ]; then
    LOG_DIR="${LOG_DIR:-$DEFAULT_LOG_DIR}"
else
    DEFAULT_LOG_DIR="/tmp/demo-openwrt/setup"
    mkdir -p "$DEFAULT_LOG_DIR" 2>/dev/null || true
    LOG_DIR="${LOG_DIR:-$DEFAULT_LOG_DIR}"
fi
mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR="/tmp/demo-openwrt/setup"
mkdir -p "$LOG_DIR"
TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
LOG_FILE="$LOG_DIR/${SCRIPT_NAME}-${TIMESTAMP}.log"

if [ -z "${SETUP_LOG_INITIALIZED:-}" ]; then
    SETUP_LOG_INITIALIZED=1
    export SETUP_LOG_INITIALIZED
    if command -v tee >/dev/null 2>&1 && command -v mkfifo >/dev/null 2>&1; then
        LOG_PIPE="/tmp/${SCRIPT_NAME}-$$.logpipe"
        mkfifo "$LOG_PIPE"
        tee -a "$LOG_FILE" < "$LOG_PIPE" &
        LOG_TEE_PID=$!
        exec > "$LOG_PIPE" 2>&1
        cleanup_setup_logging() {
            rc=$?
            trap - EXIT INT TERM
            exec 1>&- 2>&-
            wait "$LOG_TEE_PID" 2>/dev/null || true
            rm -f "$LOG_PIPE"
            exit "$rc"
        }
        trap cleanup_setup_logging EXIT INT TERM
    else
        exec >> "$LOG_FILE" 2>&1
    fi
fi
printf '[INFO]  Log file: %s\n' "$LOG_FILE"

. "$SCRIPT_DIR/lib/common.sh"

print_usage() {
    cat <<EOF
Uso:
  sh scripts/setup-openwrt.sh [opciones]

Opciones:
  --topology legacy|split_portal   Selecciona topología.
  --portal-ip <ip>                 Fuerza IP de destino del portal.
  --ai-ip <ip>                     IP del nodo IA (Raspi4B normalmente).
  -h, --help                       Muestra esta ayuda.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --topology)
            [ -n "${2:-}" ] || die "Falta valor para --topology"
            TOPOLOGY="$2"
            shift 2
            ;;
        --portal-ip)
            [ -n "${2:-}" ] || die "Falta valor para --portal-ip"
            PORTAL_IP="$2"
            shift 2
            ;;
        --ai-ip)
            [ -n "${2:-}" ] || die "Falta valor para --ai-ip"
            AI_IP="$2"
            shift 2
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        *)
            die "Argumento no soportado: $1"
            ;;
    esac
done

case "$TOPOLOGY" in
    legacy|split_portal) ;;
    *) die "TOPOLOGY inválida: $TOPOLOGY (usar legacy|split_portal)" ;;
esac

if [ "$TOPOLOGY" = "split_portal" ] && [ -z "${PORTAL_IP:-}" ]; then
    PORTAL_IP="$PORTAL_NODE_IP"
fi
AI_IP="${AI_IP:-$RASPI4B_IP}"

validate_ip "$PORTAL_IP" || die "IP de portal inválida: $PORTAL_IP"
validate_ip "$AI_IP" || die "IP de AI inválida: $AI_IP"

CAPTIVE_DOMAIN="${CAPTIVE_DOMAIN:-captive.rafex.dev}"
CAPTIVE_DOMAIN2="${CAPTIVE_DOMAIN2:-captive.localhost}"
PEOPLE_DOMAIN="${PEOPLE_DOMAIN:-people.localhost.com}"

# =============================================================================
# Pre-flight checks
# =============================================================================
log_info "=== Setup de OpenWrt para Captive Portal ==="
log_info "Topología: $TOPOLOGY (portal_ip=$PORTAL_IP ai_ip=$AI_IP)"

check_ssh_key
test_router_ssh

# Verificar espacio disponible en el overlay del router (~840KB total)
log_info "Verificando espacio disponible en overlay del router..."
AVAIL_KB=$(router_ssh "df /overlay 2>/dev/null | awk 'NR==2{print \$4}'" 2>/dev/null || echo "0")
if [ -n "$AVAIL_KB" ] && [ "$AVAIL_KB" -lt 5 ] 2>/dev/null; then
    die "Espacio insuficiente en overlay del router: ${AVAIL_KB}KB disponibles (necesario: ~5KB)"
fi
log_ok "Espacio disponible en overlay: ${AVAIL_KB}KB"

# Verificar que la interfaz AP existe en el router
log_info "Verificando interfaz $AP_IFACE en el router..."
if ! router_ssh "ip link show $AP_IFACE > /dev/null 2>&1"; then
    log_warn "Interfaz $AP_IFACE no encontrada. Interfaces disponibles:"
    router_ssh "ip link show | grep -E '^[0-9]+:' | awk '{print \$2}'"
    die "Ajusta AP_IFACE en lib/common.sh con el nombre correcto de la interfaz AP WiFi"
fi
log_ok "Interfaz $AP_IFACE presente en el router"

# =============================================================================
# FASE A: Llave SSH en el router
# =============================================================================
log_info "--- FASE A: Configurando llave SSH en el router ---"

PUB_KEY="$(cat "$SSH_KEY_PUB")"

# Verificar si la llave ya esta en authorized_keys (busqueda literal)
KEY_EXISTS=0
router_ssh "grep -qF '$PUB_KEY' /etc/dropbear/authorized_keys 2>/dev/null" && KEY_EXISTS=1

if [ "$KEY_EXISTS" -eq 0 ]; then
    log_info "Agregando llave SSH publica al router..."
    # Crear el archivo si no existe
    router_ssh "mkdir -p /etc/dropbear && touch /etc/dropbear/authorized_keys && chmod 600 /etc/dropbear/authorized_keys"
    # Agregar la llave (usando printf para evitar problemas con caracteres especiales)
    router_ssh "printf '%s\n' '$PUB_KEY' >> /etc/dropbear/authorized_keys"
    # Verificar que se agrego
    router_ssh "grep -qF '$PUB_KEY' /etc/dropbear/authorized_keys" || \
        die "No se pudo agregar la llave SSH al router"
    log_ok "Llave SSH agregada a /etc/dropbear/authorized_keys"
else
    log_info "Llave SSH ya esta en el router (skip)"
fi

# =============================================================================
# FASE B: Configuracion dnsmasq
# =============================================================================
log_info "--- FASE B: Configurando dnsmasq para captive portal ---"

# Contenido del archivo de configuracion dnsmasq
# Dominios que los SO usan para detectar captive portals +
# dominios de demo de DNS poisoning (suplantacion educativa)
DNSMASQ_CONTENT="# captive-portal.conf — Generado por setup-openwrt.sh
# Redirige dominios de deteccion de captive portal a la Pi ($PORTAL_IP)
# Orden: primero las marcas con mayor presencia en la demo.

# ── Android AOSP / Google (Pixel, la mayoria de marcas Android) ─────────────
address=/connectivitycheck.gstatic.com/$PORTAL_IP
address=/connectivitycheck.android.com/$PORTAL_IP
address=/clients1.google.com/$PORTAL_IP
address=/clients3.google.com/$PORTAL_IP

# ── Huawei EMUI / HarmonyOS ──────────────────────────────────────────────────
# Estos dominios son los que usan los Huawei para su deteccion propia de portal.
# Sin estas entradas dnsmasq no intercepta el check y la notificacion no aparece
# aunque el DNAT de nftables redirige el trafico HTTP igualmente.
address=/connectivitycheck.platform.hicloud.com/$PORTAL_IP
address=/connectivitycheck.hicloud.com/$PORTAL_IP
address=/connectivitycheck.dbankcloud.cn/$PORTAL_IP

# ── Xiaomi MIUI / HyperOS ────────────────────────────────────────────────────
address=/connect.rom.miui.com/$PORTAL_IP
address=/connectivitycheck.platform.miui.com/$PORTAL_IP
address=/wifi.vivo.com.cn/$PORTAL_IP

# ── Samsung OneUI ────────────────────────────────────────────────────────────
address=/connectivitycheck.samsung.com/$PORTAL_IP
address=/google.com/$PORTAL_IP

# ── Apple iOS / macOS (CaptiveNetworkSupport) ────────────────────────────────
address=/captive.apple.com/$PORTAL_IP
address=/appleiphonecell.com/$PORTAL_IP
address=/iphone-otu.apple.com/$PORTAL_IP
address=/www.apple.com/$PORTAL_IP

# ── Microsoft Windows (NCSI / NCA) ───────────────────────────────────────────
address=/www.msftconnecttest.com/$PORTAL_IP
address=/msftconnecttest.com/$PORTAL_IP
address=/www.msftncsi.com/$PORTAL_IP
address=/msftncsi.com/$PORTAL_IP

# ── Mozilla Firefox ──────────────────────────────────────────────────────────
address=/detectportal.firefox.com/$PORTAL_IP

# ── Ubuntu / Canonical ───────────────────────────────────────────────────────
address=/connectivity-check.ubuntu.com/$PORTAL_IP

# ── Linux / GNOME / Debian ───────────────────────────────────────────────────
address=/network-test.debian.org/$PORTAL_IP
address=/nmcheck.gnome.org/$PORTAL_IP

# ── Dominios propios del portal (acceso manual y DHCP option 114) ────────────
# captive.rafex.dev  — URL pública de la demo (fácil de comunicar a asistentes)
# captive.localhost  — fallback sin dominio externo (funciona offline)
address=/$CAPTIVE_DOMAIN/$PORTAL_IP
address=/$CAPTIVE_DOMAIN2/$PORTAL_IP
address=/$PEOPLE_DOMAIN/$PORTAL_IP

"

# Forzar bloque en /etc/dnsmasq.conf (siempre leído por dnsmasq en OpenWrt)
# y limpiar archivo legado para evitar duplicados.
log_info "Aplicando bloque captive en /etc/dnsmasq.conf..."
router_ssh "
    rm -f /etc/dnsmasq.d/captive-portal.conf 2>/dev/null || true
    if grep -q '# --- captive-portal begin ---' /etc/dnsmasq.conf 2>/dev/null; then
        sed -i '/# --- captive-portal begin ---/,/# --- captive-portal end ---/d' /etc/dnsmasq.conf
    fi
    printf '\n# --- captive-portal begin ---\n%s\n# --- captive-portal end ---\n' \
        '$DNSMASQ_CONTENT' >> /etc/dnsmasq.conf
"
log_ok "Configuracion captive insertada en /etc/dnsmasq.conf"

# Configurar DHCP lease time a 120 minutos via UCI
# Razon: al reconectar, el dispositivo obtiene nueva IP → no esta en allowed_clients → portal
# 120m coincide con el timeout del set nftables (PORTAL_TIMEOUT)
log_info "Configurando DHCP lease time a 120 minutos..."
router_ssh "
    uci set dhcp.lan.leasetime='120m'
    # Forzar DNS del router a clientes LAN (evita bypass DNS externo/DoH por DHCP)
    # Option 6  = DNS servers
    # Option 114 = Captive Portal URL (RFC 7710/8910)
    uci del dhcp.lan.dhcp_option 2>/dev/null || true
    uci add_list dhcp.lan.dhcp_option='6,$ROUTER_IP'
    # Option 114 (RFC 8910): URL del captive portal que el OS usa directamente.
    # Se usa el dominio propio (captive.rafex.dev) en lugar de la IP para que
    # la URL sea legible y coincida con lo que dnsmasq resuelve a $PORTAL_IP.
    uci add_list dhcp.lan.dhcp_option='114,http://$CAPTIVE_DOMAIN/portal'
    uci commit dhcp
" && log_ok "DHCP lease time = 120m configurado" || \
    log_warn "No se pudo configurar DHCP lease time via UCI (puede que la interfaz no se llame 'lan')"

# Recargar dnsmasq — aplica tanto la config de captive portal como el nuevo lease time
log_info "Recargando dnsmasq..."
router_ssh "/etc/init.d/dnsmasq reload 2>/dev/null || /etc/init.d/dnsmasq restart" || \
    log_warn "No se pudo recargar dnsmasq automaticamente"
log_ok "dnsmasq recargado"

# =============================================================================
# FASE C: Configuracion nftables
# =============================================================================
log_info "--- FASE C: Configurando nftables ---"

# Contenido del archivo nft
# IMPORTANTE: la tabla se elimina antes de aplicar este archivo (ver más abajo),
# por lo que solo necesitamos 'add table' + la definición completa.
# Esto garantiza idempotencia sin el error "File exists" que ocurre con flush table.
NFT_CONTENT="#!/usr/sbin/nft -f
# captive-portal.nft — Generado por setup-openwrt.sh
# Tabla de control de acceso para captive portal en OpenWrt 25.x
#
# NOTA DE DISEÑO:
#   Las reglas usan matching por IP de origen (ip saddr) en lugar de
#   interfaz (iifname), porque en OpenWrt los clientes WiFi pasan por el
#   bridge br-lan y el hook forward ve br-lan, no la interfaz AP (phy0-ap0).
#   Matching por subred LAN es más robusto y funciona con cualquier topología.
#
# SEGURIDAD: $ADMIN_IP (admin), $RASPI4B_IP (AI) y $PORTAL_IP (portal) NUNCA son bloqueadas.
# Para resetear: nft delete table ip captive

add table ip captive

table ip captive {
    # Set de clientes autorizados — IPs que pueden navegar libremente
    #
    # timeout 120m: las autorizaciones expiran solas (2 horas)
    #   → combinado con DHCP lease=120m: al reconectar pasan de nuevo por el portal
    #
    # Admin ($ADMIN_IP), IA ($RASPI4B_IP), sensor ($RASPI3B_IP), portal node ($PORTAL_NODE_IP),
    # AP extender ($AP_EXTENDER_IP) y portal activo ($PORTAL_IP):
    # timeout 0s = NUNCA expiran
    set $NFT_SET {
        type ipv4_addr
        flags dynamic, timeout
        timeout 120m
        elements = { $ADMIN_IP timeout 0s, $RASPI4B_IP timeout 0s, $RASPI3B_IP timeout 0s, $PORTAL_NODE_IP timeout 0s, $AP_EXTENDER_IP timeout 0s, $PORTAL_IP timeout 0s }
    }

    # Redireccion HTTP: clientes de la LAN no autorizados → portal en $PORTAL_IP
    # Matching por subred: funciona con WiFi (br-lan) y cualquier otro bridge
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;

        # No redirigir tráfico que ya va al portal
        ip daddr $PORTAL_IP accept

        # Clientes autorizados: no redirigir
        ip saddr @$NFT_SET accept

        # Redirigir HTTP de la LAN que no está autorizado al portal
        ip saddr $LAN_SUBNET tcp dport 80 dnat to $PORTAL_IP:80
    }

    # Control de forward: bloquear trafico de clientes no autorizados
    # priority filter - 1 = se evalua ANTES que las reglas de inet fw4
    chain forward_captive {
        type filter hook forward priority filter - 1; policy accept;

        # Tráfico que sale del router hacia internet (no LAN): no tocar
        ip saddr != $LAN_SUBNET accept

        # Admin: acceso total siempre (REGLA DE ORO — nunca bloquear)
        ip saddr $ADMIN_IP accept

        # AI node (Raspi4B): siempre permitido (topología legacy/split)
        ip saddr $RASPI4B_IP accept
        ip daddr $RASPI4B_IP accept

        # Portal node alterno (Raspi3B #2): siempre permitido
        ip saddr $PORTAL_NODE_IP accept
        ip daddr $PORTAL_NODE_IP accept

        # AP extender (no puede abrir portal): siempre permitido
        ip saddr $AP_EXTENDER_IP accept
        ip daddr $AP_EXTENDER_IP accept

        # Portal: siempre permitido en ambas direcciones
        ip saddr $PORTAL_IP accept
        ip daddr $PORTAL_IP accept

        # DHCP y DNS: necesarios para que los clientes obtengan IP y lleguen al portal
        udp dport { 67, 68 } accept
        tcp dport 53 accept
        udp dport 53 accept

        # Clientes autorizados: acceso total a internet
        ip saddr @$NFT_SET accept

        # Todo lo demás de la LAN sin autorización: bloquear
        ip saddr $LAN_SUBNET drop
    }
}
"

# Transferir el archivo al router
TMP_NFT="/tmp/captive-portal-$$.nft"
printf '%s' "$NFT_CONTENT" > "$TMP_NFT"

log_info "Transfiriendo configuracion nftables al router..."
router_ssh "cat > /tmp/captive-portal.nft" < "$TMP_NFT"
rm -f "$TMP_NFT"

# Validar sintaxis ANTES de aplicar.
# IMPORTANTE: el dry-run (-c) también falla con "File exists" si la tabla ya existe
# porque intenta recrear el set. Por eso eliminamos la tabla primero en un entorno
# temporal de validación, o simplemente confiamos en el archivo ya probado y
# validamos la sintaxis sobre una copia sin la tabla preexistente.
log_info "Validando sintaxis del archivo nft (dry-run)..."
router_ssh "
    # Crear una copia limpia para el dry-run: eliminar tabla si existe, luego validar
    nft delete table ip captive 2>/dev/null || true
    nft -c -f /tmp/captive-portal.nft
" || die "Error de sintaxis en el archivo nftables. Abortando."
log_ok "Sintaxis nftables validada"

# CRITICO: Aplicar reglas.
# La tabla fue eliminada en el paso anterior (dry-run), así que 'add table' del archivo
# la crea limpiamente. El admin queda fuera durante milisegundos — se re-agrega justo después.
log_info "Aplicando reglas nftables..."
router_ssh "nft -f /tmp/captive-portal.nft" || \
    die "Fallo al cargar las reglas nftables"

# CRITICO: Re-confirmar IPs permanentes (timeout 0s).
# Admin, portal y ambas Raspis nunca deben expirar — sin importar los reinicios.
log_info "Re-confirmando IPs permanentes en el set (timeout 0s)..."
router_ssh "nft add element $NFT_TABLE $NFT_SET { $ADMIN_IP timeout 0s }" || \
    die "No se pudo asegurar $ADMIN_IP como permanente"
router_ssh "nft add element $NFT_TABLE $NFT_SET { $RASPI4B_IP timeout 0s }" 2>/dev/null || true
router_ssh "nft add element $NFT_TABLE $NFT_SET { $RASPI3B_IP timeout 0s }" 2>/dev/null || true
router_ssh "nft add element $NFT_TABLE $NFT_SET { $PORTAL_NODE_IP timeout 0s }" 2>/dev/null || true
router_ssh "nft add element $NFT_TABLE $NFT_SET { $AP_EXTENDER_IP timeout 0s }" 2>/dev/null || true
router_ssh "nft add element $NFT_TABLE $NFT_SET { $PORTAL_IP timeout 0s }" 2>/dev/null || true
log_ok "Permanentes: admin=$ADMIN_IP ai/4B=$RASPI4B_IP sensor/3B=$RASPI3B_IP portal/3B2=$PORTAL_NODE_IP ap-ext=$AP_EXTENDER_IP portal-activo=$PORTAL_IP (timeout 0s)"

# Limpiar conntrack para que el bloqueo sea efectivo inmediatamente
# (conexiones ESTABLISHED bypasean el hook forward)
log_info "Limpiando conntrack..."
router_ssh "conntrack -F 2>/dev/null && echo 'conntrack flush OK' || echo 'conntrack no disponible (OK)'"

# Copiar el archivo a la ubicacion de persistencia (fuera de /etc/nftables.d para evitar parseo fw4)
log_info "Persistiendo configuracion nftables..."
router_ssh "cp /tmp/captive-portal.nft /etc/captive-portal.nft"
log_ok "Reglas persistidas en /etc/captive-portal.nft"
log_info "Registrando include UCI en fw4 para asegurar carga en reboot..."
router_ssh "
    # Limpiar includes legacy (anónimos o nombrados) que apunten al captive portal.
    # Nota: usar clave completa (ej. firewall.@include[0]) evita errores con [ ].
    for key in \$(uci -q show firewall 2>/dev/null | awk -F= '/=include$/{print \$1}'); do
        path=\$(uci -q get \"\$key.path\" 2>/dev/null || true)
        case \"\$path\" in
            */captive-portal.nft|*/captive-portal-fw4-include.sh)
                uci -q delete \"\$key\"
                ;;
        esac
    done

    # Borrar archivo legacy que fw4 auto-incluye y rompe por sintaxis top-level
    rm -f /etc/nftables.d/captive-portal.nft 2>/dev/null || true

    cat > /etc/captive-portal-fw4-include.sh <<'EOS'
#!/bin/sh
nft delete table ip captive 2>/dev/null || true
nft -f /etc/captive-portal.nft
exit \$?
EOS
    chmod 755 /etc/captive-portal-fw4-include.sh

    uci -q delete firewall.captive_portal_nft
    uci set firewall.captive_portal_nft='include'
    uci set firewall.captive_portal_nft.type='script'
    uci set firewall.captive_portal_nft.path='/etc/captive-portal-fw4-include.sh'
    uci set firewall.captive_portal_nft.enabled='1'
    uci commit firewall
" && log_ok "Include UCI firewall.captive_portal_nft configurado" || \
   log_warn "No se pudo registrar include UCI para captive-portal"

# Limpiar temporal del router
router_ssh "rm -f /tmp/captive-portal.nft"

# =============================================================================
# FASE C.1: Reservas DHCP permanentes para las Raspberry Pi
# =============================================================================
log_info "--- FASE C.1: Reservas DHCP permanentes para RafexPi4B y RafexPi3B ---"

# Función interna: crea o actualiza una reserva DHCP via UCI en el router
# Uso: reserve_raspi_dhcp <hostname> <mac> <ip>
reserve_raspi_dhcp() {
    local NAME="$1"
    local MAC="$2"
    local IP="$3"

    router_ssh "
        # Buscar entrada existente por IP o MAC (idempotente)
        EXISTING_IDX=''
        IDX=0
        while uci get dhcp.@host[\$IDX] > /dev/null 2>&1; do
            CUR_IP=\$(uci get dhcp.@host[\$IDX].ip 2>/dev/null)
            CUR_MAC=\$(uci get dhcp.@host[\$IDX].mac 2>/dev/null)
            if [ \"\$CUR_IP\" = '$IP' ] || [ \"\$CUR_MAC\" = '$MAC' ]; then
                EXISTING_IDX=\$IDX
                break
            fi
            IDX=\$((IDX + 1))
        done

        if [ -n \"\$EXISTING_IDX\" ]; then
            printf 'Actualizando reserva existente para $NAME (indice %s)\\n' \"\$EXISTING_IDX\"
            uci set dhcp.@host[\$EXISTING_IDX].name='$NAME'
            uci set dhcp.@host[\$EXISTING_IDX].mac='$MAC'
            uci set dhcp.@host[\$EXISTING_IDX].ip='$IP'
            uci set dhcp.@host[\$EXISTING_IDX].leasetime='infinite'
        else
            printf 'Creando nueva reserva DHCP para $NAME\\n'
            uci add dhcp host
            uci set dhcp.@host[-1].name='$NAME'
            uci set dhcp.@host[-1].mac='$MAC'
            uci set dhcp.@host[-1].ip='$IP'
            uci set dhcp.@host[-1].leasetime='infinite'
        fi
        uci commit dhcp
        printf 'OK\\n'
    " && log_ok "Reserva DHCP: $NAME  $MAC → $IP  (infinite)" || \
       log_warn "No se pudo configurar reserva DHCP para $NAME — hazlo manualmente con openwrt-reserve-raspi.sh"
}

reserve_raspi_dhcp "$RASPI4B_HOSTNAME" "$RASPI4B_MAC" "$RASPI4B_IP"
reserve_raspi_dhcp "$RASPI3B_HOSTNAME" "$RASPI3B_MAC" "$RASPI3B_IP"
if [ -n "$PORTAL_NODE_MAC" ] && validate_ip "$PORTAL_NODE_IP"; then
    reserve_raspi_dhcp "$PORTAL_NODE_HOSTNAME" "$PORTAL_NODE_MAC" "$PORTAL_NODE_IP"
else
    log_warn "PORTAL_NODE_MAC/IP no completos; no se creó reserva DHCP del portal node"
fi
if [ -n "$AP_EXTENDER_MAC" ] && validate_ip "$AP_EXTENDER_IP"; then
    reserve_raspi_dhcp "$AP_EXTENDER_HOSTNAME" "$AP_EXTENDER_MAC" "$AP_EXTENDER_IP"
else
    log_warn "AP_EXTENDER_MAC/IP no completos; no se creó reserva DHCP del AP extender"
fi

# Recargar dnsmasq para aplicar las nuevas reservas
log_info "Recargando dnsmasq para aplicar reservas DHCP..."
router_ssh "/etc/init.d/dnsmasq reload 2>/dev/null || /etc/init.d/dnsmasq restart" && \
    log_ok "dnsmasq recargado con reservas DHCP" || \
    log_warn "No se pudo recargar dnsmasq — las reservas se aplicarán en el próximo lease"

# Mostrar tabla de reservas activas
log_info "Reservas DHCP activas en el router:"
router_ssh "
    IDX=0
    printf '  %-20s  %-20s  %-16s  %s\n' NOMBRE MAC IP LEASETIME
    printf '  %-20s  %-20s  %-16s  %s\n' '--------------------' '--------------------' '----------------' '---------'
    while uci get dhcp.@host[\$IDX] > /dev/null 2>&1; do
        NAME=\$(uci get dhcp.@host[\$IDX].name 2>/dev/null || printf '-')
        MAC=\$(uci get dhcp.@host[\$IDX].mac 2>/dev/null || printf '-')
        IP=\$(uci get dhcp.@host[\$IDX].ip 2>/dev/null || printf '-')
        LEASE=\$(uci get dhcp.@host[\$IDX].leasetime 2>/dev/null || printf '-')
        printf '  %-20s  %-20s  %-16s  %s\n' \"\$NAME\" \"\$MAC\" \"\$IP\" \"\$LEASE\"
        IDX=\$((IDX + 1))
    done
" 2>/dev/null || log_warn "No se pudo listar las reservas DHCP"

# =============================================================================
# FASE D: Verificacion
# =============================================================================
log_info "--- FASE D: Verificando configuracion ---"

# Verificar tabla nftables
log_info "Verificando tabla nftables..."
router_ssh "nft list table $NFT_TABLE" | head -5
log_ok "Tabla $NFT_TABLE cargada"

# Verificar que admin esta en el set
if router_ip_in_set "$ADMIN_IP"; then
    log_ok "Admin $ADMIN_IP esta en $NFT_SET"
else
    log_warn "Admin $ADMIN_IP NO esta en $NFT_SET — agregando de emergencia..."
    router_add_ip "$ADMIN_IP"
fi

# Verificar dnsmasq — función helper para no repetir el nslookup
check_dns_redirect() {
    local domain="$1"
    local expected="$2"
    local resolved
    resolved=$(router_ssh "nslookup $domain 127.0.0.1 2>/dev/null | grep -Eo '([0-9]{1,3}\\.){3}[0-9]{1,3}' | tail -1" 2>/dev/null || echo "")
    if [ "$resolved" = "$expected" ]; then
        log_ok "dnsmasq: $domain -> $resolved"
    else
        log_warn "dnsmasq: $domain -> ${resolved:-sin respuesta} (esperado: $expected)"
    fi
}

log_info "Verificando dnsmasq (dominios de deteccion captive)..."
# Android / Google
check_dns_redirect "connectivitycheck.gstatic.com"          "$PORTAL_IP"
# Huawei EMUI / HarmonyOS
check_dns_redirect "connectivitycheck.platform.hicloud.com" "$PORTAL_IP"
check_dns_redirect "connectivitycheck.hicloud.com"          "$PORTAL_IP"
# Apple
check_dns_redirect "captive.apple.com"                      "$PORTAL_IP"
# Windows
check_dns_redirect "www.msftconnecttest.com"                "$PORTAL_IP"
# Firefox
check_dns_redirect "detectportal.firefox.com"              "$PORTAL_IP"

log_info "Verificando dominios propios del portal..."
check_dns_redirect "$CAPTIVE_DOMAIN"  "$PORTAL_IP"
check_dns_redirect "$CAPTIVE_DOMAIN2" "$PORTAL_IP"
check_dns_redirect "$PEOPLE_DOMAIN"   "$PORTAL_IP"

# Verificar DHCP option 114 (URL del portal)
log_info "Verificando DHCP option 114..."
OPT114="$(router_ssh "uci -q get dhcp.lan.dhcp_option 2>/dev/null | tr ' ' '\n' | grep '^114,' | tail -1" 2>/dev/null || echo "")"
if printf '%s' "$OPT114" | grep -q "114,http://$CAPTIVE_DOMAIN/portal"; then
    log_ok "DHCP option 114 correcta: $OPT114"
else
    log_warn "DHCP option 114 no coincide (actual: ${OPT114:-<vacía>}, esperado: 114,http://$CAPTIVE_DOMAIN/portal)"
fi

# Verificar regla DNAT hacia portal
log_info "Verificando regla DNAT hacia portal..."
DNAT_RULE="$(router_ssh "nft list chain ip captive prerouting 2>/dev/null | grep -F 'dnat to $PORTAL_IP:80' | head -1" 2>/dev/null || echo "")"
if [ -n "$DNAT_RULE" ]; then
    log_ok "Regla DNAT detectada: $DNAT_RULE"
else
    log_warn "No se encontró DNAT a $PORTAL_IP:80 en chain prerouting"
fi

# Reachability HTTP del portal desde el router
log_info "Verificando reachability HTTP al portal desde OpenWrt..."
if router_ssh "uclient-fetch -T 5 -qO- http://$PORTAL_IP/portal >/dev/null 2>&1"; then
    log_ok "OpenWrt alcanza http://$PORTAL_IP/portal"
else
    log_warn "OpenWrt NO alcanza http://$PORTAL_IP/portal"
fi

# Resumen final
printf '\n'
log_ok "=== Setup de OpenWrt completado ==="
printf '\n'
log_info "Estado del sistema:"
printf '  Router:        %s\n' "$ROUTER_IP"
printf '  Topología:     %s\n' "$TOPOLOGY"
printf '  AI node/4B:    %s (%s) — permanente\n' "$RASPI4B_IP" "$RASPI4B_HOSTNAME"
printf '  Portal node:   %s\n' "$PORTAL_IP"
printf '  Portal node 3B2 reservado: %s (%s)\n' "$PORTAL_NODE_IP" "$PORTAL_NODE_HOSTNAME"
printf '  AP extender reservado:     %s (%s)\n' "$AP_EXTENDER_IP" "$AP_EXTENDER_HOSTNAME"
printf '  Sensor/3B:     %s (%s) — permanente\n' "$RASPI3B_IP" "$RASPI3B_HOSTNAME"
printf '  Admin (libre): %s — permanente\n' "$ADMIN_IP"
printf '  AP interface:  %s\n' "$AP_IFACE"
printf '  Portal timeout: %s (acceso WiFi invitados)\n' "$PORTAL_TIMEOUT"
printf '  DHCP leasetime: 120m\n'
printf '  Portal (demo):    http://%s/portal\n' "$CAPTIVE_DOMAIN"
printf '  Portal (local):   http://%s/portal\n' "$CAPTIVE_DOMAIN2"
printf '  Dashboard people: http://%s/people\n' "$PEOPLE_DOMAIN"
printf '\n'
log_info "Comandos utiles:"
printf '  Listar clientes:    sh scripts/openwrt-list-clients.sh\n'
printf '  Autorizar cliente:  sh scripts/openwrt-allow-client.sh <IP>\n'
printf '  Bloquear cliente:   sh scripts/openwrt-block-client.sh <IP>\n'
printf '  Reset emergencia:   sh scripts/openwrt-reset-firewall.sh\n'
