#!/bin/sh
# openwrt-wifi-ap-doctor.sh
# Diagnóstico de conectividad WiFi en OpenWrt:
#   - Uplink STA (WWAN) conectado a red externa
#   - AP local funcionando y aceptando clientes

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

WWAN_IF="${WWAN_IF:-wwan}"
AP_LAN_IF="${AP_LAN_IF:-br-lan}"

usage() {
    cat <<EOF
Uso:
  bash scripts/openwrt-wifi-ap-doctor.sh [opciones]

Opciones:
  --wwan-if <ifname>   Interfaz uplink lógica (default: wwan)
  --ap-if <ifname>     Interfaz LAN/AP bridge (default: br-lan)
  -h, --help           Muestra ayuda
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --wwan-if) [ -n "${2:-}" ] || die "Falta valor para --wwan-if"; WWAN_IF="$2"; shift 2 ;;
        --ap-if) [ -n "${2:-}" ] || die "Falta valor para --ap-if"; AP_LAN_IF="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "Argumento no soportado: $1" ;;
    esac
done

check_ssh_key
test_router_ssh

log_info "=== OpenWrt WiFi/AP Doctor ==="
log_info "Router: $ROUTER_IP"
log_info "WWAN : $WWAN_IF"
log_info "AP IF: $AP_LAN_IF"

UP_OK=0
AP_OK=0

log_info "--- 1) Estado uplink (STA/WWAN) ---"
WWAN_JSON="$(router_ssh "ifstatus '$WWAN_IF' 2>/dev/null || true")"
if [ -n "$WWAN_JSON" ]; then
    WWAN_UP="$(printf '%s\n' "$WWAN_JSON" | grep -m1 '"up"' | grep -o 'true\|false' || true)"
    WWAN_DEV="$(printf '%s\n' "$WWAN_JSON" | sed -n 's/.*"l3_device":"\([^"]*\)".*/\1/p' | head -1)"
    WWAN_ADDR="$(printf '%s\n' "$WWAN_JSON" | sed -n 's/.*"address":"\([^"]*\)".*/\1/p' | head -1)"
    if [ "$WWAN_UP" = "true" ]; then
        UP_OK=1
        log_ok "WWAN arriba: up=true dev=${WWAN_DEV:-?} ip=${WWAN_ADDR:-sin_ip}"
    else
        log_warn "WWAN no está arriba (up=${WWAN_UP:-desconocido})"
    fi
else
    log_warn "No se pudo obtener ifstatus de $WWAN_IF"
fi

log_info "Prueba DNS desde router:"
if router_ssh "nslookup google.com 127.0.0.1 >/dev/null 2>&1"; then
    log_ok "DNS resolviendo correctamente"
else
    log_warn "DNS no resolvió (nslookup google.com 127.0.0.1)"
fi

log_info "Prueba salida a internet (ICMP 8.8.8.8):"
if router_ssh "ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1"; then
    log_ok "Salida a internet OK (8.8.8.8)"
else
    log_warn "No hubo respuesta ICMP a 8.8.8.8"
fi

log_info "--- 2) Estado AP (radio + SSID + clientes) ---"
AP_IFACES="$(router_ssh "uci show wireless | sed -n \"s/^wireless\\.\\([^=]*\\)=wifi-iface$/\\1/p\"")"
AP_FOUND=0
AP_ENABLED=0
while IFS= read -r sec; do
    [ -n "$sec" ] || continue
    MODE="$(router_ssh "uci -q get wireless.$sec.mode 2>/dev/null || true")"
    [ "$MODE" = "ap" ] || continue
    AP_FOUND=1
    SSID="$(router_ssh "uci -q get wireless.$sec.ssid 2>/dev/null || true")"
    DEV="$(router_ssh "uci -q get wireless.$sec.device 2>/dev/null || true")"
    DISABLED="$(router_ssh "uci -q get wireless.$sec.disabled 2>/dev/null || echo 0")"
    ENC="$(router_ssh "uci -q get wireless.$sec.encryption 2>/dev/null || true")"
    if [ "$DISABLED" = "1" ]; then
        log_warn "AP sección=$sec deshabilitada (device=$DEV ssid=$SSID)"
    else
        AP_ENABLED=1
        log_ok "AP activo: sección=$sec device=$DEV ssid=$SSID enc=$ENC"
    fi
done <<EOF
$AP_IFACES
EOF

if [ "$AP_FOUND" -eq 0 ]; then
    log_warn "No se encontró ningún wifi-iface en modo AP"
fi

ASSOC_CNT="$(router_ssh "iwinfo 2>/dev/null | awk '/ESSID|Access Point|Mode/ {print}' | wc -l" 2>/dev/null || echo 0)"
CLIENTS_CNT="$(router_ssh "iwinfo 2>/dev/null | awk '/Station/{c++} END{print c+0}'" 2>/dev/null || echo 0)"
if [ "$AP_ENABLED" -eq 1 ]; then
    AP_OK=1
    log_ok "AP reportado por configuración como activo"
    log_info "Clientes asociados detectados (iwinfo): ${CLIENTS_CNT:-0}"
else
    log_warn "AP no parece activo por configuración"
fi

log_info "Resumen interfaces inalámbricas (iwinfo):"
router_ssh "iwinfo 2>/dev/null | sed -n '1,120p'" || true

echo
if [ "$UP_OK" -eq 1 ] && [ "$AP_OK" -eq 1 ]; then
    log_ok "Diagnóstico OK: uplink y AP funcionales."
    exit 0
fi

log_warn "Diagnóstico con advertencias."
log_info "Sugerencias:"
log_info "  1) Reaplicar WiFi: bash scripts/setup-openwrt-wifi-uplink24-ap5.sh"
log_info "  2) Ver openNDS:  bash scripts/setup-openwrt-opennds-raspi-portal.sh"
exit 1

