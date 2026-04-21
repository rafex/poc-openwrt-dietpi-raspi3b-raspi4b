#!/bin/sh
# openwrt-dns-spoof-enable.sh — Activa la demo de DNS poisoning
#
# Uso:
#   sh scripts/openwrt-dns-spoof-enable.sh
#   sh scripts/openwrt-dns-spoof-enable.sh --domain otro.com
#   sh scripts/openwrt-dns-spoof-enable.sh --domain a.com --domain b.com
#
# Qué hace:
#   Agrega entradas en dnsmasq del router para que los dominios indicados
#   resuelvan a la Pi (192.168.1.167) en lugar de sus servidores reales.
#   El navegador del cliente llega a la Pi, que sirve una página explicando
#   el ataque de DNS poisoning.
#
# Para desactivar:
#   sh scripts/openwrt-dns-spoof-disable.sh
#
# Nota: solo funciona con HTTP (puerto 80). Con HTTPS el navegador mostrará
# error de certificado — que es en sí mismo parte del aprendizaje.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

# =============================================================================
# Dominios por defecto y argumentos
# =============================================================================
DOMAINS="rafex.dev www.rafex.dev"
EXTRA_DOMAINS=""

while [ $# -gt 0 ]; do
    case "$1" in
        --domain|-d)
            shift
            EXTRA_DOMAINS="$EXTRA_DOMAINS $1"
            ;;
        --domain=*)
            EXTRA_DOMAINS="$EXTRA_DOMAINS ${1#--domain=}"
            ;;
        --help|-h)
            sed -n '2,20p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            die "Argumento desconocido: '$1'
  Uso: sh $0 [--domain dominio.com] [--domain otro.com]"
            ;;
    esac
    shift
done

ALL_DOMAINS="$DOMAINS $EXTRA_DOMAINS"

# =============================================================================
# Pre-flight
# =============================================================================
check_ssh_key
test_router_ssh

# =============================================================================
# Construir bloque de configuración dnsmasq
# =============================================================================
log_info "Dominios a suplantar:"
DNSMASQ_BLOCK="# --- dns-spoof-demo begin ---
# Generado por openwrt-dns-spoof-enable.sh
# Eliminar con openwrt-dns-spoof-disable.sh"

for domain in $ALL_DOMAINS; do
    [ -z "$domain" ] && continue
    printf '  %s → %s\n' "$domain" "$PORTAL_IP"
    DNSMASQ_BLOCK="$DNSMASQ_BLOCK
address=/$domain/$PORTAL_IP"
done

DNSMASQ_BLOCK="$DNSMASQ_BLOCK
# --- dns-spoof-demo end ---"

# =============================================================================
# Verificar si ya existe la demo activa
# =============================================================================
ALREADY=$(router_ssh "grep -c 'dns-spoof-demo begin' /etc/dnsmasq.conf 2>/dev/null || echo 0" 2>/dev/null)
if [ "$ALREADY" -gt 0 ]; then
    log_warn "Demo DNS ya activa — eliminando bloque anterior antes de reescribir..."
    router_ssh "sed -i '/# --- dns-spoof-demo begin ---/,/# --- dns-spoof-demo end ---/d' /etc/dnsmasq.conf"
fi

# Verificar también en dnsmasq.d si existe
router_ssh "[ -f /etc/dnsmasq.d/dns-spoof-demo.conf ] && rm /etc/dnsmasq.d/dns-spoof-demo.conf 2>/dev/null; true"

# =============================================================================
# Escribir configuración en el router
# =============================================================================
log_info "Escribiendo configuración DNS spoof en el router..."

DNSMASQ_D_EXISTS=0
router_ssh "[ -d /etc/dnsmasq.d ]" 2>/dev/null && DNSMASQ_D_EXISTS=1

if [ "$DNSMASQ_D_EXISTS" -eq 1 ]; then
    router_ssh "printf '%s\n' '$DNSMASQ_BLOCK' > /etc/dnsmasq.d/dns-spoof-demo.conf"
    log_ok "Escrito en /etc/dnsmasq.d/dns-spoof-demo.conf"
else
    router_ssh "printf '\n%s\n' '$DNSMASQ_BLOCK' >> /etc/dnsmasq.conf"
    log_ok "Bloque añadido en /etc/dnsmasq.conf"
fi

# =============================================================================
# Recargar dnsmasq
# =============================================================================
log_info "Recargando dnsmasq..."
router_ssh "/etc/init.d/dnsmasq reload 2>/dev/null || /etc/init.d/dnsmasq restart" \
    && log_ok "dnsmasq recargado" \
    || log_warn "No se pudo recargar dnsmasq — reinicia manualmente"

# =============================================================================
# Verificar que la resolución DNS está envenenada
# =============================================================================
log_info "Verificando resolución DNS..."
for domain in $ALL_DOMAINS; do
    [ -z "$domain" ] && continue
    RESOLVED=$(router_ssh "nslookup $domain 127.0.0.1 2>/dev/null | awk '/^Address/ && NR>2 {print \$2}' | head -1" 2>/dev/null)
    if [ "$RESOLVED" = "$PORTAL_IP" ]; then
        log_ok "$domain → $RESOLVED (envenenado correctamente)"
    else
        log_warn "$domain → '${RESOLVED:-sin respuesta}' (esperaba $PORTAL_IP)"
    fi
done

# =============================================================================
# Aplicar recursos k8s del deployment dns-spoof
# =============================================================================
K8S_DIR="$(dirname "$SCRIPT_DIR")/k8s"
log_info "Aplicando deployment dns-spoof en k3s..."
kubectl apply -f "$K8S_DIR/dns-spoof-configmap.yaml" \
    && kubectl apply -f "$K8S_DIR/dns-spoof-deployment.yaml" \
    && kubectl apply -f "$K8S_DIR/dns-spoof-svc.yaml" \
    && kubectl apply -f "$K8S_DIR/dns-spoof-ingress.yaml" \
    && log_ok "Recursos k8s dns-spoof aplicados" \
    || log_warn "Error aplicando recursos k8s — verifica con: kubectl get pods"

log_info "Esperando que el pod dns-spoof esté listo..."
kubectl rollout status deployment/dns-spoof --timeout=60s 2>/dev/null \
    && log_ok "Pod dns-spoof listo" \
    || log_warn "Timeout esperando pod — verifica con: kubectl get pods"

# =============================================================================
# Resumen
# =============================================================================
printf '\n'
log_ok "=== Demo DNS Poisoning ACTIVA ==="
printf '\n'
printf '  Dominios suplantados → %s\n' "$PORTAL_IP"
for domain in $ALL_DOMAINS; do
    [ -z "$domain" ] && continue
    printf '    http://%s\n' "$domain"
done
printf '\n'
log_info "Conecta un dispositivo al WiFi y visita uno de esos dominios (HTTP, no HTTPS)."
log_info "Para desactivar: sh scripts/openwrt-dns-spoof-disable.sh"
