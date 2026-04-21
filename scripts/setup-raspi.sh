#!/bin/bash
# setup-raspi.sh — Configura la Raspberry Pi 4 (RafexPi) desde cero
# Idempotente: puede ejecutarse multiples veces sin efectos secundarios
#
# Uso: bash scripts/setup-raspi.sh
#
# Requisitos:
#   - k3s corriendo en la Pi
#   - podman instalado con --runtime=runc disponible
#   - Repositorio en /opt/repository/poc-openwrt-dietpi-raspi3b-raspi4b/

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BACKEND_DIR="$REPO_DIR/backend/captive-portal"
K8S_DIR="$REPO_DIR/k8s"

# Constantes
SSH_KEY="/opt/keys/captive-portal"
SSH_KEY_PUB="/opt/keys/captive-portal.pub"
PORTAL_URL="http://192.168.1.167"
IMAGE_NAME="captive-backend:latest"
K3S_IMAGE_NAME="localhost/captive-backend:latest"

# Logging
log_info()  { printf '[INFO]  %s\n' "$*"; }
log_ok()    { printf '[OK]    %s\n' "$*"; }
log_warn()  { printf '[WARN]  %s\n' "$*"; }
log_error() { printf '[ERROR] %s\n' "$*" >&2; }
die()       { log_error "$*"; exit 1; }

# =============================================================================
# FASE A: Verificar k3s
# =============================================================================
log_info "--- FASE A: Verificando k3s ---"

# DietPi no usa systemd como PID 1 — verificar via ps
if ! ps aux | grep -q '[k]3s server'; then
    die "k3s no esta corriendo.
  Para iniciar k3s manualmente:
    /usr/local/bin/k3s server --disable traefik &
  O verificar logs:
    ps aux | grep k3s
    dmesg | tail -20"
fi
log_ok "k3s esta corriendo"

# Verificar que kubectl responde
if ! k3s kubectl get nodes > /dev/null 2>&1; then
    die "k3s kubectl no responde. El servidor puede estar inicializandose. Espera un momento."
fi
log_ok "kubectl responde correctamente"

# =============================================================================
# FASE B: Directorio y llaves SSH
# =============================================================================
log_info "--- FASE B: Configurando llaves SSH ---"

# Crear directorio de llaves
if [ ! -d /opt/keys ]; then
    mkdir -p /opt/keys
    log_ok "Directorio /opt/keys creado"
else
    log_info "/opt/keys ya existe (skip)"
fi

# Generar llave SSH ed25519 si no existe
if [ ! -f "$SSH_KEY" ]; then
    ssh-keygen -t ed25519 \
        -f "$SSH_KEY" \
        -N "" \
        -C "captive-portal@rafexpi"
    log_ok "Llave SSH generada: $SSH_KEY"
else
    log_info "Llave SSH ya existe (skip): $SSH_KEY"
fi

# Permisos correctos
chmod 600 "$SSH_KEY"
chmod 644 "$SSH_KEY_PUB"
log_ok "Permisos de llaves SSH configurados"

# Mostrar la llave publica para copiarla al router
log_info "Llave publica (copiar al router con setup-openwrt.sh):"
printf '  %s\n' "$(cat "$SSH_KEY_PUB")"

# =============================================================================
# FASE C: Build de imagen Docker
# =============================================================================
log_info "--- FASE C: Construyendo imagen Docker ---"

if [ ! -f "$BACKEND_DIR/Dockerfile" ]; then
    die "Dockerfile no encontrado en: $BACKEND_DIR/Dockerfile"
fi

# Verificar si la imagen ya esta en k3s (aun asi se reconstruye para tener la version fresca)
if k3s ctr images ls 2>/dev/null | grep -q "$K3S_IMAGE_NAME"; then
    log_warn "Imagen $K3S_IMAGE_NAME ya existe en k3s — reconstruyendo para actualizar"
fi

log_info "Construyendo imagen con podman..."
podman build \
    --runtime=runc \
    --network=host \
    -t "$IMAGE_NAME" \
    "$BACKEND_DIR" || die "Fallo el build de la imagen Docker"
log_ok "Imagen $IMAGE_NAME construida"

log_info "Importando imagen en k3s (containerd)..."
podman save "$IMAGE_NAME" | k3s ctr images import - || \
    die "Fallo la importacion de la imagen en k3s"

# Verificar importacion
k3s ctr images ls 2>/dev/null | grep -q "$K3S_IMAGE_NAME" || \
    die "La imagen $K3S_IMAGE_NAME no aparece en k3s despues de importar"
log_ok "Imagen $K3S_IMAGE_NAME disponible en k3s"

# =============================================================================
# FASE D: Aplicar manifiestos Kubernetes
# =============================================================================
log_info "--- FASE D: Aplicando manifiestos k8s ---"

if [ ! -d "$K8S_DIR" ]; then
    die "Directorio de manifiestos k8s no encontrado: $K8S_DIR"
fi

# Orden de aplicacion: configmap -> service -> deployment
# (el deployment referencia el configmap y el service)
MANIFESTS="
captive-portal-configmap.yaml
captive-portal-svc.yaml
captive-portal-deployment.yaml
"

for manifest in $MANIFESTS; do
    manifest_path="$K8S_DIR/$manifest"
    if [ ! -f "$manifest_path" ]; then
        log_warn "Manifiesto no encontrado (skip): $manifest_path"
        continue
    fi
    log_info "Aplicando $manifest..."
    k3s kubectl apply -f "$manifest_path" || die "Fallo al aplicar $manifest"
    log_ok "$manifest aplicado"
done

# Esperar que el deployment este listo
log_info "Esperando que el deployment captive-portal este listo (max 120s)..."
k3s kubectl rollout status deployment/captive-portal \
    --timeout=120s \
    --namespace=default || die "El deployment captive-portal no se levanto a tiempo"
log_ok "Deployment captive-portal listo"

# =============================================================================
# FASE E: Verificacion
# =============================================================================
log_info "--- FASE E: Verificando portal ---"

# Esperar hasta 30s que el pod este en estado Running
log_info "Esperando pod Running (max 30s)..."
READY=0
for i in $(seq 1 30); do
    if k3s kubectl get pods -l app=captive-portal 2>/dev/null | grep -q "Running"; then
        READY=1
        break
    fi
    sleep 1
done

if [ "$READY" -eq 0 ]; then
    log_warn "Pod no llego a estado Running en 30s"
    k3s kubectl get pods -l app=captive-portal
    k3s kubectl describe pods -l app=captive-portal | tail -20
    die "Portal no disponible"
fi
log_ok "Pod captive-portal en estado Running"

# Verificar respuesta HTTP del portal
log_info "Verificando respuesta HTTP en $PORTAL_URL..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    --connect-timeout 10 \
    --max-time 15 \
    "$PORTAL_URL" 2>/dev/null || echo "000")

case "$HTTP_CODE" in
    200|301|302|307|308)
        log_ok "Portal responde con HTTP $HTTP_CODE en $PORTAL_URL"
        ;;
    000)
        log_warn "No se pudo conectar al portal. Verifica que Traefik este expuesto en puerto 80."
        k3s kubectl get svc -A | grep -E "traefik|captive"
        ;;
    *)
        log_warn "Portal responde con HTTP $HTTP_CODE (puede ser normal segun la implementacion)"
        ;;
esac

# Resumen final
printf '\n'
log_ok "=== Setup de Raspberry Pi completado ==="
log_info "Estado del cluster:"
k3s kubectl get pods,svc -l app=captive-portal
printf '\n'
log_info "Proximos pasos:"
printf '  1. Ejecutar en la Pi: bash scripts/setup-openwrt.sh\n'
printf '     (configurara el router usando la llave SSH generada)\n'
printf '  2. Llave publica a registrar en el router:\n'
printf '     %s\n' "$(cat "$SSH_KEY_PUB" 2>/dev/null || echo '(no disponible)')"
