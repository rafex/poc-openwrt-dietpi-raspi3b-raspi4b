#!/bin/sh
# Diagnóstico puntual de activación de captive portal en OpenWrt.
# Uso:
#   bash scripts/openwrt-captive-doctor.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

CAPTIVE_DOMAIN="${CAPTIVE_DOMAIN:-captive.localhost.com}"
PEOPLE_DOMAIN="${PEOPLE_DOMAIN:-people.localhost.com}"

log_info "=== OpenWrt Captive Doctor ==="
log_info "Topología esperada: ${TOPOLOGY:-legacy}"
log_info "Portal esperado: $PORTAL_IP"
log_info "Router: $ROUTER_IP"

check_ssh_key
test_router_ssh

FAIL=0

check_ok() { log_ok "$*"; }
check_warn() { log_warn "$*"; FAIL=1; }

# 1) DHCP option 114 (URL del portal) y DNS option 6
OPTS="$(router_ssh "uci -q get dhcp.lan.dhcp_option 2>/dev/null || true")"
OPTS_SPLIT="$(printf '%s\n' "$OPTS" | tr ' ' '\n')"
OPT114="$(printf '%s\n' "$OPTS_SPLIT" | grep '^114,' | tail -1)"
OPT6="$(printf '%s\n' "$OPTS_SPLIT" | grep '^6,' | tail -1)"

if [ -n "$OPT114" ] && printf '%s' "$OPT114" | grep -q "http://$PORTAL_IP/portal"; then
  check_ok "DHCP option 114 OK: $OPT114"
else
  check_warn "DHCP option 114 incorrecta o ausente (actual: ${OPT114:-<vacía>})"
fi

if [ -n "$OPT6" ] && printf '%s' "$OPT6" | grep -q "6,$ROUTER_IP"; then
  check_ok "DHCP option 6 OK: $OPT6"
else
  check_warn "DHCP option 6 incorrecta o ausente (actual: ${OPT6:-<vacía>})"
fi

# 2) DNS de detección captive -> portal_ip
check_dns_domain() {
  dom="$1"
  resolved="$(router_ssh "nslookup '$dom' 127.0.0.1 2>/dev/null | grep -Eo '([0-9]{1,3}\\.){3}[0-9]{1,3}' | tail -1")"
  if [ "$resolved" = "$PORTAL_IP" ]; then
    check_ok "DNS $dom -> $resolved"
  else
    check_warn "DNS $dom -> ${resolved:-<sin respuesta>} (esperado $PORTAL_IP)"
  fi
}

check_dns_domain connectivitycheck.gstatic.com
check_dns_domain captive.apple.com
check_dns_domain www.msftconnecttest.com
check_dns_domain "$CAPTIVE_DOMAIN"
check_dns_domain "$PEOPLE_DOMAIN"

# 3) nftables: tabla, dnat y permanentes
if router_table_exists; then
  check_ok "Tabla nftables $NFT_TABLE existe"
else
  check_warn "Tabla nftables $NFT_TABLE NO existe"
fi

DNAT_RULE="$(router_ssh "nft list chain ip captive prerouting 2>/dev/null | grep -F 'dnat to $PORTAL_IP:80' | head -1")"
if [ -n "$DNAT_RULE" ]; then
  check_ok "DNAT a portal detectado: $DNAT_RULE"
else
  check_warn "No se encontró regla DNAT hacia $PORTAL_IP:80 en chain prerouting"
fi

for ip in "$ADMIN_IP" "$RASPI4B_IP" "$RASPI3B_IP" "$PORTAL_IP"; do
  if router_ip_in_set "$ip"; then
    check_ok "IP permanente en set: $ip"
  else
    check_warn "IP no presente en set allowed_clients: $ip"
  fi
done

# 4) Reachability HTTP del portal desde el router
PORTAL_CODE="$(router_ssh "uclient-fetch -T 5 -qO- http://$PORTAL_IP/portal >/dev/null 2>&1; echo \$?" 2>/dev/null)"
if [ "$PORTAL_CODE" = "0" ]; then
  check_ok "Router alcanza http://$PORTAL_IP/portal"
else
  check_warn "Router NO alcanza http://$PORTAL_IP/portal"
fi

# 5) Endpoints típicos de detección (desde host actual)
probe_local() {
  path="$1"
  code="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 4 --max-time 8 "http://$PORTAL_IP$path" 2>/dev/null || echo 000)"
  case "$code" in
    200|301|302|307|308) check_ok "Probe $path -> HTTP $code" ;;
    *) check_warn "Probe $path -> HTTP $code (esperado redirect/200)" ;;
  esac
}
probe_local /portal
probe_local /generate_204
probe_local /hotspot-detect.html
probe_local /connecttest.txt

printf '\n'
if [ "$FAIL" -eq 0 ]; then
  log_ok "Captive Doctor: configuración consistente"
  exit 0
fi

log_warn "Captive Doctor detectó inconsistencias"
log_info "Reparación sugerida:"
printf '  bash scripts/setup-openwrt.sh --topology %s --portal-ip %s --ai-ip %s\n' \
  "${TOPOLOGY:-legacy}" "$PORTAL_IP" "${AI_IP:-$RASPI4B_IP}"
exit 1
