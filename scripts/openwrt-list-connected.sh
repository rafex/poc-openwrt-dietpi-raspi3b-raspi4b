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
trap 'rm -f "$TMP_WIFI_MACS" "$TMP_WIFI_ASSOC" "$TMP_LEASES"' EXIT

# ── 1) Recolectar MACs WiFi asociadas ───────────────────────────────────────
touch "$TMP_WIFI_MACS" "$TMP_WIFI_ASSOC"
if command -v iwinfo >/dev/null 2>&1; then
  for ifc in $(iwinfo 2>/dev/null | awk -F' ' '/ESSID/{print $1}'); do
    iwinfo "$ifc" assoclist 2>/dev/null | awk 'NR%2==1 && $1 ~ /:/{print tolower($1)}' >> "$TMP_WIFI_MACS"
    iwinfo "$ifc" assoclist 2>/dev/null | awk -v I="$ifc" 'NR%2==1 && $1 ~ /:/{print tolower($1)" "I}' >> "$TMP_WIFI_ASSOC"
  done
fi
sort -u "$TMP_WIFI_MACS" -o "$TMP_WIFI_MACS" 2>/dev/null || true

# ── 2) Leer leases DHCP ──────────────────────────────────────────────────────
awk '
  {
    exp=$1; mac=tolower($2); ip=$3; host=$4;
    if (host=="*") host="-";
    print exp "|" mac "|" ip "|" host
  }
' "$LEASES" > "$TMP_LEASES"

COUNT="$(wc -l < "$TMP_LEASES" | tr -d ' ')"
echo "[INFO]  Leases DHCP activos: $COUNT"
echo
printf '%-16s  %-17s  %-9s  %-10s  %s\n' "IP" "MAC" "MEDIO" "EXPIRA" "HOSTNAME"
printf '%-16s  %-17s  %-9s  %-10s  %s\n' "----------------" "-----------------" "---------" "----------" "----------------"

while IFS='|' read -r exp mac ip host; do
  [ -n "$ip" ] || continue
  medio="ethernet"
  if grep -qx "$mac" "$TMP_WIFI_MACS" 2>/dev/null; then
    medio="wifi"
  fi
  now="$(date +%s)"
  if [ "$exp" -gt "$now" ] 2>/dev/null; then
    left="$((exp-now))s"
  else
    left="expired"
  fi
  printf '%-16s  %-17s  %-9s  %-10s  %s\n' "$ip" "$mac" "$medio" "$left" "$host"
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

