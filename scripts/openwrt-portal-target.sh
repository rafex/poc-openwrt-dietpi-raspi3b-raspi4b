#!/bin/sh
# openwrt-portal-target.sh — Muestra a qué portal está apuntando OpenWrt
# Uso:
#   bash scripts/openwrt-portal-target.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

CAPTIVE_DOMAIN="${CAPTIVE_DOMAIN:-captive.localhost.com}"
PEOPLE_DOMAIN="${PEOPLE_DOMAIN:-people.localhost.com}"

log_info "=== Portal target en OpenWrt ==="
log_info "Topología esperada: ${TOPOLOGY:-legacy}"
log_info "IP esperada de portal (según config local): $PORTAL_IP"

check_ssh_key
test_router_ssh

DHCP_OPTS="$(router_ssh "uci -q get dhcp.lan.dhcp_option 2>/dev/null || true")"
OPT_114="$(printf '%s\n' "$DHCP_OPTS" | grep '^114,' | tail -1)"
TARGET_URL="${OPT_114#114,}"
TARGET_IP="$(printf '%s\n' "$TARGET_URL" | sed -n 's#.*://\([0-9][0-9.]*\).*#\1#p')"

DNS_CAPTIVE_LINE="$(router_ssh "grep -E '^address=/${CAPTIVE_DOMAIN//./\\.}/' /etc/dnsmasq.conf 2>/dev/null | tail -1")"
DNS_PEOPLE_LINE="$(router_ssh "grep -E '^address=/${PEOPLE_DOMAIN//./\\.}/' /etc/dnsmasq.conf 2>/dev/null | tail -1")"
DNS_CAPTIVE_IP="${DNS_CAPTIVE_LINE##*/}"
DNS_PEOPLE_IP="${DNS_PEOPLE_LINE##*/}"

NS_CAPTIVE="$(router_ssh "nslookup '$CAPTIVE_DOMAIN' 127.0.0.1 2>/dev/null | awk '/^Address [0-9]+: /{print \$3}' | tail -1")"
NS_PEOPLE="$(router_ssh "nslookup '$PEOPLE_DOMAIN' 127.0.0.1 2>/dev/null | awk '/^Address [0-9]+: /{print \$3}' | tail -1")"

printf '\n'
log_info "DHCP option 114 (URL portal):"
if [ -n "$TARGET_URL" ]; then
    printf '  %s\n' "$TARGET_URL"
    printf '  IP detectada: %s\n' "${TARGET_IP:-<no detectada>}"
else
    log_warn "No se encontró option 114 en dhcp.lan.dhcp_option"
fi

printf '\n'
log_info "dnsmasq (bloque captive):"
printf '  %s -> %s\n' "$CAPTIVE_DOMAIN" "${DNS_CAPTIVE_IP:-<sin regla>}"
printf '  %s -> %s\n' "$PEOPLE_DOMAIN" "${DNS_PEOPLE_IP:-<sin regla>}"

printf '\n'
log_info "Resolución real en el router (nslookup 127.0.0.1):"
printf '  %s -> %s\n' "$CAPTIVE_DOMAIN" "${NS_CAPTIVE:-<sin respuesta>}"
printf '  %s -> %s\n' "$PEOPLE_DOMAIN" "${NS_PEOPLE:-<sin respuesta>}"

printf '\n'
MISMATCH=0
if [ -n "$TARGET_IP" ] && [ "$TARGET_IP" != "$PORTAL_IP" ]; then
    log_warn "option 114 apunta a $TARGET_IP pero la IP esperada local es $PORTAL_IP"
    MISMATCH=1
fi
if [ -n "$DNS_CAPTIVE_IP" ] && [ "$DNS_CAPTIVE_IP" != "$PORTAL_IP" ]; then
    log_warn "$CAPTIVE_DOMAIN apunta a $DNS_CAPTIVE_IP pero la IP esperada local es $PORTAL_IP"
    MISMATCH=1
fi
if [ -n "$DNS_PEOPLE_IP" ] && [ "$DNS_PEOPLE_IP" != "$PORTAL_IP" ]; then
    log_warn "$PEOPLE_DOMAIN apunta a $DNS_PEOPLE_IP pero la IP esperada local es $PORTAL_IP"
    MISMATCH=1
fi

if [ "$MISMATCH" -eq 0 ]; then
    log_ok "OpenWrt está apuntando al portal esperado: $PORTAL_IP"
else
    printf '\n'
    log_info "Para corregir:"
    printf '  bash scripts/setup-openwrt.sh --topology %s --portal-ip %s --ai-ip %s\n' \
        "${TOPOLOGY:-legacy}" "$PORTAL_IP" "${AI_IP:-$RASPI4B_IP}"
fi
