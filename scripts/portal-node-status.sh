#!/bin/bash
# Estado del nodo portal (Raspi 3B #2).
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=./lib/raspi4b-common.sh
. "$SCRIPT_DIR/lib/raspi4b-common.sh"
# shellcheck source=./lib/topology-common.sh
. "$SCRIPT_DIR/lib/topology-common.sh"

init_log_dir "portal-node"
load_topology

ensure_cmd podman curl

CONTAINER_NAME="captive-portal-node"
BACKEND_CONTAINER_NAME="captive-portal-node-backend"
PORTAL_LOCAL_URL="http://127.0.0.1"

log_info "--- portal-node-status ---"
log_info "Topología: $TOPOLOGY"
log_info "Portal IP objetivo en OpenWrt: $PORTAL_IP"
log_info "AI endpoint: $AI_IP"

if podman ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  log_ok "Contenedor activo: $CONTAINER_NAME"
else
  die "Contenedor no activo: $CONTAINER_NAME"
fi

if podman ps --format '{{.Names}}' | grep -qx "$BACKEND_CONTAINER_NAME"; then
  log_ok "Contenedor activo: $BACKEND_CONTAINER_NAME"
else
  die "Contenedor no activo: $BACKEND_CONTAINER_NAME"
fi

for ep in /portal /services /blocked /people /api/history /api/stats /api/portal/context; do
  code="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "${PORTAL_LOCAL_URL}${ep}" 2>/dev/null || echo 000)"
  case "$code" in
    200|301|302|307|308) log_ok "${ep} HTTP ${code}" ;;
    *) log_warn "${ep} HTTP ${code}" ;;
  esac
done

log_info "Resumen de contenedor:"
podman ps --filter "name=$CONTAINER_NAME"
