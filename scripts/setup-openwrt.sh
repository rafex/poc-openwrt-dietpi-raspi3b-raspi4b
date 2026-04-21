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
#   - La IP 192.168.1.128 (admin) NUNCA sera bloqueada
#   - En caso de emergencia: ssh root@192.168.1.1 y ejecutar:
#       nft delete table ip captive

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

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
# Dominios que los SO usan para detectar captive portals
DNSMASQ_CONTENT="# captive-portal.conf — Generado por setup-openwrt.sh
# Redirige dominios de deteccion de captive portal a la Pi (192.168.1.167)

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
"

# Verificar si /etc/dnsmasq.d/ existe en el router
DNSMASQ_D_EXISTS=0
router_ssh "[ -d /etc/dnsmasq.d ]" 2>/dev/null && DNSMASQ_D_EXISTS=1

if [ "$DNSMASQ_D_EXISTS" -eq 1 ]; then
    # Usar /etc/dnsmasq.d/captive-portal.conf
    log_info "Escribiendo /etc/dnsmasq.d/captive-portal.conf en el router..."
    router_ssh "cat > /etc/dnsmasq.d/captive-portal.conf" << EOF
$DNSMASQ_CONTENT
EOF
    log_ok "Archivo dnsmasq creado: /etc/dnsmasq.d/captive-portal.conf"
else
    # Fallback: insertar en /etc/dnsmasq.conf entre marcadores
    log_warn "/etc/dnsmasq.d/ no existe — usando /etc/dnsmasq.conf con marcadores"
    # Eliminar bloque anterior si existe
    router_ssh "
        if grep -q '# --- captive-portal begin ---' /etc/dnsmasq.conf 2>/dev/null; then
            sed -i '/# --- captive-portal begin ---/,/# --- captive-portal end ---/d' /etc/dnsmasq.conf
        fi
        printf '\n# --- captive-portal begin ---\n%s\n# --- captive-portal end ---\n' \
            '$DNSMASQ_CONTENT' >> /etc/dnsmasq.conf
    "
    log_ok "Configuracion dnsmasq insertada en /etc/dnsmasq.conf"
fi

# Configurar DHCP lease time a 30 minutos via UCI
# Razon: al reconectar, el dispositivo obtiene nueva IP → no esta en allowed_clients → portal
log_info "Configurando DHCP lease time a 30 minutos..."
router_ssh "
    uci set dhcp.lan.leasetime='30m'
    uci commit dhcp
" && log_ok "DHCP lease time = 30m configurado" || \
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
    # timeout 30m: las autorizaciones expiran solas
    #   → combinado con DHCP lease=30m: al reconectar pasan de nuevo por el portal
    #
    # Admin ($ADMIN_IP) y portal ($PORTAL_IP): timeout 0s = NUNCA expiran
    set $NFT_SET {
        type ipv4_addr
        flags dynamic, timeout
        timeout 30m
        elements = { $ADMIN_IP timeout 0s, $PORTAL_IP timeout 0s }
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

# CRITICO: Re-confirmar admin y portal como PERMANENTES (timeout 0s).
# No usar router_add_ip aquí — esa función no especifica timeout y heredaría
# el default de 30m del set, sobreescribiendo el timeout 0s del archivo nft.
log_info "Re-confirmando admin y portal como permanentes (timeout 0s)..."
router_ssh "nft add element $NFT_TABLE $NFT_SET { $ADMIN_IP timeout 0s }" || \
    die "No se pudo asegurar $ADMIN_IP como permanente"
router_ssh "nft add element $NFT_TABLE $NFT_SET { $PORTAL_IP timeout 0s }" 2>/dev/null || true
log_ok "Admin $ADMIN_IP y portal $PORTAL_IP asegurados como permanentes"

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

# Resumen final
printf '\n'
log_ok "=== Setup de OpenWrt completado ==="
printf '\n'
log_info "Estado del sistema:"
printf '  Router:        %s\n' "$ROUTER_IP"
printf '  Portal:        %s\n' "$PORTAL_IP"
printf '  Admin (libre): %s\n' "$ADMIN_IP"
printf '  AP interface:  %s\n' "$AP_IFACE"
printf '\n'
log_info "Comandos utiles:"
printf '  Listar clientes:    sh scripts/openwrt-list-clients.sh\n'
printf '  Autorizar cliente:  sh scripts/openwrt-allow-client.sh <IP>\n'
printf '  Bloquear cliente:   sh scripts/openwrt-block-client.sh <IP>\n'
printf '  Reset emergencia:   sh scripts/openwrt-reset-firewall.sh\n'
