#!/bin/bash
# raspi-k8s-status.sh — Diagnóstico completo del estado real de k8s en la Pi
#
# Uso: bash scripts/raspi-k8s-status.sh
#
# Si k3s no está corriendo, intenta arrancarlo y espera a que esté listo.
# Luego vuelca TODO en YAML real desde el API server (no desde archivos del repo).
# La salida se guarda en output/output_status_YYYYmmDD_HHMMss.md

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="$REPO_DIR/output"
mkdir -p "$OUTPUT_DIR"

TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
OUTPUT_FILE="$OUTPUT_DIR/output_status_${TIMESTAMP}.md"

# Redirigir toda la salida: pantalla + fichero simultáneamente
exec > >(tee "$OUTPUT_FILE") 2>&1

echo "# k8s Status — $(date '+%Y-%m-%d %H:%M:%S')"
echo ""
echo "> Archivo: \`output/output_status_${TIMESTAMP}.md\`"
echo "> Host: $(hostname)"
echo ""

SEP='============================================================'
sep() { printf '\n%s\n %s\n%s\n' "$SEP" "$1" "$SEP"; }

KUBECTL="k3s kubectl"

# =============================================================================
# 0. Arrancar k3s si no está corriendo
# =============================================================================
sep "0. ESTADO Y ARRANQUE DE K3S"

K3S_RUNNING=0
if ps aux | grep -q '[k]3s server'; then
    echo "  k3s ya está corriendo"
    K3S_RUNNING=1
else
    echo "  [!] k3s no está corriendo — intentando arrancar..."

    # Buscar el binario
    K3S_BIN=$(which k3s 2>/dev/null || echo "/usr/local/bin/k3s")
    if [ ! -x "$K3S_BIN" ]; then
        echo "  [ERROR] Binario k3s no encontrado. Instala k3s primero."
        exit 1
    fi

    # Arrancar k3s en background (DietPi sin systemd)
    # --disable traefik porque lo gestionamos aparte via HelmChartConfig
    nohup "$K3S_BIN" server \
        --write-kubeconfig-mode=644 \
        > /var/log/k3s-start.log 2>&1 &

    K3S_PID=$!
    echo "  k3s arrancado con PID $K3S_PID"
    echo "  Esperando que el API server responda en 127.0.0.1:6443 (max 60s)..."

    READY=0
    for i in $(seq 1 60); do
        if $KUBECTL get nodes > /dev/null 2>&1; then
            READY=1
            break
        fi
        printf '.'
        sleep 1
    done
    printf '\n'

    if [ "$READY" -eq 1 ]; then
        echo "  [OK] k3s listo después de ${i}s"
        K3S_RUNNING=1
    else
        echo "  [ERROR] k3s no respondió en 60s. Últimas líneas del log:"
        tail -20 /var/log/k3s-start.log 2>/dev/null
        echo ""
        echo "  Puedes revisar: tail -f /var/log/k3s-start.log"
        exit 1
    fi
fi

echo ""
echo "--- Versión ---"
k3s --version

echo ""
echo "--- Nodos ---"
$KUBECTL get nodes -o wide

# =============================================================================
# 1. Vista general de recursos
# =============================================================================
sep "1. RECURSOS — VISTA GENERAL (todos los namespaces)"
$KUBECTL get all -A 2>/dev/null

# =============================================================================
# 2. YAML completo — Deployments (namespace default)
# =============================================================================
sep "2. DEPLOYMENTS — YAML COMPLETO (default)"

DEPLOYMENTS=$($KUBECTL get deployments -n default -o name 2>/dev/null)
if [ -z "$DEPLOYMENTS" ]; then
    echo "  (sin deployments en namespace default)"
else
    for d in $DEPLOYMENTS; do
        echo ""
        echo "### $d ###"
        $KUBECTL get "$d" -n default -o yaml 2>/dev/null
        echo "---"
    done
fi

# =============================================================================
# 3. YAML completo — Services (namespace default)
# =============================================================================
sep "3. SERVICES — YAML COMPLETO (default)"

SERVICES=$($KUBECTL get svc -n default -o name 2>/dev/null | grep -v 'kubernetes')
if [ -z "$SERVICES" ]; then
    echo "  (sin services en namespace default)"
else
    for s in $SERVICES; do
        echo ""
        echo "### $s ###"
        $KUBECTL get "$s" -n default -o yaml 2>/dev/null
        echo "---"
    done
fi

# =============================================================================
# 4. YAML completo — ConfigMaps (namespace default)
# =============================================================================
sep "4. CONFIGMAPS — YAML COMPLETO (default)"

CONFIGMAPS=$($KUBECTL get configmaps -n default -o name 2>/dev/null | grep -v 'kube-root-ca')
if [ -z "$CONFIGMAPS" ]; then
    echo "  (sin configmaps en namespace default)"
else
    for cm in $CONFIGMAPS; do
        echo ""
        echo "### $cm ###"
        $KUBECTL get "$cm" -n default -o yaml 2>/dev/null
        echo "---"
    done
fi

# =============================================================================
# 5. YAML completo — Ingress (namespace default)
# =============================================================================
sep "5. INGRESS — YAML COMPLETO (default)"

INGRESSES=$($KUBECTL get ingress -n default -o name 2>/dev/null)
if [ -z "$INGRESSES" ]; then
    echo "  (sin ingress en namespace default)"
else
    for ing in $INGRESSES; do
        echo ""
        echo "### $ing ###"
        $KUBECTL get "$ing" -n default -o yaml 2>/dev/null
        echo "---"
    done
fi

# =============================================================================
# 6. Traefik — configuración real desplegada
# =============================================================================
sep "6. TRAEFIK — CONFIGURACIÓN REAL"

echo "--- Pods Traefik (kube-system) ---"
$KUBECTL get pods -n kube-system 2>/dev/null | grep -i traefik || echo "  (no encontrado en kube-system)"

echo ""
echo "--- HelmChart Traefik ---"
$KUBECTL get helmchart -n kube-system 2>/dev/null | grep -i traefik || echo "  (sin HelmChart)"

TRAEFIK_HC=$($KUBECTL get helmchart -n kube-system -o name 2>/dev/null | grep -i traefik | head -1)
if [ -n "$TRAEFIK_HC" ]; then
    echo ""
    echo "### $TRAEFIK_HC YAML ###"
    $KUBECTL get "$TRAEFIK_HC" -n kube-system -o yaml 2>/dev/null
fi

echo ""
echo "--- HelmChartConfig Traefik ---"
TRAEFIK_HCC=$($KUBECTL get helmchartconfig -n kube-system -o name 2>/dev/null | grep -i traefik | head -1)
if [ -n "$TRAEFIK_HCC" ]; then
    $KUBECTL get "$TRAEFIK_HCC" -n kube-system -o yaml 2>/dev/null
else
    echo "  (sin HelmChartConfig — Traefik usa configuración por defecto)"
fi

echo ""
echo "--- Service Traefik ---"
$KUBECTL get svc -n kube-system 2>/dev/null | grep -i traefik

echo ""
echo "--- Puertos en escucha ---"
ss -tlnp 2>/dev/null | grep -E ':80 |:443 |:8080 |:6443 ' || \
    cat /proc/net/tcp 2>/dev/null | awk '$2~/^[0-9A-F]+:0050 |^[0-9A-F]+:01F90 |^[0-9A-F]+:1F90 /' | head -10 || \
    echo "  ss no disponible"

# =============================================================================
# 7. Imágenes en containerd (lo que k3s puede usar)
# =============================================================================
sep "7. IMÁGENES EN CONTAINERD (k3s ctr)"
k3s ctr images ls 2>/dev/null | awk '{printf "  %-70s  %s\n", $1, $4}' | sort || echo "  (ctr no disponible)"

echo ""
echo "--- Imágenes en podman ---"
podman images 2>/dev/null || echo "  podman no disponible"

# =============================================================================
# 8. Llaves SSH
# =============================================================================
sep "8. LLAVES SSH (/opt/keys)"
ls -la /opt/keys 2>/dev/null || echo "  [!] /opt/keys no existe"

if [ -f /opt/keys/captive-portal.pub ]; then
    echo ""
    echo "--- Llave pública ---"
    cat /opt/keys/captive-portal.pub
fi

# =============================================================================
# 9. Conectividad HTTP
# =============================================================================
sep "9. CONECTIVIDAD HTTP"

for url in \
    "http://127.0.0.1/" \
    "http://127.0.0.1:8080/health" \
    "http://192.168.1.167/" \
    "http://192.168.1.167/health"
do
    echo -n "  $url → "
    code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 --max-time 5 "$url" 2>/dev/null)
    echo "HTTP $code"
done

# =============================================================================
# 10. Logs recientes de pods captive-portal
# =============================================================================
sep "10. LOGS RECIENTES (pods captive-portal)"

for pod in $($KUBECTL get pods -n default -o name 2>/dev/null | grep -i 'captive\|portal\|backend'); do
    # Obtener los nombres de contenedores del pod
    containers=$($KUBECTL get "$pod" -n default \
        -o jsonpath='{.spec.containers[*].name}' 2>/dev/null)

    for container in $containers; do
        echo ""
        echo "--- $pod  [contenedor: $container] ---"
        $KUBECTL logs "$pod" -n default -c "$container" --tail=40 2>/dev/null \
            || echo "  (no hay logs para $container)"
    done
done

printf '\n%s\n FIN DEL DIAGNÓSTICO\n%s\n\n' "$SEP" "$SEP"

# Mostrar ruta del fichero generado (va a pantalla Y al fichero via tee)
printf 'Salida guardada en:\n  %s\n\n' "$OUTPUT_FILE"
