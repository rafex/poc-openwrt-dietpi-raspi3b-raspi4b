#!/bin/sh
# openwrt-dns-spoof-disable.sh — Desactiva la demo de DNS poisoning
#
# Uso:
#   sh scripts/openwrt-dns-spoof-disable.sh
#
# Qué hace:
#   Elimina del dnsmasq del router todas las entradas de suplantación DNS
#   añadidas por openwrt-dns-spoof-enable.sh y recarga dnsmasq.
#   Tras esto, los dominios suplantados vuelven a resolver correctamente.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

# =============================================================================
# Pre-flight
# =============================================================================
check_ssh_key
test_router_ssh

# =============================================================================
# Eliminar bloque de dnsmasq.conf (si se insertó ahí)
# =============================================================================
log_info "Buscando bloque de DNS spoof demo en /etc/dnsmasq.conf..."

FOUND_IN_CONF=$(router_ssh \
    "grep -c 'dns-spoof-demo begin' /etc/dnsmasq.conf 2>/dev/null || echo 0" 2>/dev/null)

if [ "$FOUND_IN_CONF" -gt 0 ]; then
    router_ssh \
        "sed -i '/# --- dns-spoof-demo begin ---/,/# --- dns-spoof-demo end ---/d' /etc/dnsmasq.conf"
    log_ok "Bloque eliminado de /etc/dnsmasq.conf"
else
    log_info "No hay bloque en /etc/dnsmasq.conf"
fi

# =============================================================================
# Eliminar archivo de dnsmasq.d (si se creó ahí)
# =============================================================================
log_info "Buscando /etc/dnsmasq.d/dns-spoof-demo.conf..."

FILE_EXISTS=$(router_ssh \
    "[ -f /etc/dnsmasq.d/dns-spoof-demo.conf ] && echo 1 || echo 0" 2>/dev/null)

if [ "$FILE_EXISTS" = "1" ]; then
    router_ssh "rm /etc/dnsmasq.d/dns-spoof-demo.conf"
    log_ok "Eliminado /etc/dnsmasq.d/dns-spoof-demo.conf"
else
    log_info "No existe /etc/dnsmasq.d/dns-spoof-demo.conf"
fi

# =============================================================================
# Verificar que no quedó nada
# =============================================================================
if [ "$FOUND_IN_CONF" -eq 0 ] && [ "$FILE_EXISTS" = "0" ]; then
    log_warn "No se encontró ninguna configuración de DNS spoof activa."
    log_warn "Puede que nunca se haya activado o ya estuviera desactivada."
    exit 0
fi

# =============================================================================
# Recargar dnsmasq
# =============================================================================
log_info "Recargando dnsmasq..."
router_ssh "/etc/init.d/dnsmasq reload 2>/dev/null || /etc/init.d/dnsmasq restart" \
    && log_ok "dnsmasq recargado" \
    || log_warn "No se pudo recargar dnsmasq — reinicia manualmente"

# =============================================================================
# Verificar que la resolución DNS volvió a la normalidad
# =============================================================================
log_info "Verificando que rafex.dev ya NO resuelve a la Pi..."
RESOLVED=$(router_ssh \
    "nslookup rafex.dev 127.0.0.1 2>/dev/null | awk '/^Address/ && NR>2 {print \$2}' | head -1" \
    2>/dev/null)

if [ "$RESOLVED" = "$PORTAL_IP" ]; then
    log_warn "rafex.dev aún resuelve a $PORTAL_IP — puede haber caché. Espera unos segundos."
elif [ -z "$RESOLVED" ]; then
    log_ok "rafex.dev ya no tiene entrada local — se resolverá por DNS upstream (correcto)"
else
    log_ok "rafex.dev resuelve a $RESOLVED (servidor real)"
fi

# =============================================================================
# Eliminar recursos k8s del deployment dns-spoof
# =============================================================================
K8S_DIR="$(dirname "$SCRIPT_DIR")/k8s"
log_info "Eliminando deployment dns-spoof de k3s..."
kubectl delete -f "$K8S_DIR/dns-spoof-ingress.yaml" --ignore-not-found=true 2>/dev/null
kubectl delete -f "$K8S_DIR/dns-spoof-svc.yaml" --ignore-not-found=true 2>/dev/null
kubectl delete -f "$K8S_DIR/dns-spoof-deployment.yaml" --ignore-not-found=true 2>/dev/null
kubectl delete -f "$K8S_DIR/dns-spoof-configmap.yaml" --ignore-not-found=true 2>/dev/null
log_ok "Recursos k8s dns-spoof eliminados"

printf '\n'
log_ok "=== Demo DNS Poisoning DESACTIVADA ==="
printf '\n'
log_info "Los dominios vuelven a resolver con el DNS real del ISP."
log_info "Para volver a activar: sh scripts/openwrt-dns-spoof-enable.sh"
