#!/bin/bash
# Instala/despliega solo ai-analyzer en k3s (sin llama ni mosquitto).
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
K8S_DIR="$REPO_DIR/k8s"

# shellcheck source=./lib/raspi4b-common.sh
. "$SCRIPT_DIR/lib/raspi4b-common.sh"

parse_common_flags "$@"
init_log_dir "ai-analyzer"
need_root

[ "${#REM_ARGS[@]}" -eq 0 ] || die "Argumentos no soportados: ${REM_ARGS[*]}"

log_info "--- setup-raspi4b-ai-analyzer ---"
ensure_cmd bash curl podman k3s kubectl
ensure_k3s_ready

if ! $ONLY_VERIFY; then
  if ! $NO_BUILD; then
    run_cmd podman build --cgroup-manager=cgroupfs --platform linux/arm64 -t localhost/ai-analyzer:latest "$REPO_DIR/backend/ai-analyzer/"
    run_cmd sh -c "podman save localhost/ai-analyzer:latest | k3s ctr images import -"
  fi

  run_cmd kubectl apply -f "$K8S_DIR/ai-analyzer-deployment.yaml"
  run_cmd kubectl apply -f "$K8S_DIR/ai-analyzer-svc.yaml"
  run_cmd kubectl apply -f "$K8S_DIR/ai-analyzer-ingress.yaml"

  if ! $NO_BUILD; then
    run_cmd kubectl rollout restart deployment/ai-analyzer
  fi
fi

if $DRY_RUN; then
  log_ok "Dry-run completado"
  exit 0
fi

run_cmd kubectl rollout status deployment/ai-analyzer --timeout=180s

PI_IP="192.168.1.167"
for ep in /health /dashboard /terminal /rulez; do
  code="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "http://${PI_IP}${ep}" 2>/dev/null || echo 000)"
  case "$code" in
    200|301|302|307|308) log_ok "${ep} HTTP ${code}" ;;
    *) die "Fallo verificación ${ep}: HTTP ${code}" ;;
  esac
done

log_ok "setup-raspi4b-ai-analyzer completado"
