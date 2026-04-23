#!/bin/bash
# Verificación end-to-end por topología (legacy/split_portal).
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=./lib/raspi4b-common.sh
. "$SCRIPT_DIR/lib/raspi4b-common.sh"
# shellcheck source=./lib/topology-common.sh
. "$SCRIPT_DIR/lib/topology-common.sh"
# shellcheck source=./lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

TOP_OVERRIDE=""
parse_common_flags "$@"
ARGS=("${REM_ARGS[@]}")
REM_ARGS=()
for a in "${ARGS[@]}"; do
  case "$a" in
    --topology=*) TOP_OVERRIDE="${a#*=}" ;;
    *) REM_ARGS+=("$a") ;;
  esac
done

init_log_dir "verify"
load_topology
[ -z "$TOP_OVERRIDE" ] || TOPOLOGY="$TOP_OVERRIDE"
ensure_topology_value >/dev/null || die "TOPOLOGY inválida: $TOPOLOGY"
[ "${#REM_ARGS[@]}" -eq 0 ] || die "Argumentos no soportados: ${REM_ARGS[*]}"

if [[ "$TOPOLOGY" == "split_portal" ]]; then
  PORTAL_IP="${PORTAL_NODE_IP}"
else
  PORTAL_IP="${RASPI4B_IP}"
fi

http_check() {
  local url="$1"
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 12 "$url" 2>/dev/null || echo 000)"
  case "$code" in
    200|301|302|307|308) log_ok "$url -> HTTP $code" ;;
    *) die "Fallo HTTP $url -> $code" ;;
  esac
}

log_info "--- verify-topology ---"
log_info "Topología: $TOPOLOGY"
log_info "portal=$PORTAL_IP ai=$AI_IP sensor=$RASPI3B_IP router=$ROUTER_IP"

# Portal/UI
http_check "http://${PORTAL_IP}/portal"
http_check "http://${PORTAL_IP}/services"
http_check "http://${PORTAL_IP}/people"
http_check "http://${PORTAL_IP}/api/history?limit=1"
http_check "http://${PORTAL_IP}/api/stats"

# AI direct
http_check "http://${AI_IP}/health"
http_check "http://${AI_IP}/dashboard"
http_check "http://${AI_IP}/rulez"

# Router checks (best effort)
if [[ -f "$SSH_KEY" && -f "$SSH_KEY_PUB" ]] && router_ssh 'echo ok' >/dev/null 2>&1; then
  if router_ip_in_set "$ADMIN_IP"; then log_ok "Admin permanente en allowed_clients"; else die "Admin no está en allowed_clients"; fi
  if router_ip_in_set "$RASPI4B_IP"; then log_ok "Raspi4B permanente en allowed_clients"; else die "Raspi4B no está en allowed_clients"; fi
  if router_ip_in_set "$RASPI3B_IP"; then log_ok "Raspi3B sensor permanente en allowed_clients"; else die "Raspi3B sensor no está en allowed_clients"; fi
  if router_ip_in_set "$PORTAL_IP"; then log_ok "Portal node permanente en allowed_clients"; else die "Portal node no está en allowed_clients"; fi
else
  log_warn "No se pudo validar router por SSH (skip checks nftables)"
fi

log_ok "verify-topology completado"
