#!/bin/sh
# setup-openwrt.sh — Configura el router OpenWrt para el captive portal
# Idempotente: puede ejecutarse multiples veces sin efectos secundarios
#
# Uso: sh scripts/setup-openwrt.sh
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
#   CAPTIVE_DOMAIN=captive.localhost.com   # dominio local de fallback para abrir portal manualmente

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
CAPTIVE_DOMAIN="${CAPTIVE_DOMAIN:-captive.localhost.com}"

# =============================================================================
# Pre-flight checks
# =============================================================================
log_info "=== Setup de OpenWrt para Captive Portal ==="

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

# Android / Google
address=/connectivitycheck.gstatic.com/$PORTAL_IP
address=/connectivitycheck.android.com/$PORTAL_IP
address=/clients1.google.com/$PORTAL_IP
address=/clients3.google.com/$PORTAL_IP

# iOS / macOS (Apple)
address=/captive.apple.com/$PORTAL_IP
address=/appleiphonecell.com/$PORTAL_IP
address=/iphone-otu.apple.com/$PORTAL_IP
address=/www.apple.com/$PORTAL_IP

# Windows / Microsoft (NCA)
address=/www.msftconnecttest.com/$PORTAL_IP
address=/msftconnecttest.com/$PORTAL_IP
address=/www.msftncsi.com/$PORTAL_IP
address=/msftncsi.com/$PORTAL_IP

# Firefox / Mozilla
address=/detectportal.firefox.com/$PORTAL_IP

# Ubuntu / Canonical
address=/connectivity-check.ubuntu.com/$PORTAL_IP

# Linux / GNOME / Debian
address=/network-test.debian.org/$PORTAL_IP
address=/nmcheck.gnome.org/$PORTAL_IP

# Dominio local de fallback (manual)
address=/$CAPTIVE_DOMAIN/$PORTAL_IP

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
    uci add_list dhcp.lan.dhcp_option='114,http://$PORTAL_IP/portal'
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
# SEGURIDAD: $ADMIN_IP (admin) y $PORTAL_IP (portal) NUNCA son bloqueadas.
# Para resetear: nft delete table ip captive

add table ip captive

table ip captive {
    # Set de clientes autorizados — IPs que pueden navegar libremente
    #
    # timeout 120m: las autorizaciones expiran solas (2 horas)
    #   → combinado con DHCP lease=120m: al reconectar pasan de nuevo por el portal
    #
    # Admin ($ADMIN_IP), portal ($PORTAL_IP) y Raspis: timeout 0s = NUNCA expiran
    #   RafexPi4B ($RASPI4B_IP) — IA + k3s, siempre necesita acceso
    #   RafexPi3B ($RASPI3B_IP) — sensor de red, siempre capturando tráfico
    set $NFT_SET {
        type ipv4_addr
        flags dynamic, timeout
        timeout 120m
        elements = { $ADMIN_IP timeout 0s, $PORTAL_IP timeout 0s, $RASPI3B_IP timeout 0s }
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
router_ssh "nft add element $NFT_TABLE $NFT_SET { $PORTAL_IP timeout 0s }" 2>/dev/null || true
router_ssh "nft add element $NFT_TABLE $NFT_SET { $RASPI3B_IP timeout 0s }" 2>/dev/null || true
log_ok "Permanentes: admin=$ADMIN_IP  portal/4B=$PORTAL_IP  sensor/3B=$RASPI3B_IP (timeout 0s)"

# Limpiar conntrack para que el bloqueo sea efectivo inmediatamente
# (conexiones ESTABLISHED bypasean el hook forward)
log_info "Limpiando conntrack..."
router_ssh "conntrack -F 2>/dev/null && echo 'conntrack flush OK' || echo 'conntrack no disponible (OK)'"

# Copiar el archivo a la ubicacion de persistencia
log_info "Persistiendo configuracion nftables..."
# Verificar si /etc/nftables.d/ existe
NFT_D_EXISTS=0
router_ssh "[ -d /etc/nftables.d ]" 2>/dev/null && NFT_D_EXISTS=1

if [ "$NFT_D_EXISTS" -eq 1 ]; then
    router_ssh "cp /tmp/captive-portal.nft /etc/nftables.d/captive-portal.nft"
    log_ok "Reglas persistidas en /etc/nftables.d/captive-portal.nft"
    log_info "fw4 cargara este archivo automaticamente al reiniciar el firewall"
else
    # Fallback: agregar carga del archivo en /etc/firewall.user
    log_warn "/etc/nftables.d/ no existe — usando /etc/firewall.user como fallback"
    router_ssh "cp /tmp/captive-portal.nft /etc/captive-portal.nft"
    router_ssh "
        grep -q 'captive-portal.nft' /etc/firewall.user 2>/dev/null || \
        echo 'nft -f /etc/captive-portal.nft' >> /etc/firewall.user
    "
    log_ok "Carga de reglas agregada a /etc/firewall.user"
fi

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

# Verificar dnsmasq
log_info "Verificando dnsmasq (resolucion de dominio de deteccion)..."
RESOLVED=$(router_ssh "nslookup connectivitycheck.gstatic.com 127.0.0.1 2>/dev/null | grep 'Address' | tail -1" 2>/dev/null || echo "")
if printf '%s' "$RESOLVED" | grep -q "$PORTAL_IP"; then
    log_ok "dnsmasq resuelve correctamente: connectivitycheck.gstatic.com -> $PORTAL_IP"
else
    log_warn "No se pudo verificar dnsmasq (puede estar OK si el dominio tarda en propagarse)"
fi

log_info "Verificando dominio fallback del portal..."
FALLBACK_RESOLVED=$(router_ssh "nslookup $CAPTIVE_DOMAIN 127.0.0.1 2>/dev/null | grep 'Address' | tail -1" 2>/dev/null || echo "")
if printf '%s' "$FALLBACK_RESOLVED" | grep -q "$PORTAL_IP"; then
    log_ok "dnsmasq resuelve correctamente: $CAPTIVE_DOMAIN -> $PORTAL_IP"
else
    log_warn "No se pudo verificar $CAPTIVE_DOMAIN en dnsmasq"
fi

# Resumen final
printf '\n'
log_ok "=== Setup de OpenWrt completado ==="
printf '\n'
log_info "Estado del sistema:"
printf '  Router:        %s\n' "$ROUTER_IP"
printf '  Portal/4B:     %s (%s) — permanente\n' "$PORTAL_IP" "$RASPI4B_HOSTNAME"
printf '  Sensor/3B:     %s (%s) — permanente\n' "$RASPI3B_IP" "$RASPI3B_HOSTNAME"
printf '  Admin (libre): %s — permanente\n' "$ADMIN_IP"
printf '  AP interface:  %s\n' "$AP_IFACE"
printf '  Portal timeout: %s (acceso WiFi invitados)\n' "$PORTAL_TIMEOUT"
printf '  DHCP leasetime: 120m\n'
printf '  Fallback portal: http://%s/portal\n' "$CAPTIVE_DOMAIN"
printf '\n'
log_info "Comandos utiles:"
printf '  Listar clientes:    sh scripts/openwrt-list-clients.sh\n'
printf '  Autorizar cliente:  sh scripts/openwrt-allow-client.sh <IP>\n'
printf '  Bloquear cliente:   sh scripts/openwrt-block-client.sh <IP>\n'
printf '  Reset emergencia:   sh scripts/openwrt-reset-firewall.sh\n'
