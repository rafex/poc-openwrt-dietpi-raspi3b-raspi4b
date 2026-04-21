#!/bin/sh
# scripts/lib/common.sh — Funciones comunes para todos los scripts del captive portal
# Compatibilidad: POSIX sh (busybox ash en OpenWrt, bash en DietPi)

# =============================================================================
# Constantes globales
# =============================================================================
ROUTER_IP="192.168.1.1"
PORTAL_IP="192.168.1.167"
ADMIN_IP="192.168.1.113"
LAN_SUBNET="192.168.1.0/24"    # subred LAN completa — usada en reglas nftables
SSH_KEY="/opt/keys/captive-portal"
SSH_KEY_PUB="/opt/keys/captive-portal.pub"
NFT_TABLE="ip captive"
NFT_SET="allowed_clients"
NFT_FILE="/etc/nftables.d/captive-portal.nft"
DNSMASQ_CONF="/etc/dnsmasq.d/captive-portal.conf"
AP_IFACE="phy0-ap0"            # solo usado en pre-flight check de interfaz WiFi

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
# Admin y portal se agregan siempre con timeout 0s (permanentes).
# El resto hereda el timeout del set (30m por defecto).
router_add_ip() {
    local ip="$1"
    local timeout_flag=""
    if [ "$ip" = "$ADMIN_IP" ] || [ "$ip" = "$PORTAL_IP" ]; then
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
