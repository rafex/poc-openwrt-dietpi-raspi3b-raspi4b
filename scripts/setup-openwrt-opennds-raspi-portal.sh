#!/bin/sh
# setup-openwrt-opennds-raspi-portal.sh
# Configura openNDS para portal externo en Raspi3B (frontend/backend).
#
# Config objetivo:
#   fasremoteip=192.168.1.181
#   fasport=8080
#   faspath=/portal/

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

PORTAL_IP="${PORTAL_IP:-$RASPI3B_IP}"
PORTAL_PORT="${PORTAL_PORT:-8080}"
PORTAL_PATH="${PORTAL_PATH:-/portal/}"
NDS_GATEWAY_IF="${NDS_GATEWAY_IF:-br-lan}"
NDS_GATEWAY_NAME="${NDS_GATEWAY_NAME:-Rafex Portal}"

usage() {
    cat <<EOF
Uso:
  bash scripts/setup-openwrt-opennds-raspi-portal.sh [opciones]

Opciones:
  --portal-ip <ip>       IP Raspi portal (default: $RASPI3B_IP)
  --portal-port <port>   Puerto portal (default: 8080)
  --portal-path <path>   Path portal (default: /portal/)
  --gateway-if <if>      Gateway interface openNDS (default: br-lan)
  --gateway-name <name>  Gateway name openNDS (default: Rafex Portal)
  -h, --help             Ayuda
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --portal-ip) [ -n "${2:-}" ] || die "Falta valor para --portal-ip"; PORTAL_IP="$2"; shift 2 ;;
        --portal-port) [ -n "${2:-}" ] || die "Falta valor para --portal-port"; PORTAL_PORT="$2"; shift 2 ;;
        --portal-path) [ -n "${2:-}" ] || die "Falta valor para --portal-path"; PORTAL_PATH="$2"; shift 2 ;;
        --gateway-if) [ -n "${2:-}" ] || die "Falta valor para --gateway-if"; NDS_GATEWAY_IF="$2"; shift 2 ;;
        --gateway-name) [ -n "${2:-}" ] || die "Falta valor para --gateway-name"; NDS_GATEWAY_NAME="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "Argumento no soportado: $1" ;;
    esac
done

validate_ip "$PORTAL_IP" || die "IP portal inválida: $PORTAL_IP"

check_ssh_key
test_router_ssh

ensure_opennds_installed() {
    if router_ssh "test -f /etc/config/opennds"; then
        log_ok "openNDS ya está instalado"
        return 0
    fi

    log_warn "No existe /etc/config/opennds — instalando openNDS..."
    router_ssh "sh -s" <<'EOF'
set -eu
if command -v apk >/dev/null 2>&1; then
    apk update
    apk add opennds
elif command -v opkg >/dev/null 2>&1; then
    opkg update
    opkg install opennds
else
    echo "No hay gestor de paquetes soportado (apk/opkg)" >&2
    exit 1
fi

# Inicializar config/defaults si el paquete no la creó automáticamente
/etc/init.d/opennds enable >/dev/null 2>&1 || true
/etc/init.d/opennds restart >/dev/null 2>&1 || true
test -f /etc/config/opennds
EOF
    [ "$?" -eq 0 ] || die "No se pudo instalar/activar openNDS"
    log_ok "openNDS instalado y activo"
}

ensure_opennds_installed

log_info "=== Configurando openNDS -> portal Raspi ==="
log_info "portal=${PORTAL_IP}:${PORTAL_PORT}${PORTAL_PATH}"

router_ssh "sh -s -- '$NDS_GATEWAY_IF' '$NDS_GATEWAY_NAME' '$PORTAL_IP' '$PORTAL_PORT' '$PORTAL_PATH' '$RASPI3B_MAC' '$RASPI4B_MAC' '$PORTAL_NODE_MAC' '$AP_EXTENDER_MAC' '$ADMIN_MAC' '$ADMIN_IP'" <<'EOF'
set -eu
GW_IF="$1"
GW_NAME="$2"
P_IP="$3"
P_PORT="$4"
P_PATH="$5"
MAC_R3="$6"
MAC_R4="$7"
MAC_P3B2="$8"
MAC_APX="$9"
MAC_ADMIN="${10}"
IP_ADMIN="${11}"

uci set opennds.@opennds[0].enabled='1'
uci set opennds.@opennds[0].gatewayinterface="$GW_IF"
uci set opennds.@opennds[0].gatewayname="$GW_NAME"
uci set opennds.@opennds[0].fasremoteip="$P_IP"
uci set opennds.@opennds[0].fasport="$P_PORT"
uci set opennds.@opennds[0].faspath="$P_PATH"
uci set opennds.@opennds[0].fas_secure_enabled='0'

# Excepciones al portal/backend en Raspi
for p in 8080 80 443; do
  v="allow tcp port $p to $P_IP"
  if ! uci show opennds | grep -F "opennds.@opennds[0].preauthenticated_users='$v'" >/dev/null 2>&1; then
    uci add_list opennds.@opennds[0].preauthenticated_users="$v"
  fi
done

# Bypass permanente de nodos de infraestructura para que nunca caigan al portal.
for m in "$MAC_R3" "$MAC_R4" "$MAC_P3B2" "$MAC_APX" "$MAC_ADMIN"; do
  [ -n "$m" ] || continue
  case "$m" in
    *:*:*:*:*:*) ;;
    *) continue ;;
  esac
  if ! uci show opennds | grep -Fi "opennds.@opennds[0].trustedmac='$m'" >/dev/null 2>&1; then
    uci add_list opennds.@opennds[0].trustedmac="$m"
  fi
done

# Bypass por IP para admin (además de trustedmac), útil si cambia temporalmente la MAC visible.
if [ -n "$IP_ADMIN" ]; then
  v="allow tcp port 1:65535 to $IP_ADMIN"
  if ! uci show opennds | grep -F "opennds.@opennds[0].preauthenticated_users='$v'" >/dev/null 2>&1; then
    uci add_list opennds.@opennds[0].preauthenticated_users="$v"
  fi
fi

uci commit opennds
/etc/init.d/opennds restart
EOF

log_ok "openNDS configurado para portal en Raspi"
log_info "Resumen:"
router_ssh "uci show opennds | grep -E 'enabled|gatewayinterface|gatewayname|fasremoteip|fasport|faspath|fas_secure_enabled|trustedmac|preauthenticated_users'" || true

log_info "Verificando exenciones obligatorias (admin + Raspi3B + Raspi4B)..."
for must_mac in "$ADMIN_MAC" "$RASPI3B_MAC" "$RASPI4B_MAC"; do
    [ -n "$must_mac" ] || die "MAC obligatoria vacía en entorno/topología"
    if router_ssh "uci show opennds | grep -Fi \"opennds.@opennds[0].trustedmac='$must_mac'\" >/dev/null"; then
        log_ok "trustedmac OK: $must_mac"
    else
        die "Falta trustedmac obligatorio: $must_mac"
    fi
done

if router_ssh "uci show opennds | grep -F \"opennds.@opennds[0].preauthenticated_users='allow tcp port 1:65535 to $ADMIN_IP'\" >/dev/null"; then
    log_ok "preauthenticated_users admin IP OK: $ADMIN_IP"
else
    die "Falta exención preauthenticated_users para admin IP: $ADMIN_IP"
fi
