#!/bin/bash
# Orquesta setup por topología sin eliminar el flujo legacy.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=./lib/raspi4b-common.sh
. "$SCRIPT_DIR/lib/raspi4b-common.sh"
# shellcheck source=./lib/topology-common.sh
. "$SCRIPT_DIR/lib/topology-common.sh"

TOP_OVERRIDE=""
RUN_OPENWRT=true
RUN_AI=true
RUN_PORTAL=true
PORTAL_HOST=""
PORTAL_USER="root"
PORTAL_SSH_KEY=""
PORTAL_REPO_DIR="$REPO_DIR"

parse_common_flags "$@"
ARGS=("${REM_ARGS[@]}")
REM_ARGS=()
for a in "${ARGS[@]}"; do
  case "$a" in
    --topology=*) TOP_OVERRIDE="${a#*=}" ;;
    --no-openwrt) RUN_OPENWRT=false ;;
    --no-ai) RUN_AI=false ;;
    --no-portal) RUN_PORTAL=false ;;
    --portal-host=*) PORTAL_HOST="${a#*=}" ;;
    --portal-user=*) PORTAL_USER="${a#*=}" ;;
    --portal-ssh-key=*) PORTAL_SSH_KEY="${a#*=}" ;;
    --portal-repo-dir=*) PORTAL_REPO_DIR="${a#*=}" ;;
    *) REM_ARGS+=("$a") ;;
  esac
done

init_log_dir "topology"
need_root
load_topology
[ -z "$TOP_OVERRIDE" ] || TOPOLOGY="$TOP_OVERRIDE"
ensure_topology_value >/dev/null || die "TOPOLOGY inválida: $TOPOLOGY"
[ "${#REM_ARGS[@]}" -eq 0 ] || die "Argumentos no soportados: ${REM_ARGS[*]}"

if [[ "$TOPOLOGY" == "split_portal" ]]; then
  PORTAL_IP="${PORTAL_NODE_IP}"
else
  PORTAL_IP="${RASPI4B_IP}"
fi

log_info "--- setup-topology ---"
log_info "Topología objetivo: $TOPOLOGY"
log_info "router=$ROUTER_IP ai=$AI_IP portal=$PORTAL_IP sensor=$RASPI3B_IP"

if $RUN_OPENWRT; then
  run_cmd bash "$SCRIPT_DIR/setup-openwrt.sh" --topology "$TOPOLOGY" --portal-ip "$PORTAL_IP" --ai-ip "$AI_IP"
fi

if $RUN_AI; then
  if [[ "$TOPOLOGY" == "split_portal" ]]; then
    run_cmd bash "$SCRIPT_DIR/setup-raspi4b-all.sh" --skip-portals
  else
    run_cmd bash "$SCRIPT_DIR/setup-raspi4b-all.sh"
  fi
fi

if $RUN_PORTAL; then
  if [[ "$TOPOLOGY" == "split_portal" ]]; then
    if [[ -n "$PORTAL_HOST" ]]; then
      SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes)
      [[ -z "$PORTAL_SSH_KEY" ]] || SSH_OPTS+=(-i "$PORTAL_SSH_KEY")
      run_cmd ssh "${SSH_OPTS[@]}" "${PORTAL_USER}@${PORTAL_HOST}" \
        "cd '$PORTAL_REPO_DIR' && sudo bash scripts/setup-portal-raspi3b.sh"
    else
      log_warn "Topología split_portal: no se indicó --portal-host, ejecuta setup-portal-raspi3b.sh manualmente en Raspi3B #2"
    fi
  else
    log_info "Topología legacy: portal queda en Raspi4B (k3s), no se despliega portal node"
  fi
fi

if ! $DRY_RUN; then
  run_cmd bash "$SCRIPT_DIR/verify-topology.sh" --topology="$TOPOLOGY"
fi

log_ok "setup-topology completado"
