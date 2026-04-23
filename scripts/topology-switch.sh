#!/bin/bash
# Cambia entre topologías (legacy/split_portal) sin borrar despliegues existentes.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=./lib/raspi4b-common.sh
. "$SCRIPT_DIR/lib/raspi4b-common.sh"
# shellcheck source=./lib/topology-common.sh
. "$SCRIPT_DIR/lib/topology-common.sh"

TARGET_TOPOLOGY="${1:-}"
PERSIST=false

shift_count=0
if [[ -n "$TARGET_TOPOLOGY" && "$TARGET_TOPOLOGY" != "--persist" ]]; then
  shift_count=1
fi

if [[ "$shift_count" -eq 1 ]]; then
  shift
fi

for a in "$@"; do
  case "$a" in
    --persist) PERSIST=true ;;
    *) die "Argumento no soportado: $a" ;;
  esac
done

init_log_dir "topology"
need_root
load_topology

if [[ -z "$TARGET_TOPOLOGY" || "$TARGET_TOPOLOGY" == "--persist" ]]; then
  log_info "Uso: bash scripts/topology-switch.sh legacy|split_portal [--persist]"
  exit 1
fi

case "$TARGET_TOPOLOGY" in
  legacy) NEW_PORTAL_IP="$RASPI4B_IP" ;;
  split_portal) NEW_PORTAL_IP="$PORTAL_NODE_IP" ;;
  *) die "Topología inválida: $TARGET_TOPOLOGY" ;;
esac

upsert_kv() {
  local file="$1" key="$2" value="$3"
  if grep -q "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$file"
  else
    printf '\n%s=%s\n' "$key" "$value" >> "$file"
  fi
}

if $PERSIST; then
  TF="$(resolve_topology_file)"
  run_cmd cp "$TF" "${TF}.bak.$(date +%Y%m%d-%H%M%S)"
  upsert_kv "$TF" "TOPOLOGY" "$TARGET_TOPOLOGY"
  upsert_kv "$TF" "PORTAL_IP" "$NEW_PORTAL_IP"
  upsert_kv "$TF" "AI_IP" "${AI_IP:-$RASPI4B_IP}"
  log_ok "topology.env actualizado: $TF"
fi

run_cmd bash "$SCRIPT_DIR/setup-openwrt.sh" \
  --topology "$TARGET_TOPOLOGY" \
  --portal-ip "$NEW_PORTAL_IP" \
  --ai-ip "${AI_IP:-$RASPI4B_IP}"

if [[ "$TARGET_TOPOLOGY" == "legacy" ]]; then
  log_info "Recomendado: bash scripts/setup-raspi4b-portals.sh"
else
  log_info "Recomendado en Raspi4B: bash scripts/setup-raspi4b-all.sh --skip-portals"
  log_info "Recomendado en Raspi3B#2: bash scripts/setup-portal-raspi3b.sh"
fi

log_ok "topology-switch completado: $TARGET_TOPOLOGY"
