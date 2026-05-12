#!/bin/sh
# openwrt-enable-usb-persistent-logs.sh
# Configura logs persistentes en OpenWrt usando /overlay (ideal: overlay en USB).
#
# Cambios:
#   /etc/config/system:
#     option log_file '/overlay/log/messages'
#     option log_size '0'
#     option log_proto 'file'
#   mkdir -p /overlay/log
#   /etc/init.d/log restart
#
# Uso:
#   bash scripts/openwrt-enable-usb-persistent-logs.sh
#   bash scripts/openwrt-enable-usb-persistent-logs.sh --no-reboot

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

DO_REBOOT=1

usage() {
    cat <<EOF
Uso:
  bash scripts/openwrt-enable-usb-persistent-logs.sh [opciones]

Opciones:
  --no-reboot   No reinicia el router al final
  -h, --help    Muestra ayuda
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --no-reboot) DO_REBOOT=0; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Argumento no soportado: $1" ;;
    esac
done

check_ssh_key
test_router_ssh

log_info "=== Habilitando logs persistentes en /overlay ==="

log_info "Verificando mountpoint /overlay..."
OVERLAY_SRC="$(router_ssh "mount | awk '\$3==\"/overlay\" {print \$1}' | head -1")"
[ -n "$OVERLAY_SRC" ] || die "No se detectó /overlay montado."
log_ok "/overlay montado desde: $OVERLAY_SRC"

if [ "$OVERLAY_SRC" = "overlayfs:/overlay" ] || [ "$OVERLAY_SRC" = "overlayfs:/tmp/root" ]; then
    log_warn "Parece overlay interno, no USB. Puedes continuar, pero no ganarás persistencia extra por USB."
fi

log_info "Respaldando /etc/config/system..."
router_ssh "cp /etc/config/system /etc/config/system.bak-\$(date +%Y%m%d-%H%M%S)" \
    || die "No se pudo respaldar /etc/config/system"

log_info "Aplicando configuración de logging a archivo..."
router_ssh "sh -s" <<'EOF'
set -eu
uci set system.@system[0].log_file='/overlay/log/messages'
uci set system.@system[0].log_size='0'
uci set system.@system[0].log_proto='file'
uci commit system
mkdir -p /overlay/log
chmod 700 /overlay/log
/etc/init.d/log restart
EOF

[ "$?" -eq 0 ] || die "No se pudo aplicar la configuración de logs"
log_ok "Configuración aplicada"

log_info "Validando archivos y últimas líneas..."
router_ssh "sleep 1; logread | tail -20; ls -lh /overlay/log; ls -l /overlay/log/messages 2>/dev/null || true"

if [ "$DO_REBOOT" -eq 1 ]; then
    log_info "Reiniciando router..."
    router_ssh "reboot" >/dev/null 2>&1 || true
    log_ok "Comando reboot enviado"
    log_info "Espera ~60s y valida:"
    log_info "  ssh root@$ROUTER_IP 'logread | tail; ls -lh /overlay/log'"
else
    log_warn "Sin reboot (--no-reboot). Configuración activa tras restart de logd."
fi

