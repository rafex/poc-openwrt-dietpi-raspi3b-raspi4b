#!/bin/sh
# setup-openwrt-wifi-uplink24-ap5.sh
#
# Modo WiFi solicitado:
#   - OpenWrt se conecta por 2.4GHz (STA) a SSID netup
#   - OpenWrt expone AP por 5GHz para clientes
#
# Uso:
#   bash scripts/setup-openwrt-wifi-uplink24-ap5.sh
#   bash scripts/setup-openwrt-wifi-uplink24-ap5.sh --uplink-ssid netup --uplink-pass 123 --ap-ssid "Rafex-Portal-5G"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

UPLINK_SSID="${UPLINK_SSID:-netup}"
UPLINK_PASS="${UPLINK_PASS:-123}"
AP_SSID="${AP_SSID:-Rafex Portal 5G}"
AP_OPEN="${AP_OPEN:-1}"      # 1: sin contraseña, 0: WPA2
AP_PASS="${AP_PASS:-}"

usage() {
    cat <<EOF
Uso:
  bash scripts/setup-openwrt-wifi-uplink24-ap5.sh [opciones]

Opciones:
  --uplink-ssid <ssid>   SSID uplink 2.4GHz (default: netup)
  --uplink-pass <pass>   Password uplink (default: 123)
  --ap-ssid <ssid>       SSID AP 5GHz (default: Rafex Portal 5G)
  --ap-open <0|1>        AP abierto (1) o WPA2 (0). Default: 1
  --ap-pass <pass>       Password AP si --ap-open 0
  -h, --help             Ayuda
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --uplink-ssid) [ -n "${2:-}" ] || die "Falta valor para --uplink-ssid"; UPLINK_SSID="$2"; shift 2 ;;
        --uplink-pass) [ -n "${2:-}" ] || die "Falta valor para --uplink-pass"; UPLINK_PASS="$2"; shift 2 ;;
        --ap-ssid) [ -n "${2:-}" ] || die "Falta valor para --ap-ssid"; AP_SSID="$2"; shift 2 ;;
        --ap-open) [ -n "${2:-}" ] || die "Falta valor para --ap-open"; AP_OPEN="$2"; shift 2 ;;
        --ap-pass) [ -n "${2:-}" ] || die "Falta valor para --ap-pass"; AP_PASS="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "Argumento no soportado: $1" ;;
    esac
done

case "$AP_OPEN" in
    0|1) ;;
    *) die "--ap-open debe ser 0 o 1" ;;
esac

if [ "$AP_OPEN" = "0" ]; then
    [ "${#AP_PASS}" -ge 8 ] || die "AP_PASS debe tener mínimo 8 caracteres para WPA2"
fi
[ "${#UPLINK_PASS}" -ge 1 ] || die "UPLINK_PASS vacío"

check_ssh_key
test_router_ssh

log_info "=== Configurando WiFi OpenWrt (2.4 uplink + 5 AP) ==="
log_info "Uplink SSID: $UPLINK_SSID"
log_info "AP SSID    : $AP_SSID"

router_ssh "sh -s -- '$UPLINK_SSID' '$UPLINK_PASS' '$AP_SSID' '$AP_OPEN' '$AP_PASS'" <<'EOF'
set -eu

UPLINK_SSID="$1"
UPLINK_PASS="$2"
AP_SSID="$3"
AP_OPEN="$4"
AP_PASS="$5"

find_radios() {
    R2=""
    R5=""
    for dev in $(uci show wireless | sed -n "s/^wireless\.\([^=]*\)=wifi-device$/\1/p"); do
        band="$(uci -q get wireless.$dev.band || true)"
        ch="$(uci -q get wireless.$dev.channel || true)"
        case "$band" in
            2g) [ -z "$R2" ] && R2="$dev" ;;
            5g) [ -z "$R5" ] && R5="$dev" ;;
        esac
        if [ -z "$R2" ]; then
            case "$ch" in
                1|2|3|4|5|6|7|8|9|10|11|12|13|14) R2="$dev" ;;
            esac
        fi
        if [ -z "$R5" ]; then
            case "$ch" in
                36|40|44|48|52|56|60|64|100|104|108|112|116|120|124|128|132|136|140|149|153|157|161|165) R5="$dev" ;;
            esac
        fi
    done
    [ -n "$R2" ] || R2="radio0"
    [ -n "$R5" ] || R5="radio1"
    printf '%s %s\n' "$R2" "$R5"
}

set -- $(find_radios)
RADIO_2G="$1"
RADIO_5G="$2"
echo "[router] radio 2.4 uplink: $RADIO_2G"
echo "[router] radio 5 AP    : $RADIO_5G"

# Desactivar wifi-ifaces previas conflictivas
for sec in $(uci show wireless | sed -n "s/^wireless\.\([^=]*\)=wifi-iface$/\1/p"); do
    case "$sec" in
        sta_uplink_24|ap_captive_5) ;;
        *) uci set "wireless.$sec.disabled=1" ;;
    esac
done

# Red wwan por DHCP
uci set network.wwan='interface'
uci set network.wwan.proto='dhcp'
uci set network.wwan.metric='20'

# STA 2.4GHz
uci set wireless.sta_uplink_24='wifi-iface'
uci set wireless.sta_uplink_24.device="$RADIO_2G"
uci set wireless.sta_uplink_24.mode='sta'
uci set wireless.sta_uplink_24.network='wwan'
uci set wireless.sta_uplink_24.ssid="$UPLINK_SSID"
uci set wireless.sta_uplink_24.encryption='psk2'
uci set wireless.sta_uplink_24.key="$UPLINK_PASS"
uci set wireless.sta_uplink_24.disabled='0'

# AP 5GHz
uci set wireless.ap_captive_5='wifi-iface'
uci set wireless.ap_captive_5.device="$RADIO_5G"
uci set wireless.ap_captive_5.mode='ap'
uci set wireless.ap_captive_5.network='lan'
uci set wireless.ap_captive_5.ssid="$AP_SSID"
if [ "$AP_OPEN" = "1" ]; then
    uci set wireless.ap_captive_5.encryption='none'
    uci -q delete wireless.ap_captive_5.key
else
    uci set wireless.ap_captive_5.encryption='psk2'
    uci set wireless.ap_captive_5.key="$AP_PASS"
fi
uci set wireless.ap_captive_5.disabled='0'

# firewall wan zone <- wwan
WAN_ZONE="$(uci show firewall | sed -n "s/^\(firewall\.[^.]*\)\.name='wan'$/\1/p" | head -1)"
if [ -n "$WAN_ZONE" ]; then
    uci -q del_list "$WAN_ZONE.network=wwan" || true
    uci add_list "$WAN_ZONE.network=wwan"
    uci set "$WAN_ZONE.masq='1'"
    uci set "$WAN_ZONE.mtu_fix='1'"
fi

# LAN forward sane + forwarding lan->wan (evita valor escapado roto)
LAN_ZONE="$(uci show firewall | sed -n "s/^\(firewall\.[^.]*\)\.name='lan'$/\1/p" | head -1)"
if [ -n "$LAN_ZONE" ]; then
    uci set "$LAN_ZONE.forward='ACCEPT'"
fi

# Dejar un solo forwarding src=lan dest=wan
LAN_WAN_COUNT=0
i=0
while uci get firewall.@forwarding[$i] >/dev/null 2>&1; do
    src="$(uci -q get firewall.@forwarding[$i].src || true)"
    dst="$(uci -q get firewall.@forwarding[$i].dest || true)"
    if [ "$src" = "lan" ] && [ "$dst" = "wan" ]; then
        LAN_WAN_COUNT=$((LAN_WAN_COUNT + 1))
        if [ "$LAN_WAN_COUNT" -gt 1 ]; then
            uci delete firewall.@forwarding[$i]
        fi
    fi
    i=$((i + 1))
done
if [ "$LAN_WAN_COUNT" -eq 0 ]; then
    uci add firewall forwarding >/dev/null
    uci set firewall.@forwarding[-1].src='lan'
    uci set firewall.@forwarding[-1].dest='wan'
fi

uci commit network
uci commit wireless
uci commit firewall

/etc/init.d/network reload >/dev/null 2>&1 || true
wifi reload >/dev/null 2>&1 || wifi >/dev/null 2>&1 || true
ifup wwan >/dev/null 2>&1 || true
/etc/init.d/firewall reload >/dev/null 2>&1 || true

echo "[router] ifstatus wwan:"
ifstatus wwan 2>/dev/null || true
echo "[router] firewall lan/wan sanity:"
uci -q get firewall.@zone[0].forward 2>/dev/null || true
uci show firewall | grep -n "forwarding" || true
echo "[router] nft forward chain excerpt:"
nft list ruleset 2>/dev/null | grep -n "chain forward\|br-lan\|forward_lan" || true
EOF

log_ok "WiFi configurado: uplink 2.4GHz + AP 5GHz"
log_info "Validación sugerida: ssh root@$ROUTER_IP 'ifstatus wwan; iwinfo'"
