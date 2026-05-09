#!/bin/bash
# setup-raspi3b-deps.sh — Instala TODAS las dependencias del SO para Raspi3B
#                         (Debian/DietPi Bookworm armhf/arm64)
#
# Delega en lib/raspi3b-deps.sh que expone funciones reutilizables:
#   install_raspi3b_base       — herramientas base del sistema
#   install_raspi3b_capture    — tshark + tcpdump (captura de red)
#   install_raspi3b_python     — python3 + pip + paho-mqtt + requests
#   install_raspi3b_podman     — podman (solo para topología split_portal)
#   install_raspi3b_all_deps   — llama a todas las anteriores
#
# Los mismos scripts de componente pueden importar sólo lo que necesitan:
#   . "$SCRIPT_DIR/lib/raspi3b-deps.sh"
#   install_raspi3b_capture    # solo tshark + tcpdump
#   install_raspi3b_python     # solo Python + paho-mqtt
#
# Uso:
#   sudo bash scripts/setup-raspi3b-deps.sh
#   sudo bash scripts/setup-raspi3b-deps.sh --with-podman    # incluir podman (split_portal)
#   sudo bash scripts/setup-raspi3b-deps.sh --skip-capture   # omitir tshark/tcpdump
#   sudo bash scripts/setup-raspi3b-deps.sh --dry-run

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Logging mínimo para scripts independientes de Pi3B
_init_log() {
    local log_dir="/var/log/demo-openwrt/deps"
    mkdir -p "$log_dir" 2>/dev/null || log_dir="/tmp/demo-openwrt/deps"
    mkdir -p "$log_dir" 2>/dev/null || true
    local log_file="$log_dir/setup-raspi3b-deps-$(date '+%Y%m%d-%H%M%S').log"
    if command -v tee &>/dev/null && command -v mkfifo &>/dev/null; then
        local pipe="/tmp/r3b-deps-$$.pipe"
        mkfifo "$pipe"
        tee -a "$log_file" < "$pipe" &
        local tee_pid=$!
        exec > "$pipe" 2>&1
        trap "exec 1>&- 2>&-; wait $tee_pid 2>/dev/null; rm -f $pipe; exit" EXIT INT TERM
    else
        exec >> "$log_file" 2>&1
    fi
    printf '[INFO]  Log: %s\n' "$log_file"
}

# shellcheck source=./lib/raspi3b-deps.sh
. "$SCRIPT_DIR/lib/raspi3b-deps.sh"

# ─── Flags ────────────────────────────────────────────────────────────────────
WITH_PODMAN=false
SKIP_CAPTURE=false
DRY_RUN=false   # exportado para que lib/raspi3b-deps.sh lo tome via _DRY_RUN

for arg in "$@"; do
    case "$arg" in
        --with-podman)   WITH_PODMAN=true ;;
        --skip-capture)  SKIP_CAPTURE=true ;;
        --dry-run)       DRY_RUN=true ;;
        --help|-h)
            printf 'Uso: sudo bash %s [--with-podman] [--skip-capture] [--dry-run]\n' "$(basename "$0")"
            exit 0 ;;
        *)
            printf '[WARN]  Argumento ignorado: %s\n' "$arg" ;;
    esac
done
export DRY_RUN
_DRY_RUN="$DRY_RUN"

[ "${EUID:-$(id -u)}" -eq 0 ] || { printf '[ERROR] Ejecutar como root\n' >&2; exit 1; }

_init_log

_r3b_log_info "=== setup-raspi3b-deps (Debian/DietPi Bookworm) ==="
_r3b_log_info "Arch: $(uname -m) | OS: $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || cat /etc/debian_version 2>/dev/null || echo 'Debian')"

# ─── Instalar grupos según flags ──────────────────────────────────────────────
install_raspi3b_base
$SKIP_CAPTURE || install_raspi3b_capture
install_raspi3b_python
$WITH_PODMAN  && install_raspi3b_podman || true

# ─── Verificación final ───────────────────────────────────────────────────────
if $DRY_RUN; then
    _r3b_log_ok "Dry-run completado"
    exit 0
fi

_r3b_log_info "── Verificación de comandos ──────────────────────────────"
_chk3() {
    local cmd="$1" label="${2:-$1}"
    command -v "$cmd" &>/dev/null \
        && _r3b_log_ok "  ✓ ${label}: $($cmd --version 2>/dev/null | head -1 || echo 'ok')" \
        || _r3b_log_warn "  ✗ ${label}: no encontrado"
}
_chk3 curl; _chk3 wget; _chk3 git; _chk3 jq; _chk3 python3; _chk3 pip3
! $SKIP_CAPTURE && { _chk3 tshark; _chk3 tcpdump; }
$WITH_PODMAN && _chk3 podman
python3 -c "import paho.mqtt" 2>/dev/null && _r3b_log_ok "  ✓ paho-mqtt" || _r3b_log_warn "  ✗ paho-mqtt"
python3 -c "import requests"  2>/dev/null && _r3b_log_ok "  ✓ requests"  || _r3b_log_warn "  ✗ requests"

printf "\n"
_r3b_log_ok "=== setup-raspi3b-deps completado ==="
printf "\n"
printf "  Siguiente paso:\n"
printf "    sudo bash scripts/setup-sensor-raspi3b.sh\n"
printf "\n"
