#!/bin/sh
# openwrt-push-admin-pubkeys.sh
# Copia al router OpenWrt las llaves públicas de administración:
#   - captive-portal.pub
#   - sensor.pub
#
# Idempotente: si ya existen en authorized_keys, no las duplica.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

CAPTIVE_PUB="${CAPTIVE_PUB:-/opt/keys/captive-portal.pub}"
SENSOR_PUB="${SENSOR_PUB:-/opt/keys/sensor.pub}"

usage() {
    cat <<EOF
Uso:
  bash scripts/openwrt-push-admin-pubkeys.sh [opciones]

Opciones:
  --captive-pub <path>   Ruta a captive-portal.pub (default: /opt/keys/captive-portal.pub)
  --sensor-pub <path>    Ruta a sensor.pub (default: /opt/keys/sensor.pub)
  -h, --help             Muestra esta ayuda
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --captive-pub)
            [ -n "${2:-}" ] || die "Falta valor para --captive-pub"
            CAPTIVE_PUB="$2"
            shift 2
            ;;
        --sensor-pub)
            [ -n "${2:-}" ] || die "Falta valor para --sensor-pub"
            SENSOR_PUB="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Argumento no soportado: $1"
            ;;
    esac
done

[ -f "$CAPTIVE_PUB" ] || die "No existe llave pública captive: $CAPTIVE_PUB"
[ -f "$SENSOR_PUB" ] || die "No existe llave pública sensor: $SENSOR_PUB"

check_ssh_key
test_router_ssh

CAPTIVE_KEY="$(cat "$CAPTIVE_PUB")"
SENSOR_KEY="$(cat "$SENSOR_PUB")"

log_info "=== Push de llaves públicas admin -> OpenWrt ==="
log_info "Router: $ROUTER_IP"
log_info "Llaves:"
log_info "  captive: $CAPTIVE_PUB"
log_info "  sensor : $SENSOR_PUB"

log_info "Preparando /etc/dropbear/authorized_keys..."
router_ssh "mkdir -p /etc/dropbear && touch /etc/dropbear/authorized_keys && chmod 600 /etc/dropbear/authorized_keys" \
    || die "No se pudo preparar authorized_keys en el router"

install_key_if_missing() {
    key_label="$1"
    key_value="$2"
    if router_ssh "grep -qF '$key_value' /etc/dropbear/authorized_keys 2>/dev/null"; then
        log_info "Llave ya presente ($key_label) — skip"
        return 0
    fi

    router_ssh "printf '%s\n' '$key_value' >> /etc/dropbear/authorized_keys" \
        || die "No se pudo agregar llave $key_label al router"

    if router_ssh "grep -qF '$key_value' /etc/dropbear/authorized_keys 2>/dev/null"; then
        log_ok "Llave agregada: $key_label"
    else
        die "No se pudo verificar llave $key_label en authorized_keys"
    fi
}

install_key_if_missing "captive-portal" "$CAPTIVE_KEY"
install_key_if_missing "sensor" "$SENSOR_KEY"

log_ok "Llaves públicas sincronizadas con OpenWrt."
log_info "Conteo actual de claves en router:"
router_ssh "wc -l /etc/dropbear/authorized_keys | awk '{print \"  \" \$1 \" claves\"}'" || true

