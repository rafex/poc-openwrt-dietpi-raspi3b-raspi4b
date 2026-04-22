#!/bin/sh
# setup-openwrt-wifi-uplink.sh
#
# Configura OpenWrt para esta topología:
#   - Uplink WAN por WiFi 5GHz (modo STA) hacia un AP externo
#   - AP 2.4GHz abierto (sin clave) para clientes captive portal
#
# Defaults solicitados:
#   SSID uplink : netup
#   Password    : 123
#   SSID AP 2.4 : INFINITUM MOVIL
#
# Uso:
#   sh scripts/setup-openwrt-wifi-uplink.sh
#   sh scripts/setup-openwrt-wifi-uplink.sh --uplink-ssid netup --uplink-pass 123 --ap-ssid "INFINITUM MOVIL"

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

UPLINK_SSID="netup"
UPLINK_PASS="123"
AP_SSID="INFINITUM MOVIL"

while [ $# -gt 0 ]; do
    case "$1" in
        --uplink-ssid) UPLINK_SSID="$2"; shift 2 ;;
        --uplink-pass) UPLINK_PASS="$2"; shift 2 ;;
        --ap-ssid)     AP_SSID="$2"; shift 2 ;;
        --help|-h)
            sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            die "Argumento desconocido: $1"
            ;;
    esac
done

check_ssh_key
test_router_ssh

log_warn "Se configurará uplink WiFi 5GHz a SSID '$UPLINK_SSID' y AP 2.4GHz ABIERTO '$AP_SSID'."
log_warn "La clave uplink actual es '$UPLINK_PASS' (solo demo)."

router_ssh "sh -s -- '$UPLINK_SSID' '$UPLINK_PASS' '$AP_SSID'" <<'EOF'
set -eu

UPLINK_SSID="$1"
UPLINK_PASS="$2"
AP_SSID="$3"

find_radios() {
    RADIO_2G=""
    RADIO_5G=""

    for dev in $(uci show wireless | sed -n "s/^wireless\.\([^=]*\)=wifi-device$/\1/p"); do
        band="$(uci -q get wireless.$dev.band || true)"
        channel="$(uci -q get wireless.$dev.channel || true)"

        case "$band" in
            2g) [ -z "$RADIO_2G" ] && RADIO_2G="$dev" ;;
            5g) [ -z "$RADIO_5G" ] && RADIO_5G="$dev" ;;
        esac

        if [ -z "$RADIO_2G" ]; then
            case "$channel" in
                1|2|3|4|5|6|7|8|9|10|11|12|13|14) RADIO_2G="$dev" ;;
            esac
        fi
        if [ -z "$RADIO_5G" ]; then
            case "$channel" in
                36|40|44|48|52|56|60|64|100|104|108|112|116|120|124|128|132|136|140|149|153|157|161|165)
                    RADIO_5G="$dev"
                    ;;
            esac
        fi
    done

    [ -n "$RADIO_2G" ] || RADIO_2G="radio0"
    [ -n "$RADIO_5G" ] || RADIO_5G="radio1"

    echo "$RADIO_2G $RADIO_5G"
}

set -- $(find_radios)
RADIO_2G="$1"
RADIO_5G="$2"

echo "[router] Radio 2.4GHz: $RADIO_2G"
echo "[router] Radio 5GHz:   $RADIO_5G"

# 1) Desactivar wifi-iface legacy para evitar conflictos de múltiples SSID/STA.
for sec in $(uci show wireless | sed -n "s/^wireless\.\([^=]*\)=wifi-iface$/\1/p"); do
    case "$sec" in
        ap_captive|sta_uplink) ;;
        *) uci set "wireless.$sec.disabled=1" ;;
    esac
done

# 2) Interfaz de red para uplink por WiFi
uci set network.wwan='interface'
uci set network.wwan.proto='dhcp'
uci set network.wwan.metric='20'

# 3) STA 5GHz hacia upstream
uci set wireless.sta_uplink='wifi-iface'
uci set wireless.sta_uplink.device="$RADIO_5G"
uci set wireless.sta_uplink.mode='sta'
uci set wireless.sta_uplink.network='wwan'
uci set wireless.sta_uplink.ssid="$UPLINK_SSID"
uci set wireless.sta_uplink.encryption='psk2'
uci set wireless.sta_uplink.key="$UPLINK_PASS"
uci set wireless.sta_uplink.disabled='0'

# 4) AP 2.4GHz abierto para captive portal
uci set wireless.ap_captive='wifi-iface'
uci set wireless.ap_captive.device="$RADIO_2G"
uci set wireless.ap_captive.mode='ap'
uci set wireless.ap_captive.network='lan'
uci set wireless.ap_captive.ssid="$AP_SSID"
uci set wireless.ap_captive.encryption='none'
uci -q delete wireless.ap_captive.key
uci set wireless.ap_captive.disabled='0'

# 5) Incluir wwan en zona wan del firewall
WAN_ZONE="$(uci show firewall | sed -n "s/^\(firewall\.[^.]*\)\.name='wan'$/\1/p" | head -1)"
if [ -n "$WAN_ZONE" ]; then
    uci -q del_list "$WAN_ZONE.network=wwan" || true
    uci add_list "$WAN_ZONE.network=wwan"
fi

uci commit network
uci commit wireless
uci commit firewall

# 6) Aplicar cambios
/etc/init.d/network reload >/dev/null 2>&1 || true
wifi reload >/dev/null 2>&1 || wifi >/dev/null 2>&1 || true
ifup wwan >/dev/null 2>&1 || true
/etc/init.d/firewall reload >/dev/null 2>&1 || true

echo "[router] Estado wwan:"
ifstatus wwan 2>/dev/null || true
echo "[router] Selector wireless:"
uci -q get wireless.sta_uplink.device 2>/dev/null || true
uci -q get wireless.ap_captive.device 2>/dev/null || true
echo "[router] SSIDs:"
uci -q get wireless.sta_uplink.ssid 2>/dev/null || true
uci -q get wireless.ap_captive.ssid 2>/dev/null || true
EOF

log_ok "Configuración WiFi aplicada en router."
log_info "Verifica en el router:"
printf '  1) ifstatus wwan\n'
printf '  2) iwinfo\n'
printf '  3) nslookup google.com 192.168.1.1\n'
