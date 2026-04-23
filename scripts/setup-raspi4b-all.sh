#!/bin/bash
# Instalación integral Raspi4B: mosquitto + llm + ai-analyzer + portales.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib/raspi4b-common.sh
. "$SCRIPT_DIR/lib/raspi4b-common.sh"
# shellcheck source=./lib/topology-common.sh
. "$SCRIPT_DIR/lib/topology-common.sh"

SKIP_MOSQUITTO=false
SKIP_LLM=false
SKIP_ANALYZER=false
SKIP_PORTALS=false
HEADLESS_WEB=false

parse_common_flags "$@"
ARGS=("${REM_ARGS[@]}")
REM_ARGS=()
for a in "${ARGS[@]}"; do
  case "$a" in
    --skip-mosquitto) SKIP_MOSQUITTO=true ;;
    --skip-llm) SKIP_LLM=true ;;
    --skip-analyzer) SKIP_ANALYZER=true ;;
    --skip-portals) SKIP_PORTALS=true ;;
    --headless-web) HEADLESS_WEB=true ;;
    *) REM_ARGS+=("$a") ;;
  esac
done

init_log_dir "all"
need_root
load_topology
[ "${#REM_ARGS[@]}" -eq 0 ] || die "Argumentos no soportados: ${REM_ARGS[*]}"

log_info "--- setup-raspi4b-all ---"

if $HEADLESS_WEB || [[ "${TOPOLOGY:-legacy}" == "split_portal" ]]; then
  SKIP_PORTALS=true
  log_info "Modo headless/split_portal: se omite despliegue de portales en Raspi4B"
fi

COMMON_FLAGS=()
$DRY_RUN && COMMON_FLAGS+=(--dry-run)
$ONLY_VERIFY && COMMON_FLAGS+=(--only-verify)
$FORCE && COMMON_FLAGS+=(--force)
$NO_BUILD && COMMON_FLAGS+=(--no-build)

run_component() {
  local script="$1"
  shift
  log_info "Ejecutando: $(basename "$script") $*"
  bash "$script" "$@"
}

$SKIP_MOSQUITTO || run_component "$SCRIPT_DIR/setup-raspi4b-mosquitto.sh" "${COMMON_FLAGS[@]}"
$SKIP_LLM || run_component "$SCRIPT_DIR/setup-raspi4b-llm.sh" "${COMMON_FLAGS[@]}"
$SKIP_ANALYZER || run_component "$SCRIPT_DIR/setup-raspi4b-ai-analyzer.sh" "${COMMON_FLAGS[@]}"
$SKIP_PORTALS || run_component "$SCRIPT_DIR/setup-raspi4b-portals.sh" "${COMMON_FLAGS[@]}"

log_ok "setup-raspi4b-all completado"
