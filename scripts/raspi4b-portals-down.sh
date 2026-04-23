#!/bin/bash
# Apaga los portales en Raspi4B (k3s) sin tocar AI analyzer ni llama.cpp.
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
  run_cmd kubectl scale deployment/captive-portal --replicas=0 -n default
  run_cmd kubectl scale deployment/captive-portal-lentium --replicas=0 -n default
fi

if $DRY_RUN; then
  log_ok "Dry-run completado"
  exit 0
fi

log_info "Esperando que no queden pods de portal en Running..."
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

log_ok "Portales en Raspi4B apagados (replicas=0)"
kubectl get deploy -n default captive-portal captive-portal-lentium
