#!/bin/bash
# raspi-k8s-status.sh — Diagnóstico completo del estado actual de k8s en la Pi
#
# Uso: bash scripts/raspi-k8s-status.sh
#
# Muestra:
#   1. Estado de k3s (proceso, versión)
#   2. Nodos del cluster
#   3. Todos los recursos desplegados (pods, services, deployments, ingress, configmaps)
#   4. Imágenes disponibles en containerd (k3s)
#   5. Imágenes en podman (si existe)
#   6. Configuración de Traefik (entrypoints, puertos)
#   7. Volúmenes hostPath montados
#   8. Conectividad HTTP del portal

SEP='============================================================'
sep() { printf '\n%s\n %s\n%s\n' "$SEP" "$1" "$SEP"; }

# =============================================================================
# 1. Estado de k3s
# =============================================================================
sep "1. ESTADO DE K3S"

echo "--- Proceso k3s ---"
ps aux | grep '[k]3s' || echo "  [!] k3s NO está corriendo"

echo ""
echo "--- Versión ---"
k3s --version 2>/dev/null || echo "  [!] k3s no encontrado en PATH"

echo ""
echo "--- Nodos ---"
k3s kubectl get nodes -o wide 2>/dev/null || echo "  [!] kubectl no responde"

# =============================================================================
# 2. Namespaces y recursos por namespace
# =============================================================================
sep "2. NAMESPACES"
k3s kubectl get namespaces 2>/dev/null

# =============================================================================
# 3. Pods — todos los namespaces
# =============================================================================
sep "3. PODS (todos los namespaces)"
k3s kubectl get pods -A -o wide 2>/dev/null

# =============================================================================
# 4. Deployments
# =============================================================================
sep "4. DEPLOYMENTS (todos los namespaces)"
k3s kubectl get deployments -A -o wide 2>/dev/null

# =============================================================================
# 5. Services
# =============================================================================
sep "5. SERVICES (todos los namespaces)"
k3s kubectl get svc -A -o wide 2>/dev/null

# =============================================================================
# 6. Ingress
# =============================================================================
sep "6. INGRESS (todos los namespaces)"
k3s kubectl get ingress -A 2>/dev/null || echo "  (sin ingress definidos)"

# =============================================================================
# 7. ConfigMaps (excluyendo los de sistema)
# =============================================================================
sep "7. CONFIGMAPS (namespace default)"
k3s kubectl get configmaps -n default 2>/dev/null

echo ""
echo "--- Contenido de ConfigMaps del captive portal ---"
for cm in $(k3s kubectl get configmaps -n default -o name 2>/dev/null | grep -i 'captive\|portal\|nginx'); do
    echo ""
    echo "  >> $cm"
    k3s kubectl get "$cm" -n default -o yaml 2>/dev/null | grep -A 200 '^data:' | head -60
done

# =============================================================================
# 8. Descripción detallada de pods captive-portal
# =============================================================================
sep "8. DETALLE DE PODS captive-portal"

for pod in $(k3s kubectl get pods -n default -o name 2>/dev/null | grep -i 'captive\|portal\|backend'); do
    echo ""
    echo "--- $pod ---"
    k3s kubectl describe "$pod" -n default 2>/dev/null | grep -E \
        'Name:|Image:|Port|Host Path|Mount|Restart|State:|Ready:|Volumes:|Mounts:|Node:|IP:|Labels:'
done

# =============================================================================
# 9. Imágenes en containerd (k3s)
# =============================================================================
sep "9. IMÁGENES EN CONTAINERD (k3s ctr)"
k3s ctr images ls 2>/dev/null | grep -v '^TYPE' | awk '{printf "  %-70s %s\n", $1, $4}' | sort

# =============================================================================
# 10. Imágenes en podman
# =============================================================================
sep "10. IMÁGENES EN PODMAN"
if command -v podman > /dev/null 2>&1; then
    podman images 2>/dev/null
else
    echo "  podman no disponible"
fi

# =============================================================================
# 11. Configuración de Traefik
# =============================================================================
sep "11. TRAEFIK"

echo "--- Pods Traefik ---"
k3s kubectl get pods -n kube-system -l 'app.kubernetes.io/name=traefik' -o wide 2>/dev/null || \
k3s kubectl get pods -A -l 'app=traefik' -o wide 2>/dev/null || \
echo "  (no encontrado con labels estándar)"

echo ""
echo "--- Service Traefik ---"
k3s kubectl get svc -A | grep -i traefik 2>/dev/null

echo ""
echo "--- HelmChart / HelmChartConfig de Traefik ---"
k3s kubectl get helmchart -A 2>/dev/null | grep -i traefik || echo "  (sin HelmChart)"
k3s kubectl get helmchartconfig -A 2>/dev/null | grep -i traefik || echo "  (sin HelmChartConfig)"

echo ""
echo "--- Puertos en escucha en la Pi (80, 443, 8080) ---"
ss -tlnp 2>/dev/null | grep -E ':80 |:443 |:8080 ' || \
netstat -tlnp 2>/dev/null | grep -E ':80 |:443 |:8080 ' || \
echo "  ss/netstat no disponible"

# =============================================================================
# 12. Volúmenes hostPath y llaves SSH
# =============================================================================
sep "12. LLAVES SSH Y HOSTPATH /opt/keys"

echo "--- Directorio /opt/keys ---"
ls -la /opt/keys 2>/dev/null || echo "  [!] /opt/keys no existe"

echo ""
echo "--- hostPath montados en pods (default) ---"
k3s kubectl get pods -n default -o json 2>/dev/null | \
    python3 -c "
import json, sys
data = json.load(sys.stdin)
for item in data.get('items', []):
    name = item['metadata']['name']
    vols = item['spec'].get('volumes', [])
    for v in vols:
        hp = v.get('hostPath')
        if hp:
            print(f'  Pod: {name}  |  volume: {v[\"name\"]}  |  hostPath: {hp[\"path\"]}')
" 2>/dev/null || echo "  (no se pudo parsear)"

# =============================================================================
# 13. Conectividad HTTP
# =============================================================================
sep "13. CONECTIVIDAD HTTP DEL PORTAL"

echo "--- curl http://192.168.1.167/ ---"
curl -sv --connect-timeout 5 --max-time 10 http://192.168.1.167/ 2>&1 | \
    grep -E '^[<>*]|HTTP/|Location:|< ' | head -20

echo ""
echo "--- curl http://192.168.1.167/health (backend Python) ---"
curl -s --connect-timeout 5 --max-time 10 http://192.168.1.167/health 2>/dev/null || \
    echo "  (no responde — backend puede no estar expuesto aún)"

echo ""
echo "--- curl http://localhost:8080/health (backend directo) ---"
curl -s --connect-timeout 3 --max-time 5 http://localhost:8080/health 2>/dev/null || \
    echo "  (no responde en :8080 directo)"

# =============================================================================
# 14. Yamls aplicados (historial kubectl)
# =============================================================================
sep "14. ARCHIVOS YAML EN EL REPO"
find "$(cd "$(dirname "$0")/.." && pwd)/k8s" -name '*.yaml' -o -name '*.yml' 2>/dev/null | sort | while read -r f; do
    lines=$(wc -l < "$f")
    printf '  %-50s  (%d líneas)\n' "$f" "$lines"
done

printf '\n%s\n FIN DEL DIAGNÓSTICO\n%s\n\n' "$SEP" "$SEP"
