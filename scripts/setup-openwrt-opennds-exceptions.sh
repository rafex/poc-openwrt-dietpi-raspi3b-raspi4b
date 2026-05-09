#!/bin/sh
# setup-openwrt-opennds-exceptions.sh
# Agrega reglas de excepción para backend preautenticado en OpenNDS.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

BACKEND_IP="${BACKEND_IP:-192.168.1.181}"
BACKEND_PORTS="${BACKEND_PORTS:-5000 80 443}"
ROUTER_PORTS="${ROUTER_PORTS:-80 443}"

usage() {
    cat <<EOF
Uso:
  bash scripts/setup-openwrt-opennds-exceptions.sh [opciones]

Opciones:
  --backend-ip <ip>        IP backend preauth (default: 192.168.1.181)
  --backend-ports "a b c"  Puertos backend (default: "5000 80 443")
  --router-ports "a b"     Puertos router permitidos (default: "80 443")
  -h, --help               Muestra ayuda
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --backend-ip) [ -n "${2:-}" ] || die "Falta valor para --backend-ip"; BACKEND_IP="$2"; shift 2 ;;
        --backend-ports) [ -n "${2:-}" ] || die "Falta valor para --backend-ports"; BACKEND_PORTS="$2"; shift 2 ;;
        --router-ports) [ -n "${2:-}" ] || die "Falta valor para --router-ports"; ROUTER_PORTS="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "Argumento no soportado: $1" ;;
    esac
done

validate_ip "$BACKEND_IP" || die "IP inválida para backend: $BACKEND_IP"

check_ssh_key
test_router_ssh

log_info "=== Configurando excepciones OpenNDS ==="
log_info "Backend preauth: $BACKEND_IP"

router_ssh "test -f /etc/config/opennds" || die "No existe /etc/config/opennds (instala opennds primero)"

router_ssh "sh -s" <<EOF
set -eu
add_if_missing() {
    key="\$1"
    value="\$2"
    if uci show opennds | grep -F "opennds.@opennds[0].\${key}='\${value}'" >/dev/null 2>&1; then
        return 0
    fi
    uci add_list opennds.@opennds[0]."\$key"="\$value"
}

EOF

for p in $ROUTER_PORTS; do
    router_ssh "sh -s" <<EOF
set -eu
if ! uci show opennds | grep -F "opennds.@opennds[0].users_to_router='allow tcp port $p'" >/dev/null 2>&1; then
  uci add_list opennds.@opennds[0].users_to_router='allow tcp port $p'
fi
EOF
done

for p in $BACKEND_PORTS; do
    router_ssh "sh -s" <<EOF
set -eu
if ! uci show opennds | grep -F "opennds.@opennds[0].preauthenticated_users='allow tcp port $p to $BACKEND_IP'" >/dev/null 2>&1; then
  uci add_list opennds.@opennds[0].preauthenticated_users='allow tcp port $p to $BACKEND_IP'
fi
EOF
done

router_ssh "uci commit opennds && /etc/init.d/opennds restart" || die "No se pudo aplicar/reiniciar opennds"

log_ok "Excepciones aplicadas."
log_info "Reglas activas:"
router_ssh "uci show opennds | grep -E 'users_to_router|preauthenticated_users'" || true

