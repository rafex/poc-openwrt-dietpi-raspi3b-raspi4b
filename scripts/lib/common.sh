#!/bin/sh
# scripts/lib/common.sh — Funciones comunes para todos los scripts del captive portal
# Compatibilidad: POSIX sh (busybox ash en OpenWrt, bash en DietPi)

# =============================================================================
# Configuración de topología (opcional)
# =============================================================================
# Permite sobreescribir IPs/roles sin romper scripts legacy.
TOPOLOGY_FILE="${TOPOLOGY_FILE:-/etc/demo-openwrt/topology.env}"
if [ -f "$TOPOLOGY_FILE" ]; then
    # shellcheck disable=SC1090
    . "$TOPOLOGY_FILE"
elif [ -f "/opt/repository/poc-openwrt-dietpi-raspi3b-raspi4b/scripts/lib/topology.env" ]; then
    # fallback para ejecución directa dentro de la ruta estándar en Raspi
    # shellcheck disable=SC1091
    . "/opt/repository/poc-openwrt-dietpi-raspi3b-raspi4b/scripts/lib/topology.env"
fi

# =============================================================================
# Constantes globales
# =============================================================================
ROUTER_IP="${ROUTER_IP:-192.168.1.1}"
ADMIN_IP="${ADMIN_IP:-192.168.1.113}"
LAN_SUBNET="${LAN_SUBNET:-192.168.1.0/24}"    # subred LAN completa — usada en reglas nftables
SSH_KEY="${SSH_KEY:-/opt/keys/captive-portal}"
SSH_KEY_PUB="${SSH_KEY_PUB:-/opt/keys/captive-portal.pub}"
NFT_TABLE="${NFT_TABLE:-ip captive}"
NFT_SET="${NFT_SET:-allowed_clients}"
NFT_FILE="${NFT_FILE:-/etc/nftables.d/captive-portal.nft}"
DNSMASQ_CONF="${DNSMASQ_CONF:-/etc/dnsmasq.d/captive-portal.conf}"
AP_IFACE="${AP_IFACE:-phy0-ap0}"            # solo usado en pre-flight check de interfaz WiFi

# Raspberry Pi — IPs y MACs permanentes (bypass total del portal + reserva DHCP)
RASPI4B_IP="${RASPI4B_IP:-192.168.1.167}"     # Raspi 4B (IA + k3s)
RASPI4B_MAC="${RASPI4B_MAC:-d8:3a:dd:4d:4b:ae}"
RASPI4B_HOSTNAME="${RASPI4B_HOSTNAME:-RafexPi4B}"
RASPI3B_IP="${RASPI3B_IP:-192.168.1.181}"     # Raspi 3B #1 (sensor de red)
RASPI3B_MAC="${RASPI3B_MAC:-b8:27:eb:5a:ec:33}"
RASPI3B_HOSTNAME="${RASPI3B_HOSTNAME:-RafexPi3B}"
PORTAL_NODE_IP="${PORTAL_NODE_IP:-192.168.1.182}"    # Raspi 3B #2 (portal node opcional)
PORTAL_NODE_MAC="${PORTAL_NODE_MAC:-}"
PORTAL_NODE_HOSTNAME="${PORTAL_NODE_HOSTNAME:-RafexPi3BPortal}"

TOPOLOGY="${TOPOLOGY:-legacy}"               # legacy | split_portal
AI_IP="${AI_IP:-$RASPI4B_IP}"
if [ -z "${PORTAL_IP:-}" ]; then
    if [ "$TOPOLOGY" = "split_portal" ]; then
        PORTAL_IP="$PORTAL_NODE_IP"
    else
        PORTAL_IP="$RASPI4B_IP"
    fi
fi

# Tiempo de acceso a internet para clientes WiFi del captive portal
PORTAL_TIMEOUT="${PORTAL_TIMEOUT:-120m}"          # 120 minutos (2 horas)

# =============================================================================
# Logging
# =============================================================================
log_info()  { printf '[INFO]  %s\n' "$*"; }
log_ok()    { printf '[OK]    %s\n' "$*"; }
log_warn()  { printf '[WARN]  %s\n' "$*"; }
log_error() { printf '[ERROR] %s\n' "$*" >&2; }
die()       { log_error "$*"; exit 1; }

# =============================================================================
# Validacion de IP (POSIX sh puro — sin grep -E ni [[ ]])
# =============================================================================
validate_ip() {
    local ip="$1"
    local IFS='.'
    # Rechazar si tiene caracteres que no sean digitos o puntos
    case "$ip" in
        *[!0-9.]*) return 1 ;;
        '') return 1 ;;
    esac
    set -- $ip
    [ $# -eq 4 ] || return 1
    for octet in "$@"; do
        [ -z "$octet" ] && return 1
        # Rechazar octetos vacios o mayores a 255
        [ "$octet" -ge 0 ] 2>/dev/null || return 1
        [ "$octet" -le 255 ] 2>/dev/null || return 1
    done
    return 0
}

# =============================================================================
# SSH helper — opciones basicas compatibles con Dropbear (server) + openssh-client
# El cliente SSH en la Pi es openssh-client; el servidor en el router es Dropbear.
# =============================================================================
router_ssh() {
    ssh \
        -i "$SSH_KEY" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o BatchMode=yes \
        -o ConnectTimeout=10 \
        -o LogLevel=ERROR \
        root@"$ROUTER_IP" "$@"
}

# Verificar que las llaves SSH existen en la Pi
check_ssh_key() {
    [ -f "$SSH_KEY" ] || die "Llave SSH no encontrada: $SSH_KEY
  Ejecuta primero: bash scripts/setup-raspi.sh"
    [ -f "$SSH_KEY_PUB" ] || die "Llave SSH publica no encontrada: $SSH_KEY_PUB"
}

# Probar conectividad SSH al router (falla rapido si no hay acceso)
test_router_ssh() {
    log_info "Verificando acceso SSH al router $ROUTER_IP..."
    router_ssh 'echo ok' > /dev/null 2>&1 || \
        die "No se puede conectar al router $ROUTER_IP via SSH.
  Verifica: ssh -i $SSH_KEY root@$ROUTER_IP
  La llave publica debe estar en /etc/dropbear/authorized_keys del router."
    log_ok "Conexion SSH al router OK"
}

# =============================================================================
# Helpers nftables (ejecutados en el router via SSH)
# =============================================================================

# Verificar si la tabla ip captive existe en el router
router_table_exists() {
    router_ssh "nft list table $NFT_TABLE > /dev/null 2>&1"
}

# Verificar si el set allowed_clients existe
router_set_exists() {
    router_ssh "nft list set $NFT_TABLE $NFT_SET > /dev/null 2>&1"
}

# Verificar si una IP esta en el set allowed_clients
router_ip_in_set() {
    local ip="$1"
    router_ssh "nft list set $NFT_TABLE $NFT_SET 2>/dev/null" | grep -qw "$ip"
}

# Agregar IP al set.
# Admin, portal y Raspis (4B/3B) se agregan con timeout 0s (permanentes — bypass total).
# El resto hereda el timeout del set (PORTAL_TIMEOUT por defecto).
router_add_ip() {
    local ip="$1"
    local timeout_flag=""
    if [ "$ip" = "$ADMIN_IP" ] || [ "$ip" = "$PORTAL_IP" ] || \
       [ "$ip" = "$RASPI4B_IP" ] || [ "$ip" = "$RASPI3B_IP" ]; then
        timeout_flag=" timeout 0s"
    fi
    router_ssh "nft add element $NFT_TABLE $NFT_SET { $ip$timeout_flag }" 2>/dev/null || \
    router_ssh "nft add element $NFT_TABLE $NFT_SET { $ip$timeout_flag }"
}

# Eliminar IP del set
router_del_ip() {
    local ip="$1"
    router_ssh "nft delete element $NFT_TABLE $NFT_SET { $ip }"
}
