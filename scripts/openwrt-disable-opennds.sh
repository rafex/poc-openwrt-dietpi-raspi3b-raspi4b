#!/bin/sh
# openwrt-disable-opennds.sh
# Desactiva y limpia openNDS para volver al modo captive clásico (nft + dnsmasq).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

check_ssh_key
test_router_ssh

log_info "=== Desactivando openNDS en OpenWrt ==="

router_ssh "sh -s" <<'EOF'
set -eu

# 1) parar/disable servicio (si existe)
if [ -x /etc/init.d/opennds ]; then
  /etc/init.d/opennds stop >/dev/null 2>&1 || true
  /etc/init.d/opennds disable >/dev/null 2>&1 || true
fi

# 2) borrar config UCI de opennds para evitar residuos
if [ -f /etc/config/opennds ]; then
  cp /etc/config/opennds /etc/config/opennds.bak.$(date +%s) 2>/dev/null || true
  rm -f /etc/config/opennds
fi

# 3) limpiar include en firewall
uci -q delete firewall.opennds || true
uci commit firewall || true

# 4) quitar socket/pid temporales
rm -f /tmp/ndsctl.sock /var/run/opennds* /tmp/opennds* 2>/dev/null || true

# 5) recargar firewall para aplicar limpieza
/etc/init.d/firewall restart >/dev/null 2>&1 || /etc/init.d/firewall reload >/dev/null 2>&1 || true
EOF

log_ok "openNDS desactivado y limpiado"
log_info "Validación rápida:"
router_ssh "ps w | grep -q '[o]pennds' && echo 'WARN opennds sigue en procesos' || echo 'OK sin proceso opennds'"
router_ssh "ls -l /etc/config/opennds 2>/dev/null || echo 'OK /etc/config/opennds ausente'"

