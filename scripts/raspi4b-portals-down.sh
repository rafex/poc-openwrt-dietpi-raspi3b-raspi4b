#!/bin/bash
# Baja TODO lo de portal/backend en k3s de Raspi4B (deploy/svc/ingress/configmaps),
# dejando solamente componentes de IA.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=./lib/raspi4b-common.sh
. "$SCRIPT_DIR/lib/raspi4b-common.sh"

parse_common_flags "$@"
init_log_dir "portals"
need_root
ensure_cmd kubectl k3s
ensure_k3s_ready
[ "${#REM_ARGS[@]}" -eq 0 ] || die "Argumentos no soportados: ${REM_ARGS[*]}"

log_info "--- raspi4b-portals-down ---"

if ! $ONLY_VERIFY; then
  # 1) Escalar a cero primero para cortar tráfico rápido
  run_cmd kubectl scale deployment/captive-portal --replicas=0 -n default
  run_cmd kubectl scale deployment/captive-portal-lentium --replicas=0 -n default

  # 2) Eliminar recursos de portal/backend
  run_cmd kubectl delete deployment/captive-portal -n default --ignore-not-found=true
  run_cmd kubectl delete deployment/captive-portal-lentium -n default --ignore-not-found=true
  run_cmd kubectl delete service/captive-portal -n default --ignore-not-found=true
  run_cmd kubectl delete ingress/captive-portal -n default --ignore-not-found=true
  run_cmd kubectl delete configmap/captive-portal-nginx-conf -n default --ignore-not-found=true
  run_cmd kubectl delete configmap/captive-portal-lentium-nginx-conf -n default --ignore-not-found=true
fi

if $DRY_RUN; then
  log_ok "Dry-run completado"
  exit 0
fi

log_info "Esperando que no queden pods de portal/backend en Running..."
for _ in $(seq 1 30); do
  running="$(kubectl get pods -n default -l app=captive-portal --no-headers 2>/dev/null | awk '$3=="Running"{print $1}' | wc -l | tr -d ' ')"
  [ "${running:-0}" = "0" ] && break
  sleep 1
done

running="$(kubectl get pods -n default -l app=captive-portal --no-headers 2>/dev/null | awk '$3=="Running"{print $1}' | wc -l | tr -d ' ')"
if [ "${running:-0}" != "0" ]; then
  kubectl get pods -n default -l app=captive-portal || true
  die "Aún hay pods de portal en Running"
fi

if kubectl get deployment -n default captive-portal >/dev/null 2>&1; then
  die "Deployment captive-portal aún existe"
fi
if kubectl get deployment -n default captive-portal-lentium >/dev/null 2>&1; then
  die "Deployment captive-portal-lentium aún existe"
fi
if kubectl get service -n default captive-portal >/dev/null 2>&1; then
  die "Service captive-portal aún existe"
fi
if kubectl get ingress -n default captive-portal >/dev/null 2>&1; then
  die "Ingress captive-portal aún existe"
fi

log_ok "Portal/backend eliminados de k3s en Raspi4B"
if kubectl get deployment -n default ai-analyzer >/dev/null 2>&1; then
  log_ok "ai-analyzer sigue presente"
else
  log_warn "ai-analyzer no encontrado en default namespace"
fi

log_info "Recursos restantes relevantes:"
kubectl get deployment,svc,ingress -n default | awk 'NR==1 || /ai-analyzer|captive-portal/'
