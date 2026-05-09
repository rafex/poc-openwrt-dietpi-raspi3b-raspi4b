#!/bin/sh
# setup-openwrt-reserve-core-nodes.sh
# Reserva IPs estáticas (DHCP) para Raspi3B-sensor y Raspi4B-LLM.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

R3_HOST="${R3_HOST:-$RASPI3B_HOSTNAME}"
R3_IP="${R3_IP:-$RASPI3B_IP}"
R3_MAC="${R3_MAC:-$RASPI3B_MAC}"
R4_HOST="${R4_HOST:-$RASPI4B_HOSTNAME}"
R4_IP="${R4_IP:-$RASPI4B_IP}"
R4_MAC="${R4_MAC:-$RASPI4B_MAC}"

validate_ip "$R3_IP" || die "IP inválida R3: $R3_IP"
validate_ip "$R4_IP" || die "IP inválida R4: $R4_IP"

check_ssh_key
test_router_ssh

reserve_one() {
    _name="$1"; _mac="$2"; _ip="$3"
    router_ssh "sh -s -- '$_name' '$_mac' '$_ip'" <<'EOF'
set -eu
NAME="$1"; MAC="$2"; IP="$3"
IDX=""
i=0
while uci get dhcp.@host[$i] >/dev/null 2>&1; do
    cur_ip="$(uci -q get dhcp.@host[$i].ip || true)"
    cur_mac="$(uci -q get dhcp.@host[$i].mac || true)"
    if [ "$cur_ip" = "$IP" ] || [ "$cur_mac" = "$MAC" ]; then
        IDX="$i"
        break
    fi
    i=$((i+1))
done

if [ -n "$IDX" ]; then
    uci set dhcp.@host[$IDX].name="$NAME"
    uci set dhcp.@host[$IDX].mac="$MAC"
    uci set dhcp.@host[$IDX].ip="$IP"
    uci set dhcp.@host[$IDX].leasetime='infinite'
else
    uci add dhcp host >/dev/null
    uci set dhcp.@host[-1].name="$NAME"
    uci set dhcp.@host[-1].mac="$MAC"
    uci set dhcp.@host[-1].ip="$IP"
    uci set dhcp.@host[-1].leasetime='infinite'
fi
uci commit dhcp
EOF
}

log_info "=== Reservando IPs core en OpenWrt ==="
reserve_one "$R3_HOST" "$R3_MAC" "$R3_IP" || die "Falló reserva $R3_HOST"
log_ok "Reserva OK: $R3_HOST $R3_MAC -> $R3_IP"
reserve_one "$R4_HOST" "$R4_MAC" "$R4_IP" || die "Falló reserva $R4_HOST"
log_ok "Reserva OK: $R4_HOST $R4_MAC -> $R4_IP"

router_ssh "/etc/init.d/dnsmasq reload >/dev/null 2>&1 || /etc/init.d/dnsmasq restart >/dev/null 2>&1" || true
log_ok "dnsmasq recargado"

log_info "Reservas actuales (resumen):"
router_ssh "uci show dhcp | grep '=host' -n; uci show dhcp | grep -E '\\.name=|\\.mac=|\\.ip=|\\.leasetime='"

