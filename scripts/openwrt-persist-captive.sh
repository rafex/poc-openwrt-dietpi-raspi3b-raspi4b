#!/bin/sh
# openwrt-persist-captive.sh — Fuerza persistencia del captive portal en OpenWrt (fw4 include)
#
# Uso:
#   bash scripts/openwrt-persist-captive.sh
#
# Qué hace:
#   1) Verifica acceso SSH al router.
#   2) Asegura include persistente de /etc/nftables.d/captive-portal.nft en UCI firewall.
#   3) Reinicia firewall y valida tabla ip captive.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

log_info "=== Persistencia Captive Portal (OpenWrt) ==="

check_ssh_key
test_router_ssh

log_info "Validando archivo nft persistente en el router..."
if ! router_ssh "[ -s /etc/nftables.d/captive-portal.nft ]"; then
    die "No existe /etc/nftables.d/captive-portal.nft en el router.
Ejecuta primero: bash scripts/setup-openwrt.sh"
fi
log_ok "Archivo presente: /etc/nftables.d/captive-portal.nft"

log_info "Configurando include UCI en firewall (fw4)..."
router_ssh "
    # Limpiar includes legacy (anónimos o nombrados) que apunten al captive portal
    for sec in \$(uci show firewall 2>/dev/null | sed -n \"s/^firewall\\.\\([^=]*\\)=include$/\\1/p\"); do
        path=\$(uci -q get firewall.\$sec.path 2>/dev/null || true)
        case \"\$path\" in
            */captive-portal.nft|*/captive-portal-fw4-include.sh)
                uci -q delete firewall.\$sec
                ;;
        esac
    done

    cat > /etc/captive-portal-fw4-include.sh <<'EOS'
#!/bin/sh
nft delete table ip captive 2>/dev/null || true
nft -f /etc/nftables.d/captive-portal.nft
exit \$?
EOS
    chmod 755 /etc/captive-portal-fw4-include.sh

    uci -q delete firewall.captive_portal_nft
    uci set firewall.captive_portal_nft='include'
    uci set firewall.captive_portal_nft.type='script'
    uci set firewall.captive_portal_nft.path='/etc/captive-portal-fw4-include.sh'
    uci set firewall.captive_portal_nft.enabled='1'
    uci commit firewall
" || die "No se pudo configurar include persistente en UCI firewall"
log_ok "Include UCI configurado: firewall.captive_portal_nft"

log_info "Reiniciando firewall para aplicar include..."
router_ssh "/etc/init.d/firewall restart" || die "No se pudo reiniciar firewall"
log_ok "Firewall reiniciado"

log_info "Verificando tabla nftables captive..."
if router_ssh "nft list table ip captive >/dev/null 2>&1"; then
    log_ok "Tabla ip captive activa después de reinicio de firewall"
else
    die "La tabla ip captive no está activa tras restart de firewall"
fi

INC="$(router_ssh "uci -q show firewall.captive_portal_nft" 2>/dev/null || true)"
log_info "Include registrado:"
printf '%s\n' "$INC"

printf '\n'
log_ok "Persistencia corregida."
log_info "Próxima validación recomendada:"
printf '  1) reboot del router\n'
printf '  2) bash scripts/openwrt-captive-doctor.sh\n'
