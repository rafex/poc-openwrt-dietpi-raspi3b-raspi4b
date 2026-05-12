#!/bin/sh
# setup-openwrt-opennds-config.sh
# Configura OpenNDS para servir captive portal local del router.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

NDS_GATEWAY_IF="${NDS_GATEWAY_IF:-br-lan}"
NDS_GATEWAY_NAME="${NDS_GATEWAY_NAME:-Rafex Portal}"
NDS_FAS_PORT="${NDS_FAS_PORT:-80}"
NDS_FAS_REMOTE_IP="${NDS_FAS_REMOTE_IP:-$ROUTER_IP}"
NDS_FAS_PATH="${NDS_FAS_PATH:-/portal/portal.html}"
NDS_FAS_SECURE="${NDS_FAS_SECURE:-0}"

usage() {
    cat <<EOF
Uso:
  bash scripts/setup-openwrt-opennds-config.sh [opciones]

Opciones:
  --gateway-if <if>      Interface gateway (default: br-lan)
  --gateway-name <name>  Nombre portal (default: "Rafex Portal")
  --fas-port <port>      Puerto FAS (default: 80)
  --fas-remote-ip <ip>   IP FAS (default: $ROUTER_IP)
  --fas-path <path>      Path HTML FAS (default: /portal/portal.html)
  --fas-secure <0|1>     fas_secure_enabled (default: 0)
  -h, --help             Muestra ayuda
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --gateway-if) [ -n "${2:-}" ] || die "Falta valor para --gateway-if"; NDS_GATEWAY_IF="$2"; shift 2 ;;
        --gateway-name) [ -n "${2:-}" ] || die "Falta valor para --gateway-name"; NDS_GATEWAY_NAME="$2"; shift 2 ;;
        --fas-port) [ -n "${2:-}" ] || die "Falta valor para --fas-port"; NDS_FAS_PORT="$2"; shift 2 ;;
        --fas-remote-ip) [ -n "${2:-}" ] || die "Falta valor para --fas-remote-ip"; NDS_FAS_REMOTE_IP="$2"; shift 2 ;;
        --fas-path) [ -n "${2:-}" ] || die "Falta valor para --fas-path"; NDS_FAS_PATH="$2"; shift 2 ;;
        --fas-secure) [ -n "${2:-}" ] || die "Falta valor para --fas-secure"; NDS_FAS_SECURE="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "Argumento no soportado: $1" ;;
    esac
done

validate_ip "$NDS_FAS_REMOTE_IP" || die "IP inválida para --fas-remote-ip: $NDS_FAS_REMOTE_IP"

check_ssh_key
test_router_ssh

log_info "=== Configurando OpenNDS (portal local en router) ==="
router_ssh "test -f /etc/config/opennds" || die "No existe /etc/config/opennds (instala opennds primero)"

router_ssh "sh -s" <<EOF
set -eu
uci set opennds.@opennds[0].enabled='1'
uci set opennds.@opennds[0].gatewayinterface='$NDS_GATEWAY_IF'
uci set opennds.@opennds[0].gatewayname='$NDS_GATEWAY_NAME'
uci set opennds.@opennds[0].fasport='$NDS_FAS_PORT'
uci set opennds.@opennds[0].fasremoteip='$NDS_FAS_REMOTE_IP'
uci set opennds.@opennds[0].faspath='$NDS_FAS_PATH'
uci set opennds.@opennds[0].fas_secure_enabled='$NDS_FAS_SECURE'
uci commit opennds
/etc/init.d/opennds restart
EOF

[ "$?" -eq 0 ] || die "Falló configuración/restart de opennds"

log_ok "OpenNDS configurado."
log_info "Resumen actual:"
router_ssh "uci show opennds | grep -E 'enabled|gatewayinterface|gatewayname|fasport|fasremoteip|faspath|fas_secure_enabled'" \
    || true

