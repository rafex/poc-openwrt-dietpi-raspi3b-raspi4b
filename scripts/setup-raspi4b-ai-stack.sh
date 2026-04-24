#!/bin/bash
# Bundle Raspi4B: instala SOLO stack IA (mosquitto + llm + ai-analyzer).
# No despliega portales.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib/raspi4b-common.sh
. "$SCRIPT_DIR/lib/raspi4b-common.sh"
# shellcheck source=./lib/topology-common.sh
. "$SCRIPT_DIR/lib/topology-common.sh"

SKIP_MOSQUITTO=false
SKIP_LLM=false
SKIP_ANALYZER=false

parse_common_flags "$@"
ARGS=("${REM_ARGS[@]}")
REM_ARGS=()
for a in "${ARGS[@]}"; do
  case "$a" in
    --skip-mosquitto) SKIP_MOSQUITTO=true ;;
    --skip-llm) SKIP_LLM=true ;;
    --skip-analyzer) SKIP_ANALYZER=true ;;
    *) REM_ARGS+=("$a") ;;
  esac
done

init_log_dir "ai-stack"
need_root
load_topology

[ "${#REM_ARGS[@]}" -eq 0 ] || die "Argumentos no soportados: ${REM_ARGS[*]}"

log_info "--- setup-raspi4b-ai-stack ---"
log_info "Bundle: mosquitto + llm + ai-analyzer (sin portales)"

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

if ! $SKIP_ANALYZER && ! $DRY_RUN; then
  PI_IP="${AI_IP:-192.168.1.167}"
  for ep in /dashboard /rulez; do
    code="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "http://${PI_IP}${ep}" 2>/dev/null || echo 000)"
    case "$code" in
      200|301|302|307|308) log_ok "${ep} HTTP ${code}" ;;
      *) die "Fallo verificación ${ep}: HTTP ${code}" ;;
    esac
  done
fi

log_ok "setup-raspi4b-ai-stack completado"

