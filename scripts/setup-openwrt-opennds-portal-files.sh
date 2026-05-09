#!/bin/sh
# setup-openwrt-opennds-portal-files.sh
# Sube HTML del portal Lentium al router OpenWrt (/www/portal) y configura uhttpd.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

PORTAL_SRC_DIR="${PORTAL_SRC_DIR:-$REPO_DIR/backend/captive-portal-lentium}"
ROUTER_PORTAL_DIR="${ROUTER_PORTAL_DIR:-/www/portal}"

usage() {
    cat <<EOF
Uso:
  bash scripts/setup-openwrt-opennds-portal-files.sh [opciones]

Opciones:
  --src-dir <ruta>       Directorio local con HTML (default: backend/captive-portal-lentium)
  --router-dir <ruta>    Directorio destino en OpenWrt (default: /www/portal)
  -h, --help             Muestra esta ayuda
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --src-dir)
            [ -n "${2:-}" ] || die "Falta valor para --src-dir"
            PORTAL_SRC_DIR="$2"
            shift 2
            ;;
        --router-dir)
            [ -n "${2:-}" ] || die "Falta valor para --router-dir"
            ROUTER_PORTAL_DIR="$2"
            shift 2
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

[ -d "$PORTAL_SRC_DIR" ] || die "No existe directorio fuente: $PORTAL_SRC_DIR"
HTML_COUNT="$(find "$PORTAL_SRC_DIR" -maxdepth 1 -type f -name '*.html' | wc -l | tr -d ' ')"
[ "${HTML_COUNT:-0}" -gt 0 ] || die "No se encontraron archivos .html en: $PORTAL_SRC_DIR"

check_ssh_key
test_router_ssh

log_info "=== Instalando portal estático en OpenWrt (uhttpd) ==="
log_info "Fuente local : $PORTAL_SRC_DIR"
log_info "Destino router: $ROUTER_PORTAL_DIR"

log_info "Preparando directorio destino..."
router_ssh "mkdir -p '$ROUTER_PORTAL_DIR'" || die "No se pudo crear $ROUTER_PORTAL_DIR"

log_info "Copiando HTML al router..."
scp \
    -i "$SSH_KEY" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=10 \
    "$PORTAL_SRC_DIR"/*.html root@"$ROUTER_IP":"$ROUTER_PORTAL_DIR"/ \
    >/dev/null 2>&1 || die "Falló la copia SCP de HTML al router"

log_info "Aplicando permisos..."
router_ssh "chmod 755 /www '$ROUTER_PORTAL_DIR' && chmod 644 '$ROUTER_PORTAL_DIR'/*.html" \
    || die "No se pudieron aplicar permisos en $ROUTER_PORTAL_DIR"

log_info "Configurando uhttpd.home=/www..."
router_ssh "uci set uhttpd.main.home='/www' && uci commit uhttpd && /etc/init.d/uhttpd restart" \
    || die "No se pudo configurar/reiniciar uhttpd"

log_ok "Portal HTML desplegado en OpenWrt."
log_info "Prueba sugerida:"
log_info "  wget -O- http://$ROUTER_IP/portal/portal.html | head"

