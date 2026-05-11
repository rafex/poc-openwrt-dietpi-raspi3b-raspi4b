#!/bin/sh
# openwrt-list-connected.sh
# Lista dispositivos conectados al router OpenWrt:
#   - DHCP leases activos
#   - Clientes WiFi asociados (MAC por radio)
#   - Clasificación aproximada: wifi / ethernet / unknown
#
# Uso:
#   bash scripts/openwrt-list-connected.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

check_ssh_key
test_router_ssh

log_info "=== Clientes conectados en OpenWrt ==="
log_info "Router: $ROUTER_IP"

router_ssh "sh -s" <<'EOF'
set -eu

LEASES="/tmp/dhcp.leases"
[ -f "$LEASES" ] || { echo "[WARN]  No existe $LEASES"; exit 0; }

TMP_WIFI_MACS="/tmp/.wifi-macs.$$"
TMP_WIFI_ASSOC="/tmp/.wifi-assoc.$$"
TMP_LEASES="/tmp/.leases.$$"
TMP_ALLOWED_IPS="/tmp/.allowed-ips.$$"
trap 'rm -f "$TMP_WIFI_MACS" "$TMP_WIFI_ASSOC" "$TMP_LEASES" "$TMP_ALLOWED_IPS"' EXIT

# ── 1) Recolectar MACs WiFi asociadas ───────────────────────────────────────
touch "$TMP_WIFI_MACS" "$TMP_WIFI_ASSOC"
if command -v iwinfo >/dev/null 2>&1; then
  for ifc in $(iwinfo 2>/dev/null | awk -F' ' '/ESSID/{print $1}'); do
    iwinfo "$ifc" assoclist 2>/dev/null | awk 'NR%2==1 && $1 ~ /:/{print tolower($1)}' >> "$TMP_WIFI_MACS"
    iwinfo "$ifc" assoclist 2>/dev/null | awk -v I="$ifc" 'NR%2==1 && $1 ~ /:/{print tolower($1)" "I}' >> "$TMP_WIFI_ASSOC"
  done
fi
sort -u "$TMP_WIFI_MACS" -o "$TMP_WIFI_MACS" 2>/dev/null || true

# ── 1.1) Recolectar IPs autorizadas en nft set allowed_clients ───────────────
touch "$TMP_ALLOWED_IPS"
if nft list set ip captive allowed_clients >/dev/null 2>&1; then
  nft list set ip captive allowed_clients 2>/dev/null \
    | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' \
    | sort -u > "$TMP_ALLOWED_IPS" || true
fi

# ── 2) Leer leases DHCP ──────────────────────────────────────────────────────
awk '
  {
    lease_exp=$1; mac=tolower($2); ip=$3; host=$4;
    if (host=="*") host="-";
    print lease_exp "|" mac "|" ip "|" host
  }
' "$LEASES" > "$TMP_LEASES"

COUNT="$(wc -l < "$TMP_LEASES" | tr -d ' ')"
echo "[INFO]  Leases DHCP activos: $COUNT"
echo
printf '%-16s  %-17s  %-9s  %-11s  %-10s  %s\n' "IP" "MAC" "MEDIO" "AUTORIZADO" "EXPIRA" "HOSTNAME"
printf '%-16s  %-17s  %-9s  %-11s  %-10s  %s\n' "----------------" "-----------------" "---------" "-----------" "----------" "----------------"

while IFS='|' read -r lease_exp mac ip host; do
  [ -n "$ip" ] || continue
  medio="ethernet"
  if grep -qx "$mac" "$TMP_WIFI_MACS" 2>/dev/null; then
    medio="wifi"
  fi
  autorizado="no"
  if grep -qx "$ip" "$TMP_ALLOWED_IPS" 2>/dev/null; then
    autorizado="yes"
  fi
  now="$(date +%s)"
  if [ "$lease_exp" -gt "$now" ] 2>/dev/null; then
    left="$((lease_exp-now))s"
  else
    left="expired"
  fi
  printf '%-16s  %-17s  %-9s  %-11s  %-10s  %s\n' "$ip" "$mac" "$medio" "$autorizado" "$left" "$host"
done < "$TMP_LEASES"

echo
echo "[INFO]  Clientes WiFi asociados por interfaz:"
if [ -s "$TMP_WIFI_ASSOC" ]; then
  sort -u "$TMP_WIFI_ASSOC" | while read -r mac ifc; do
    printf '  %-17s  %s\n' "$mac" "$ifc"
  done
else
  echo "  (sin asociaciones WiFi activas)"
fi
EOF
