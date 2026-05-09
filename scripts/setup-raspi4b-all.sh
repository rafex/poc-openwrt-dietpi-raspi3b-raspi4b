#!/bin/bash
# setup-raspi4b-all.sh — Instalación integral Raspi4B (stack Java nativo)
#
# Orden de ejecución por defecto:
#   0. setup-raspi4b-deps.sh        — dependencias Debian/DietPi
#   1. setup-raspi4b-mosquitto.sh   — broker MQTT
#   2. setup-raspi4b-llm.sh         — llama.cpp server
#   3. setup-raspi4b-ai-analyzer-java.sh — ai-analyzer (GraalVM nativo + Rust .so)
#   4. setup-raspi4b-frontend.sh    — frontend Vite dist + nginx proxy (podman)
#   5. setup-raspi4b-portals.sh     — portales cautivos (solo topología legacy)
#
# Flags:
#   --skip-deps        # omitir instalación de dependencias del SO
#   --skip-mosquitto   # omitir Mosquitto
#   --skip-llm         # omitir llama.cpp
#   --skip-analyzer    # omitir ai-analyzer Java
#   --skip-frontend    # omitir frontend nginx/podman
#   --skip-portals     # omitir portales cautivos
#   --headless-web     # solo IA (analyzer + LLM + MQTT), sin portales ni frontend
#   --dry-run          # mostrar acciones sin ejecutar
#   --only-verify      # solo verificar estado actual
#
# Uso:
#   sudo bash scripts/setup-raspi4b-all.sh
#   sudo bash scripts/setup-raspi4b-all.sh --skip-llm --skip-portals
#   sudo bash scripts/setup-raspi4b-all.sh --headless-web

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./lib/raspi4b-common.sh
. "$SCRIPT_DIR/lib/raspi4b-common.sh"
# shellcheck source=./lib/topology-common.sh
. "$SCRIPT_DIR/lib/topology-common.sh"

# ─── Flags ────────────────────────────────────────────────────────────────────
SKIP_DEPS=false
SKIP_MOSQUITTO=false
SKIP_LLM=false
SKIP_ANALYZER=false
SKIP_FRONTEND=false
SKIP_PORTALS=false
HEADLESS_WEB=false

_parse_extra_flags() {
    local -a extra=()
    for arg in "$@"; do
        case "$arg" in
            --skip-deps)       SKIP_DEPS=true ;;
            --skip-mosquitto)  SKIP_MOSQUITTO=true ;;
            --skip-llm)        SKIP_LLM=true ;;
            --skip-analyzer)   SKIP_ANALYZER=true ;;
            --skip-frontend)   SKIP_FRONTEND=true ;;
            --skip-portals)    SKIP_PORTALS=true ;;
            --headless-web)    HEADLESS_WEB=true ;;
            *)                 extra+=("$arg") ;;
        esac
    done
    parse_common_flags "${extra[@]+"${extra[@]}"}"
}
_parse_extra_flags "$@"

init_log_dir "all"
need_root
load_topology

log_info "=== setup-raspi4b-all (stack Java nativo + frontend Vite) ==="

# Modo headless: solo IA, sin portales ni frontend
if $HEADLESS_WEB || [[ "${TOPOLOGY:-legacy}" == "split_portal" ]]; then
    SKIP_PORTALS=true
    SKIP_FRONTEND=true
    log_info "Modo headless/split_portal: se omiten portales y frontend en Raspi4B"
fi

# ─── Helpers ──────────────────────────────────────────────────────────────────
COMMON_FLAGS=()
$DRY_RUN      && COMMON_FLAGS+=(--dry-run)
$ONLY_VERIFY  && COMMON_FLAGS+=(--only-verify)
$FORCE        && COMMON_FLAGS+=(--force)
$NO_BUILD     && COMMON_FLAGS+=(--no-build)

run_component() {
    local label="$1" script="$2"
    shift 2
    log_info ""
    log_info "────────────────────────────────────────────────────────"
    log_info "  Ejecutando: ${label}"
    log_info "────────────────────────────────────────────────────────"
    bash "$script" "$@"
    log_ok "  ${label} completado"
}

# ─── Paso 0 — Dependencias del SO ─────────────────────────────────────────────
if ! $SKIP_DEPS; then
    DEPS_FLAGS=("${COMMON_FLAGS[@]}")
    # Omitir mosquitto en deps si lo va a instalar el script dedicado
    $SKIP_MOSQUITTO && DEPS_FLAGS+=(--skip-mosquitto)
    # Node.js solo si desplegamos frontend
    $SKIP_FRONTEND  && DEPS_FLAGS+=(--skip-node)

    run_component "Dependencias SO (Debian/DietPi)" \
        "$SCRIPT_DIR/setup-raspi4b-deps.sh" "${DEPS_FLAGS[@]}"
else
    log_info "Paso 0 (deps): OMITIDO"
fi

# ─── Paso 1 — Mosquitto MQTT ──────────────────────────────────────────────────
if ! $SKIP_MOSQUITTO; then
    run_component "Mosquitto MQTT broker" \
        "$SCRIPT_DIR/setup-raspi4b-mosquitto.sh" "${COMMON_FLAGS[@]}"
else
    log_info "Paso 1 (mosquitto): OMITIDO"
fi

# ─── Paso 2 — llama.cpp LLM ───────────────────────────────────────────────────
if ! $SKIP_LLM; then
    run_component "llama.cpp server (LLM local)" \
        "$SCRIPT_DIR/setup-raspi4b-llm.sh" "${COMMON_FLAGS[@]}"
else
    log_info "Paso 2 (llm): OMITIDO"
fi

# ─── Paso 3 — AI Analyzer (binario GraalVM nativo) ───────────────────────────
if ! $SKIP_ANALYZER; then
    run_component "AI Analyzer Java nativo (GraalVM arm64)" \
        "$SCRIPT_DIR/setup-raspi4b-ai-analyzer-java.sh" "${COMMON_FLAGS[@]}"
else
    log_info "Paso 3 (ai-analyzer): OMITIDO"
fi

# ─── Paso 4 — Frontend + nginx proxy (podman) ────────────────────────────────
if ! $SKIP_FRONTEND; then
    FRONTEND_FLAGS=("${COMMON_FLAGS[@]}")
    # Si el dist/ ya fue construido localmente y sincronizado, podemos saltar build
    run_component "Frontend Vite dist + nginx proxy (podman)" \
        "$SCRIPT_DIR/setup-raspi4b-frontend.sh" "${FRONTEND_FLAGS[@]}"
else
    log_info "Paso 4 (frontend): OMITIDO"
fi

# ─── Paso 5 — Portales cautivos (solo topología legacy) ──────────────────────
if ! $SKIP_PORTALS; then
    run_component "Portales cautivos" \
        "$SCRIPT_DIR/setup-raspi4b-portals.sh" "${COMMON_FLAGS[@]}"
else
    log_info "Paso 5 (portales): OMITIDO"
fi

# ─── Resumen ──────────────────────────────────────────────────────────────────
PI_IP="${AI_IP:-${RASPI4B_IP:-192.168.1.167}}"

printf "\n"
log_ok "=== setup-raspi4b-all completado ==="
printf "\n"
printf "  Acceso al sistema:\n"
printf "    http://%s/               → Dashboard (nginx proxy)\n" "$PI_IP"
printf "    http://%s/chat.html      → Chat IA (Groq/Qwen)\n"    "$PI_IP"
printf "    http://%s/health         → Health API Java\n"         "$PI_IP"
printf "    http://%s:5000/health    → Health directo (sin proxy)\n" "$PI_IP"
printf "\n"
printf "  Gestión de servicios:\n"
printf "    systemctl status ai-analyzer\n"
printf "    journalctl -u ai-analyzer -f\n"
printf "    podman ps\n"
printf "\n"
printf "  Diagnóstico:\n"
printf "    bash scripts/health-raspi4b.sh\n"
printf "    bash scripts/verify-topology.sh\n"
printf "\n"
