#!/bin/sh
# setup-openwrt-mode-raspi-portal-offload.sh
# Orquestador del nuevo modo:
#   - OpenWrt: uplink 2.4GHz a netup + AP 5GHz
#   - OpenWrt: DHCP reservas Raspi3B/Raspi4B
#   - OpenWrt: captive clásico (nft + dnsmasq), SIN openNDS
#     apuntando al portal en Raspi3B (192.168.1.181)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
set -eu

UPLINK_SSID="${UPLINK_SSID:-netup}"
UPLINK_PASS="${UPLINK_PASS:-123}"
AP_SSID="${AP_SSID:-Rafex Portal 5G}"
PORTAL_IP="${PORTAL_IP:-192.168.1.181}"
PORTAL_PORT="${PORTAL_PORT:-8080}"
PORTAL_PATH="${PORTAL_PATH:-/portal/}"
AI_IP="${AI_IP:-192.168.1.167}"

usage() {
    cat <<EOF
Uso:
  bash scripts/setup-openwrt-mode-raspi-portal-offload.sh [opciones]

Opciones:
  --uplink-ssid <ssid>   Default: netup
  --uplink-pass <pass>   Default: 123
  --ap-ssid <ssid>       Default: Rafex Portal 5G
  --portal-ip <ip>       Default: 192.168.1.181
  --ai-ip <ip>           Default: 192.168.1.167
  --portal-port <port>   Default: 8080
  --portal-path <path>   Default: /portal/
  -h, --help             Ayuda
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --uplink-ssid) UPLINK_SSID="$2"; shift 2 ;;
        --uplink-pass) UPLINK_PASS="$2"; shift 2 ;;
        --ap-ssid) AP_SSID="$2"; shift 2 ;;
        --portal-ip) PORTAL_IP="$2"; shift 2 ;;
        --ai-ip) AI_IP="$2"; shift 2 ;;
        --portal-port) PORTAL_PORT="$2"; shift 2 ;;
        --portal-path) PORTAL_PATH="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "[ERROR] Argumento no soportado: $1" >&2; exit 1 ;;
    esac
done

echo "[INFO]  === Modo OpenWrt offload portal a Raspi3B ==="
echo "[INFO]  1/3 Configurando WiFi (2.4 uplink + 5 AP)..."
bash "$SCRIPT_DIR/setup-openwrt-wifi-uplink24-ap5.sh" \
  --uplink-ssid "$UPLINK_SSID" \
  --uplink-pass "$UPLINK_PASS" \
  --ap-ssid "$AP_SSID"

echo "[INFO]  2/3 Reservando IPs de core nodes..."
bash "$SCRIPT_DIR/setup-openwrt-reserve-core-nodes.sh"

echo "[INFO]  3/4 Desactivando openNDS (si estaba activo)..."
bash "$SCRIPT_DIR/openwrt-disable-opennds.sh"

echo "[INFO]  4/4 Configurando captive clásico (nft + dnsmasq)..."
bash "$SCRIPT_DIR/setup-openwrt.sh" \
  --topology split_portal \
  --portal-ip "$PORTAL_IP" \
  --portal-port "$PORTAL_PORT" \
  --ai-ip "$AI_IP"

echo "[OK]    Modo aplicado."
echo "[INFO]  Validación recomendada:"
echo "  bash scripts/openwrt-captive-doctor.sh"
echo "  curl -I http://${PORTAL_IP}:${PORTAL_PORT}${PORTAL_PATH}"
