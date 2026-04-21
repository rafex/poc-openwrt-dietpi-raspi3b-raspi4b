#!/bin/bash
# raspi-deploy.sh — Despliega/actualiza el captive portal en k3s
#
# Uso:
#   bash scripts/raspi-deploy.sh              # deploy completo (build + apply + verify)
#   bash scripts/raspi-deploy.sh --no-build   # solo apply manifiestos (sin rebuild)
#   bash scripts/raspi-deploy.sh --only-build # solo rebuild imagen, sin apply
#   bash scripts/raspi-deploy.sh --cleanup    # elimina recursos legacy (captive-portal-html)
#
# Diferencia con setup-raspi.sh:
#   setup-raspi.sh  → instalación desde CERO (genera llaves, crea directorios)
#   raspi-deploy.sh → actualización de una instalación existente
#
# Qué hace este script:
#   1. Verifica que k3s está corriendo
#   2. [Opcional] Reconstruye la imagen backend y la importa en containerd
#   3. Aplica los manifiestos k8s en orden (configmap → svc → deployment → ingress)
#   4. Fuerza rollout restart si solo cambió el configmap (nginx no auto-recarga)
#   5. Espera que el pod esté 2/2 Running
#   6. Verifica HTTP y logs de ambos contenedores
#   7. [Opcional] Limpia recursos legacy

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BACKEND_DIR="$REPO_DIR/backend/captive-portal"
K8S_DIR="$REPO_DIR/k8s"

IMAGE_NAME="captive-backend:latest"
K3S_IMAGE_NAME="localhost/captive-backend:latest"
PORTAL_IP="192.168.1.167"
PORTAL_URL="http://$PORTAL_IP"
KUBECTL="k3s kubectl"

# =============================================================================
# Flags
# =============================================================================
DO_BUILD=1
DO_APPLY=1
DO_CLEANUP=0

for arg in "$@"; do
    case "$arg" in
        --no-build)   DO_BUILD=0 ;;
        --only-build) DO_APPLY=0 ;;
        --cleanup)    DO_CLEANUP=1; DO_BUILD=0; DO_APPLY=0 ;;
        --help|-h)
            sed -n '2,15p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            printf '[ERROR] Argumento desconocido: %s\n' "$arg" >&2
            exit 1
            ;;
    esac
done

# =============================================================================
# Logging
# =============================================================================
log_info()  { printf '\e[0;34m[INFO] \e[0m %s\n' "$*"; }
log_ok()    { printf '\e[0;32m[OK]   \e[0m %s\n' "$*"; }
log_warn()  { printf '\e[0;33m[WARN] \e[0m %s\n' "$*"; }
log_error() { printf '\e[0;31m[ERROR]\e[0m %s\n' "$*" >&2; }
log_step()  { printf '\n\e[1;36m=== %s ===\e[0m\n' "$*"; }
die()       { log_error "$*"; exit 1; }

# =============================================================================
# PASO 0: Verificar k3s
# =============================================================================
log_step "Verificando k3s"

ps aux | grep -q '[k]3s server' || die "k3s no está corriendo.
  Inicia con: /usr/local/bin/k3s server --write-kubeconfig-mode=644 &
  O usa:      bash scripts/raspi-k8s-status.sh  (lo arranca automáticamente)"

$KUBECTL get nodes --no-headers 2>/dev/null | grep -q Ready || \
    die "kubectl no responde o el nodo no está Ready"

NODE=$($KUBECTL get nodes --no-headers 2>/dev/null | awk '{print $1}')
log_ok "k3s listo — nodo: $NODE"

# =============================================================================
# PASO 1: Build de imagen (opcional con --no-build)
# =============================================================================
if [ "$DO_BUILD" -eq 1 ]; then
    log_step "Build de imagen backend"

    [ -f "$BACKEND_DIR/Dockerfile" ] || \
        die "Dockerfile no encontrado: $BACKEND_DIR/Dockerfile"
    [ -f "$BACKEND_DIR/backend.py" ] || \
        die "backend.py no encontrado: $BACKEND_DIR/backend.py"

    log_info "Construyendo imagen con podman..."
    podman build \
        --runtime=runc \
        --network=host \
        -t "$IMAGE_NAME" \
        "$BACKEND_DIR" \
        || die "Falló el build de la imagen"
    log_ok "Imagen $IMAGE_NAME construida"

    log_info "Importando en containerd (k3s ctr)..."
    podman save "$IMAGE_NAME" | $KUBECTL get nodes > /dev/null  # flush stdout buffer
    podman save "$IMAGE_NAME" | k3s ctr images import - \
        || die "Falló la importación en containerd"

    # Verificar
    k3s ctr images ls 2>/dev/null | grep -q "$K3S_IMAGE_NAME" \
        || die "La imagen $K3S_IMAGE_NAME no aparece en containerd"
    log_ok "Imagen $K3S_IMAGE_NAME disponible en containerd"
else
    log_info "Skipping build (--no-build)"
fi

# =============================================================================
# PASO 2: Limpieza de recursos legacy (--cleanup)
# =============================================================================
if [ "$DO_CLEANUP" -eq 1 ]; then
    log_step "Limpieza de recursos legacy"

    CLEANUP_FILE="$K8S_DIR/cleanup-legacy.yaml"
    if [ ! -f "$CLEANUP_FILE" ]; then
        log_warn "No se encontró $CLEANUP_FILE (nada que limpiar)"
    else
        log_info "Eliminando recursos legacy definidos en cleanup-legacy.yaml..."
        $KUBECTL delete -f "$CLEANUP_FILE" --ignore-not-found=true
        log_ok "Recursos legacy eliminados"
        log_warn "Puedes borrar $CLEANUP_FILE del repo si ya no lo necesitas."
    fi
    exit 0
fi

# =============================================================================
# PASO 3: Aplicar manifiestos k8s
# =============================================================================
if [ "$DO_APPLY" -eq 1 ]; then
    log_step "Aplicando manifiestos k8s"

    [ -d "$K8S_DIR" ] || die "Directorio k8s no encontrado: $K8S_DIR"

    # Capturar hash del configmap ANTES de aplicar (para detectar cambios)
    CM_HASH_BEFORE=$($KUBECTL get configmap captive-portal-nginx-conf \
        -n default -o jsonpath='{.data}' 2>/dev/null | md5sum | cut -d' ' -f1 || echo "none")

    # Orden estricto: configmap primero (lo referencia el deployment),
    # luego svc, luego deployment, luego ingress y traefik
    declare -A MANIFESTS_DESC
    MANIFESTS_ORDER=(
        "captive-portal-configmap.yaml"
        "captive-portal-svc.yaml"
        "captive-portal-deployment.yaml"
        "captive-portal-ingress.yaml"
        "traefik-helmchartconfig.yaml"
    )
    MANIFESTS_DESC=(
        ["captive-portal-configmap.yaml"]="ConfigMap nginx (HTML + nginx.conf)"
        ["captive-portal-svc.yaml"]="Service ClusterIP (80 + 8080)"
        ["captive-portal-deployment.yaml"]="Deployment nginx+backend sidecar"
        ["captive-portal-ingress.yaml"]="Ingress Traefik → puerto 80"
        ["traefik-helmchartconfig.yaml"]="Traefik HelmChartConfig (forwardedHeaders)"
    )

    for manifest in "${MANIFESTS_ORDER[@]}"; do
        path="$K8S_DIR/$manifest"
        if [ ! -f "$path" ]; then
            log_warn "No encontrado (skip): $manifest"
            continue
        fi
        log_info "Aplicando ${MANIFESTS_DESC[$manifest]:-$manifest}..."
        $KUBECTL apply -f "$path" || die "Falló al aplicar $manifest"
        log_ok "$manifest ✓"
    done

    # Determinar si hace falta un rollout restart — un solo restart aunque
    # hayan cambiado varias cosas (evita el error "already triggered within past second")
    NEED_RESTART=0
    RESTART_REASON=""

    # Razón 1: ConfigMap nginx cambió (nginx no recarga automáticamente)
    CM_HASH_AFTER=$($KUBECTL get configmap captive-portal-nginx-conf \
        -n default -o jsonpath='{.data}' 2>/dev/null | md5sum | cut -d' ' -f1 || echo "none")
    if [ "$CM_HASH_BEFORE" != "$CM_HASH_AFTER" ]; then
        NEED_RESTART=1
        RESTART_REASON="ConfigMap nginx cambió"
    fi

    # Razón 2: imagen reconstruida (imagePullPolicy: Never no re-descarga,
    # el pod debe reiniciarse para tomar la nueva imagen de containerd)
    if [ "$DO_BUILD" -eq 1 ]; then
        NEED_RESTART=1
        RESTART_REASON="${RESTART_REASON:+$RESTART_REASON + }imagen backend reconstruida"
    fi

    if [ "$NEED_RESTART" -eq 1 ]; then
        log_warn "Rollout restart necesario — motivo: $RESTART_REASON"
        $KUBECTL rollout restart deployment/captive-portal -n default
        log_ok "Rollout restart lanzado"
    else
        log_info "Sin cambios relevantes — no se requiere rollout restart"
    fi

    # =============================================================================
    # PASO 4: Esperar que el pod esté 2/2 Running
    # =============================================================================
    log_step "Esperando que el pod esté listo"

    log_info "Rollout status (max 120s)..."
    $KUBECTL rollout status deployment/captive-portal \
        -n default --timeout=120s \
        || {
            log_error "El deployment no completó el rollout. Estado actual:"
            $KUBECTL get pods -n default -l app=captive-portal
            $KUBECTL describe pods -n default -l app=captive-portal | tail -30
            die "Rollout fallido"
        }

    # Verificar explícitamente 2/2
    READY_CONTAINERS=$($KUBECTL get pods -n default -l app=captive-portal \
        --no-headers 2>/dev/null | awk '{print $2}' | head -1)
    log_ok "Pod listo: $READY_CONTAINERS contenedores running"

    # =============================================================================
    # PASO 5: Verificación HTTP
    # =============================================================================
    log_step "Verificación HTTP"

    for endpoint in "/" "/portal" "/accepted" "/health"; do
        url="$PORTAL_URL$endpoint"
        code=$(curl -s -o /dev/null -w "%{http_code}" \
            --connect-timeout 5 --max-time 8 "$url" 2>/dev/null || echo "000")
        case "$code" in
            200)       printf '  %-35s → \e[0;32mHTTP %s\e[0m\n' "$url" "$code" ;;
            301|302*)  printf '  %-35s → \e[0;33mHTTP %s\e[0m (redirect — OK)\n' "$url" "$code" ;;
            000)       printf '  %-35s → \e[0;31msin respuesta\e[0m\n' "$url" ;;
            *)         printf '  %-35s → HTTP %s\n' "$url" "$code" ;;
        esac
    done

    # Verificar backend directo dentro del pod via kubectl exec
    log_info "Verificando backend Python (:8080) dentro del pod..."
    POD=$($KUBECTL get pods -n default -l app=captive-portal \
        --no-headers 2>/dev/null | awk '{print $1}' | head -1)

    if [ -n "$POD" ]; then
        HEALTH=$($KUBECTL exec "$POD" -n default -c backend -- \
            wget -qO- http://localhost:8080/health 2>/dev/null || echo "error")
        if printf '%s' "$HEALTH" | grep -q '"ok"'; then
            log_ok "Backend Python responde: $HEALTH"
        else
            log_warn "Backend Python no responde en :8080 (respuesta: $HEALTH)"
            log_warn "Revisar logs: kubectl logs $POD -c backend"
        fi
    fi

    # =============================================================================
    # PASO 6: Logs recientes de ambos contenedores
    # =============================================================================
    log_step "Logs recientes"

    if [ -n "$POD" ]; then
        for container in portal backend; do
            printf '\n--- %s [%s] ---\n' "$POD" "$container"
            $KUBECTL logs "$POD" -n default -c "$container" --tail=15 2>/dev/null \
                || log_warn "No hay logs para contenedor $container"
        done
    fi

fi  # fin DO_APPLY

# =============================================================================
# Resumen final
# =============================================================================
log_step "Resumen"

$KUBECTL get pods,svc -n default -l app=captive-portal
printf '\n'
log_ok "Deploy completado ✓"
printf '\n'
printf '  Portal:   %s/portal\n' "$PORTAL_URL"
printf '  Health:   %s/health  (redirige al portal — normal)\n' "$PORTAL_URL"
printf '\n'
printf '  Comandos útiles:\n'
printf '    Logs nginx:   kubectl logs %s -c portal --tail=50\n' "${POD:-(pod)}"
printf '    Logs backend: kubectl logs %s -c backend --tail=50\n' "${POD:-(pod)}"
printf '    Status:       bash scripts/raspi-k8s-status.sh\n'
printf '    Cleanup:      bash scripts/raspi-deploy.sh --cleanup\n'
