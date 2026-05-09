#!/bin/sh
# openwrt-install-usb-overlay.sh
# Configura una USB (ext4) como overlay persistente en OpenWrt.
#
# Flujo:
# 1) Detecta UUID con block info (o usa --uuid)
# 2) Escribe /etc/config/fstab con target /overlay
# 3) Monta USB en /mnt/usb
# 4) Copia /overlay actual -> /mnt/usb
# 5) sync + reboot

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

USB_DEV="${USB_DEV:-/dev/sda1}"
USB_UUID="${USB_UUID:-}"
NO_REBOOT=0

usage() {
    cat <<EOF
Uso:
  bash scripts/openwrt-install-usb-overlay.sh [opciones]

Opciones:
  --device <dev>   Dispositivo USB (default: /dev/sda1)
  --uuid <uuid>    UUID explícito (si se omite se detecta con block info)
  --no-reboot      No reinicia al final
  -h, --help       Muestra ayuda
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --device)
            [ -n "${2:-}" ] || die "Falta valor para --device"
            USB_DEV="$2"
            shift 2
            ;;
        --uuid)
            [ -n "${2:-}" ] || die "Falta valor para --uuid"
            USB_UUID="$2"
            shift 2
            ;;
        --no-reboot)
            NO_REBOOT=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Argumento no soportado: $1"
            ;;
    esac
done

check_ssh_key
test_router_ssh

log_info "=== Instalar USB como overlay en OpenWrt ==="
log_info "Router: $ROUTER_IP"
log_info "Dispositivo USB: $USB_DEV"

if [ -z "$USB_UUID" ]; then
    log_info "Detectando UUID desde block info..."
    USB_UUID="$(router_ssh "block info '$USB_DEV' 2>/dev/null | sed -n 's/.*UUID=\"\\([^\"]*\\)\".*/\\1/p' | head -1")"
fi

[ -n "$USB_UUID" ] || die "No se pudo obtener UUID de $USB_DEV. Verifica: block info"
log_ok "UUID detectado: $USB_UUID"

log_info "Verificando que el tipo de FS sea ext4..."
USB_TYPE="$(router_ssh "block info '$USB_DEV' 2>/dev/null | sed -n 's/.*TYPE=\"\\([^\"]*\\)\".*/\\1/p' | head -1")"
[ "$USB_TYPE" = "ext4" ] || die "El dispositivo $USB_DEV no es ext4 (detectado: ${USB_TYPE:-desconocido})"
log_ok "FS válido: ext4"

log_info "Respaldando fstab actual..."
router_ssh "cp /etc/config/fstab /etc/config/fstab.bak-\$(date +%Y%m%d-%H%M%S) 2>/dev/null || true"
log_ok "Respaldo de fstab creado"

log_info "Escribiendo /etc/config/fstab (overlay en USB)..."
router_ssh "cat > /etc/config/fstab" <<EOF
config 'global'
        option anon_swap '0'
        option anon_mount '0'
        option auto_swap '1'
        option auto_mount '1'
        option delay_root '15'
        option check_fs '0'

config 'mount'
        option target '/overlay'
        option uuid '$USB_UUID'
        option fstype 'ext4'
        option options 'rw,sync'
        option enabled '1'
        option enabled_fsck '0'
EOF
log_ok "fstab actualizado"

log_info "Aplicando configuración de fstab..."
router_ssh "uci commit fstab && /etc/init.d/fstab boot >/dev/null 2>&1 || true"

log_info "Copiando overlay actual a USB..."
router_ssh "mkdir -p /mnt/usb && umount /mnt/usb 2>/dev/null || true"
router_ssh "mount '$USB_DEV' /mnt/usb" || die "No se pudo montar $USB_DEV en /mnt/usb"
router_ssh "tar -C /overlay -cvf - . | tar -C /mnt/usb -xf -" || die "Falló copia de /overlay a USB"
router_ssh "sync && umount /mnt/usb" || true
log_ok "Contenido de /overlay copiado a USB"

if [ "$NO_REBOOT" -eq 1 ]; then
    log_warn "Configuración aplicada sin reinicio (--no-reboot). Reinicia manualmente para activar overlay USB."
    exit 0
fi

log_info "Reiniciando router para activar nuevo overlay..."
router_ssh "reboot" >/dev/null 2>&1 || true
log_ok "Comando reboot enviado"
log_info "Espera ~60-90s y valida con: ssh root@$ROUTER_IP 'mount | grep overlay'"

