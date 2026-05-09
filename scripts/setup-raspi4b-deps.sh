#!/bin/bash
# setup-raspi4b-deps.sh — Instala TODAS las dependencias del SO para Raspi4B
#                         (Debian/DietPi Bookworm arm64)
#
# Delega en lib/raspi4b-deps.sh que expone funciones reutilizables:
#   install_raspi4b_base       — herramientas base del sistema
#   install_raspi4b_podman     — contenedores (podman + uidmap + slirp4netns)
#   install_raspi4b_mosquitto  — broker MQTT
#   install_raspi4b_age_sops   — cifrado de secretos (age + sops arm64)
#   install_raspi4b_node       — Node.js 20 LTS via NodeSource
#   install_raspi4b_all_deps   — llama a todas las anteriores
#
# Los mismos scripts de componente pueden importar sólo lo que necesitan:
#   . "$SCRIPT_DIR/lib/raspi4b-common.sh"
#   . "$SCRIPT_DIR/lib/raspi4b-deps.sh"
#   install_raspi4b_age_sops   # solo age + sops
#
# Uso:
#   sudo bash scripts/setup-raspi4b-deps.sh
#   sudo bash scripts/setup-raspi4b-deps.sh --skip-node
#   sudo bash scripts/setup-raspi4b-deps.sh --skip-mosquitto
#   sudo bash scripts/setup-raspi4b-deps.sh --dry-run

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./lib/raspi4b-common.sh
. "$SCRIPT_DIR/lib/raspi4b-common.sh"
# shellcheck source=./lib/raspi4b-deps.sh
. "$SCRIPT_DIR/lib/raspi4b-deps.sh"

# ─── Flags ────────────────────────────────────────────────────────────────────
SKIP_NODE=false
SKIP_MOSQUITTO=false

_parse_extra_flags() {
    local -a extra=()
    for arg in "$@"; do
        case "$arg" in
            --skip-node)       SKIP_NODE=true ;;
            --skip-mosquitto)  SKIP_MOSQUITTO=true ;;
            *)                 extra+=("$arg") ;;
        esac
    done
    parse_common_flags "${extra[@]+"${extra[@]}"}"
}
_parse_extra_flags "$@"

init_log_dir "deps"
need_root

log_info "=== setup-raspi4b-deps (Debian/DietPi Bookworm arm64) ==="
log_info "Arch: $(uname -m) | OS: $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || cat /etc/debian_version 2>/dev/null || echo 'Debian')"

# ─── Instalar grupos según flags ──────────────────────────────────────────────
install_raspi4b_base
install_raspi4b_podman
install_raspi4b_age_sops
$SKIP_MOSQUITTO || install_raspi4b_mosquitto
$SKIP_NODE      || install_raspi4b_node

# ─── Verificación final ───────────────────────────────────────────────────────
if $DRY_RUN; then
    log_ok "Dry-run completado"
    exit 0
fi

log_info "── Verificación de comandos ──────────────────────────────"
_chk() {
    local cmd="$1" label="${2:-$1}"
    command -v "$cmd" &>/dev/null \
        && log_ok "  ✓ ${label}: $($cmd --version 2>/dev/null | head -1 || echo 'ok')" \
        || log_warn "  ✗ ${label}: no encontrado"
}
_chk curl; _chk wget; _chk git; _chk jq; _chk python3
_chk podman; _chk age; _chk sops
! $SKIP_MOSQUITTO && _chk mosquitto_pub "mosquitto-clients"
! $SKIP_NODE      && _chk node "node.js" && _chk npm

printf "\n"
log_ok "=== setup-raspi4b-deps completado ==="
printf "\n"
printf "  Siguiente paso:\n"
printf "    sudo bash scripts/setup-raspi4b-all.sh\n"
printf "\n"
printf "  O por componente:\n"
printf "    sudo bash scripts/setup-raspi4b-mosquitto.sh\n"
printf "    sudo bash scripts/setup-raspi4b-llm.sh\n"
printf "    sudo bash scripts/setup-raspi4b-ai-analyzer-java.sh\n"
printf "    sudo bash scripts/setup-raspi4b-frontend.sh\n"
printf "\n"
