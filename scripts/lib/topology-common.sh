#!/bin/bash
# Shared helpers to load topology configuration for bash scripts.

set -u

resolve_topology_file() {
  if [[ -n "${TOPOLOGY_FILE:-}" && -f "${TOPOLOGY_FILE}" ]]; then
    printf '%s\n' "$TOPOLOGY_FILE"
    return 0
  fi
  if [[ -f /etc/demo-openwrt/topology.env ]]; then
    printf '%s\n' "/etc/demo-openwrt/topology.env"
    return 0
  fi
  printf '%s\n' "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/topology.env"
}

load_topology() {
  local f
  f="$(resolve_topology_file)"
  # shellcheck disable=SC1090
  . "$f"

  TOPOLOGY="${TOPOLOGY:-legacy}"
  ROUTER_IP="${ROUTER_IP:-192.168.1.1}"
  ADMIN_IP="${ADMIN_IP:-192.168.1.113}"
  RASPI4B_IP="${RASPI4B_IP:-192.168.1.167}"
  RASPI3B_IP="${RASPI3B_IP:-192.168.1.181}"
  PORTAL_NODE_IP="${PORTAL_NODE_IP:-192.168.1.182}"
  AI_IP="${AI_IP:-$RASPI4B_IP}"

  if [[ -z "${PORTAL_IP:-}" ]]; then
    if [[ "$TOPOLOGY" == "split_portal" ]]; then
      PORTAL_IP="$PORTAL_NODE_IP"
    else
      PORTAL_IP="$RASPI4B_IP"
    fi
  fi

  CAPTIVE_DOMAIN="${CAPTIVE_DOMAIN:-captive.localhost.com}"
  PEOPLE_DOMAIN="${PEOPLE_DOMAIN:-people.localhost.com}"
}

ensure_topology_value() {
  case "${TOPOLOGY:-}" in
    legacy|split_portal) ;;
    *) echo "TOPOLOGY invalida: ${TOPOLOGY:-<empty>}"; return 1 ;;
  esac
}
