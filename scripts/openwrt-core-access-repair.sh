#!/bin/sh
# openwrt-core-access-repair.sh — Recupera acceso de nodos core (Raspi4B/3B/3BPortal)
#
# Uso:
#   bash scripts/openwrt-core-access-repair.sh
#
# Qué hace:
#   - Reagrega IPs core como permanentes en allowed_clients.
#   - Limpia advertencias por IP (warned_clients).
#   - Limpia bloqueos de destino aplicados por IA (blocked_social_ips/blocked_porn_ips).
#   - Reinicia firewall y recarga dnsmasq.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

log_info "=== Reparación de acceso nodos core ==="
check_ssh_key
test_router_ssh

log_info "Reagregando IPs core como permanentes..."
for ip in "$ADMIN_IP" "$RASPI4B_IP" "$RASPI3B_IP" "$PORTAL_NODE_IP" "$AP_EXTENDER_IP" "$PORTAL_IP"; do
    validate_ip "$ip" || continue
    router_ssh "nft add element $NFT_TABLE $NFT_SET { $ip timeout 0s }" 2>/dev/null || true
    log_ok "IP core permanente: $ip"
done

log_info "Limpiando warned_clients para IPs core..."
for ip in "$ADMIN_IP" "$RASPI4B_IP" "$RASPI3B_IP" "$PORTAL_NODE_IP" "$AP_EXTENDER_IP" "$PORTAL_IP"; do
    validate_ip "$ip" || continue
    router_ssh "nft delete element ip captive warned_clients { $ip } >/dev/null 2>&1 || true"
done
log_ok "warned_clients limpiado para nodos core"

log_info "Flushing sets de bloqueo por destino (IA)..."
router_ssh "
    nft list set ip captive blocked_social_ips >/dev/null 2>&1 && nft flush set ip captive blocked_social_ips || true
    nft list set ip captive blocked_porn_ips >/dev/null 2>&1 && nft flush set ip captive blocked_porn_ips || true
" || true
log_ok "blocked_social_ips y blocked_porn_ips vaciados"

log_info "Saneando includes legacy de firewall para captive..."
router_ssh "
    for key in \$(uci -q show firewall 2>/dev/null | awk -F= '/=include$/{print \$1}'); do
        path=\$(uci -q get \"\$key.path\" 2>/dev/null || true)
        case \"\$path\" in
            */captive-portal.nft|*/captive-portal-fw4-include.sh)
                uci -q delete \"\$key\"
                ;;
        esac
    done
    # Migrar archivo legacy fuera de /etc/nftables.d para evitar parseo de fw4
    if [ -s /etc/nftables.d/captive-portal.nft ] && [ ! -s /etc/captive-portal.nft ]; then
        cp /etc/nftables.d/captive-portal.nft /etc/captive-portal.nft
    fi
    rm -f /etc/nftables.d/captive-portal.nft 2>/dev/null || true
    cat > /etc/captive-portal-fw4-include.sh <<'EOS'
#!/bin/sh
nft delete table ip captive 2>/dev/null || true
nft -f /etc/captive-portal.nft
exit \$?
EOS
    chmod 755 /etc/captive-portal-fw4-include.sh
    uci set firewall.captive_portal_nft='include'
    uci set firewall.captive_portal_nft.type='script'
    uci set firewall.captive_portal_nft.path='/etc/captive-portal-fw4-include.sh'
    uci set firewall.captive_portal_nft.enabled='1'
    uci commit firewall
" || true
log_ok "Include de firewall saneado"

log_info "Reiniciando firewall y recargando dnsmasq..."
router_ssh "/etc/init.d/firewall restart" || die "No se pudo reiniciar firewall"
router_ssh "/etc/init.d/dnsmasq reload 2>/dev/null || /etc/init.d/dnsmasq restart" || true
log_ok "Servicios recargados"

log_info "Validación rápida de tabla y permanentes..."
router_ssh "nft list table ip captive >/dev/null 2>&1" || die "No existe tabla ip captive tras reparación"
for ip in "$RASPI4B_IP" "$RASPI3B_IP" "$PORTAL_NODE_IP"; do
    validate_ip "$ip" || continue
    if router_ssh "nft get element $NFT_TABLE $NFT_SET { $ip } >/dev/null 2>&1"; then
        log_ok "$ip presente en allowed_clients"
    else
        log_warn "$ip no aparece en allowed_clients"
    fi
done

printf '\n'
log_ok "Reparación completada."
log_info "Siguiente paso recomendado:"
printf '  1) ejecutar setup-openwrt.sh actualizado\n'
printf '  2) verificar con openwrt-captive-doctor.sh\n'
