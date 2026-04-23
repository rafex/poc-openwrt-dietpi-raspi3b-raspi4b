#!/bin/bash
# Instala/despliega solo portales en k3s.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib/raspi4b-common.sh
. "$SCRIPT_DIR/lib/raspi4b-common.sh"
# shellcheck source=./lib/topology-common.sh
. "$SCRIPT_DIR/lib/topology-common.sh"

parse_common_flags "$@"
init_log_dir "portals"
need_root

[ "${#REM_ARGS[@]}" -eq 0 ] || die "Argumentos no soportados: ${REM_ARGS[*]}"

log_info "--- setup-raspi4b-portals ---"
ensure_cmd bash curl
load_topology

ensure_portal_ssh_key
ensure_k3s_ready

if ! $ONLY_VERIFY; then
  if $DRY_RUN; then
    if $NO_BUILD; then
      log_info "[dry-run] bash scripts/raspi-deploy.sh --no-build"
    else
      log_info "[dry-run] bash scripts/raspi-deploy.sh"
    fi
  else
    if $NO_BUILD; then
      run_cmd bash "$SCRIPT_DIR/raspi-deploy.sh" --no-build
    else
      run_cmd bash "$SCRIPT_DIR/raspi-deploy.sh"
    fi
  fi
fi

if $DRY_RUN; then
  log_ok "Dry-run completado"
  exit 0
fi

PORTAL_IP="${PORTAL_IP:-$RASPI4B_IP}"
for ep in /portal /accepted /services /people; do
  code="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 8 "http://${PORTAL_IP}${ep}" 2>/dev/null || echo 000)"
  case "$code" in
    200|301|302|307|308) log_ok "${ep} HTTP ${code}" ;;
    *) die "Fallo verificación ${ep}: HTTP ${code}" ;;
  esac
done

log_ok "setup-raspi4b-portals completado"
