#!/bin/bash
# raspi4b-k3s-doctor.sh — Diagnóstico y reparación de k3s en Raspberry Pi 4B (DietPi)
#
# Problemas que detecta y repara:
#   1. cgroup memory no habilitado en /boot/cmdline.txt  ← causa raíz más frecuente
#   2. k3s servicio deshabilitado o parado
#   3. Socket containerd no disponible (/run/k3s/containerd/containerd.sock)
#   4. kubectl no responde (API server no listo)
#   5. k3s no instalado
#   6. Conflicto entre containerd del sistema y containerd de k3s
#
# Uso:
#   bash scripts/raspi4b-k3s-doctor.sh              # diagnóstico + reparación interactiva
#   bash scripts/raspi4b-k3s-doctor.sh --fix        # reparar sin preguntar
#   bash scripts/raspi4b-k3s-doctor.sh --check      # solo diagnóstico, sin cambios
#   bash scripts/raspi4b-k3s-doctor.sh --restart    # reiniciar k3s y esperar
#
# Ejecutar directamente en la Raspi 4B como root.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Colores ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

hdr()  { printf "\n${BOLD}${CYAN}━━━ %s ━━━${NC}\n" "$*"; }
ok()   { printf "  ${GREEN}✓${NC} %s\n" "$*"; }
fail() { printf "  ${RED}✗${NC} %s\n" "$*"; ISSUES=$((ISSUES + 1)); }
warn() { printf "  ${YELLOW}!${NC} %s\n" "$*"; }
info() { printf "  ${BLUE}·${NC} %s\n" "$*"; }
die()  { printf "${RED}ERROR${NC}: %s\n" "$*" >&2; exit 1; }
fixed(){ printf "  ${GREEN}↳ REPARADO${NC}: %s\n" "$*"; FIXED=$((FIXED + 1)); }

# ─── Argumentos ──────────────────────────────────────────────────────────────
FIX_MODE=false
CHECK_ONLY=false
RESTART_MODE=false

for arg in "$@"; do
    case "$arg" in
        --fix|-f)       FIX_MODE=true ;;
        --check|-c)     CHECK_ONLY=true ;;
        --restart|-r)   RESTART_MODE=true ;;
        --help|-h)
            sed -n '2,26p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *) die "Argumento desconocido: $arg" ;;
    esac
done

[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Ejecutar como root (sudo bash $0)"

ISSUES=0
FIXED=0
NEED_REBOOT=false
K3S_SOCK="/run/k3s/containerd/containerd.sock"
CMDLINE_FILE=""

# Detectar ruta de cmdline.txt (varía según versión DietPi/Debian)
for f in /boot/firmware/cmdline.txt /boot/cmdline.txt; do
    [[ -f "$f" ]] && CMDLINE_FILE="$f" && break
done

# ─── Modo restart rápido ──────────────────────────────────────────────────────
if $RESTART_MODE; then
    printf "\n${BOLD}Reiniciando k3s...${NC}\n"
    systemctl restart k3s
    printf "Esperando socket containerd"
    waited=0
    while [[ ! -S "$K3S_SOCK" ]] && [[ $waited -lt 90 ]]; do
        printf "."; sleep 3; waited=$((waited + 3))
    done
    printf "\n"
    [[ -S "$K3S_SOCK" ]] || die "Socket no apareció tras 90s"
    ok "Socket containerd listo ($waited s)"
    printf "Esperando kubectl"
    waited=0
    while ! k3s kubectl get nodes >/dev/null 2>&1 && [[ $waited -lt 120 ]]; do
        printf "."; sleep 5; waited=$((waited + 5))
    done
    printf "\n"
    k3s kubectl get nodes || die "kubectl no responde"
    ok "k3s listo"
    k3s kubectl get pods -A
    exit 0
fi

# ─── Cabecera ─────────────────────────────────────────────────────────────────
printf "\n${BOLD}╔══════════════════════════════════════════════════╗${NC}\n"
printf   "${BOLD}║  k3s Doctor — Raspi 4B (DietPi)     %-11s║${NC}\n" "$(date '+%H:%M:%S')"
printf   "${BOLD}╚══════════════════════════════════════════════════╝${NC}\n"
printf "  Modo: %s\n" "$( $CHECK_ONLY && echo 'solo diagnóstico' || ($FIX_MODE && echo 'reparación automática' || echo 'interactivo') )"
printf "  cmdline.txt: %s\n" "${CMDLINE_FILE:-no encontrado}"

# ─── DIAGNÓSTICO 1: k3s instalado ─────────────────────────────────────────────
hdr "1. k3s instalado"
if command -v k3s &>/dev/null; then
    ok "k3s encontrado: $(command -v k3s)"
    info "Versión: $(k3s --version 2>/dev/null | head -1 || echo 'n/a')"
else
    fail "k3s NO está instalado"
    if ! $CHECK_ONLY; then
        warn "Para instalarlo:"
        printf "    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC='--disable traefik' sh -\n"
        printf "    systemctl enable k3s\n"
    fi
fi

# ─── DIAGNÓSTICO 2: cgroups ──────────────────────────────────────────────────
hdr "2. Cgroup memory (requerido por k3s en Raspberry Pi)"

CGROUP_OK=true
if [[ -z "$CMDLINE_FILE" ]]; then
    warn "cmdline.txt no encontrado — no se puede verificar cgroups desde aquí"
else
    CMDLINE_CONTENT="$(cat "$CMDLINE_FILE")"
    if echo "$CMDLINE_CONTENT" | grep -q "cgroup_enable=memory"; then
        ok "cgroup_enable=memory presente en $CMDLINE_FILE"
    else
        fail "cgroup_enable=memory NO está en $CMDLINE_FILE"
        CGROUP_OK=false
    fi
    if echo "$CMDLINE_CONTENT" | grep -q "cgroup_memory=1"; then
        ok "cgroup_memory=1 presente en $CMDLINE_FILE"
    else
        fail "cgroup_memory=1 NO está en $CMDLINE_FILE"
        CGROUP_OK=false
    fi
fi

# Verificar en runtime
if [[ -f /proc/cgroups ]]; then
    if grep -q "^memory.*1$" /proc/cgroups 2>/dev/null; then
        ok "cgroup memory activo en runtime"
    else
        warn "cgroup memory NO activo en runtime (requiere reboot tras fix en cmdline.txt)"
    fi
fi

if ! $CGROUP_OK && [[ -n "$CMDLINE_FILE" ]]; then
    if ! $CHECK_ONLY; then
        DO_FIX=$FIX_MODE
        if ! $FIX_MODE; then
            printf "\n  ¿Agregar cgroup_enable=memory cgroup_memory=1 a %s? [s/N] " "$CMDLINE_FILE"
            read -r resp
            [[ "${resp,,}" == "s" ]] && DO_FIX=true
        fi
        if $DO_FIX; then
            # Hacer backup
            cp "$CMDLINE_FILE" "${CMDLINE_FILE}.bak.$(date +%Y%m%d%H%M%S)"
            # Añadir al final de la línea (cmdline.txt es una sola línea)
            CURRENT="$(cat "$CMDLINE_FILE")"
            echo "$CURRENT cgroup_enable=memory cgroup_memory=1" > "$CMDLINE_FILE"
            fixed "Agregado cgroup_enable=memory cgroup_memory=1 a $CMDLINE_FILE"
            NEED_REBOOT=true
            warn "Se requiere REBOOT para que los cgroups tomen efecto"
        fi
    fi
fi

# ─── DIAGNÓSTICO 3: servicio k3s ─────────────────────────────────────────────
hdr "3. Servicio systemd k3s"

if systemctl is-enabled k3s &>/dev/null; then
    ok "k3s.service está habilitado (autostart)"
else
    fail "k3s.service NO está habilitado — no arranca tras reboot"
    if ! $CHECK_ONLY; then
        DO_FIX=$FIX_MODE
        if ! $FIX_MODE; then
            printf "\n  ¿Habilitar k3s.service? [s/N] "
            read -r resp
            [[ "${resp,,}" == "s" ]] && DO_FIX=true
        fi
        $DO_FIX && systemctl enable k3s && fixed "k3s.service habilitado"
    fi
fi

K3S_STATE="$(systemctl is-active k3s 2>/dev/null || echo 'unknown')"
case "$K3S_STATE" in
    active)   ok "k3s.service activo (running)" ;;
    activating)
        warn "k3s.service arrancando — esperando..."
        sleep 5
        ;;
    failed)
        fail "k3s.service en estado FAILED"
        info "Últimas líneas del journal:"
        journalctl -u k3s -n 30 --no-pager 2>/dev/null | tail -20 | sed 's/^/    /'
        if ! $CHECK_ONLY; then
            DO_FIX=$FIX_MODE
            if ! $FIX_MODE; then
                printf "\n  ¿Intentar reiniciar k3s? [s/N] "
                read -r resp
                [[ "${resp,,}" == "s" ]] && DO_FIX=true
            fi
            if $DO_FIX; then
                systemctl reset-failed k3s 2>/dev/null || true
                systemctl start k3s && fixed "k3s reiniciado" || warn "El reinicio falló — revisa el journal"
            fi
        fi
        ;;
    inactive|unknown|*)
        fail "k3s.service inactivo (estado: $K3S_STATE)"
        if ! $CHECK_ONLY; then
            DO_FIX=$FIX_MODE
            if ! $FIX_MODE; then
                printf "\n  ¿Arrancar k3s? [s/N] "
                read -r resp
                [[ "${resp,,}" == "s" ]] && DO_FIX=true
            fi
            $DO_FIX && systemctl start k3s && fixed "k3s arrancado" || true
        fi
        ;;
esac

# ─── DIAGNÓSTICO 4: socket containerd ────────────────────────────────────────
hdr "4. Socket containerd de k3s ($K3S_SOCK)"

if [[ -S "$K3S_SOCK" ]]; then
    ok "Socket existe y es accesible"
    info "Permisos: $(stat -c '%a %U:%G' "$K3S_SOCK" 2>/dev/null || echo 'n/a')"
else
    fail "Socket NO existe: $K3S_SOCK"
    info "Esto indica que k3s no está corriendo o containerd aún no inicializó"

    if ! $CHECK_ONLY && systemctl is-active k3s &>/dev/null; then
        info "k3s está activo — esperando socket (máx 60s)..."
        waited=0
        while [[ ! -S "$K3S_SOCK" ]] && [[ $waited -lt 60 ]]; do
            printf "    [%ds] esperando...\n" "$waited"
            sleep 5; waited=$((waited + 5))
        done
        if [[ -S "$K3S_SOCK" ]]; then
            ok "Socket apareció tras ${waited}s"
            ISSUES=$((ISSUES - 1))   # no era un problema real, solo timing
        else
            warn "Socket no apareció en 60s — k3s puede necesitar más tiempo o hay otro error"
        fi
    fi
fi

# Verificar conflicto con containerd del sistema
if [[ -S "/run/containerd/containerd.sock" ]]; then
    warn "Containerd del sistema también está activo (/run/containerd/containerd.sock)"
    info "k3s usa su propio containerd en /run/k3s/containerd/ — normalmente no hay conflicto"
    info "Si hay problemas: systemctl stop containerd && systemctl disable containerd"
fi

# ─── DIAGNÓSTICO 5: kubectl / API server ─────────────────────────────────────
hdr "5. kubectl / API server"

if k3s kubectl get nodes >/dev/null 2>&1; then
    ok "kubectl responde"
    printf "\n"
    k3s kubectl get nodes -o wide 2>/dev/null | sed 's/^/    /'
    printf "\n"
    k3s kubectl get pods -A 2>/dev/null | sed 's/^/    /'
else
    fail "kubectl NO responde"
    info "El API server puede estar inicializándose — esperar 30-60s más es normal"
    info "Diagnóstico rápido:"
    printf "    journalctl -u k3s -f\n"
    printf "    k3s kubectl get nodes\n"
fi

# ─── DIAGNÓSTICO 6: memoria disponible ───────────────────────────────────────
hdr "6. Memoria disponible (k3s requiere ≥ 512 MB libres)"

FREE_MB="$(awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)"
TOTAL_MB="$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)"

if [[ "$FREE_MB" -gt 512 ]]; then
    ok "Memoria disponible: ${FREE_MB} MB / ${TOTAL_MB} MB"
else
    warn "Memoria disponible baja: ${FREE_MB} MB — k3s puede tener problemas"
fi

# ─── DIAGNÓSTICO 7: espacio en disco ─────────────────────────────────────────
hdr "7. Espacio en disco"

ROOT_AVAIL="$(df -BM / | awk 'NR==2{print $4}' | tr -d M 2>/dev/null || echo 0)"
if [[ "$ROOT_AVAIL" -gt 1000 ]]; then
    ok "Espacio disponible en /: ${ROOT_AVAIL} MB"
else
    warn "Espacio en disco bajo en /: ${ROOT_AVAIL} MB"
fi

# ─── DIAGNÓSTICO 8: imágenes en k3s containerd ───────────────────────────────
hdr "8. Imágenes en k3s containerd"

if [[ -S "$K3S_SOCK" ]]; then
    AI_IMG="$(k3s ctr images ls 2>/dev/null | grep ai-analyzer | head -3 || echo '')"
    if [[ -n "$AI_IMG" ]]; then
        ok "Imagen ai-analyzer presente en k3s:"
        echo "$AI_IMG" | sed 's/^/    /'
    else
        warn "Imagen ai-analyzer NO está en k3s containerd"
        info "Para importarla: bash scripts/setup-raspi4b-ai-analyzer.sh --no-build"
        info "  (usa --no-build si la imagen ya está construida con podman)"
    fi
    info "Todas las imágenes:"
    k3s ctr images ls 2>/dev/null | awk 'NR==1 || /localhost/' | sed 's/^/    /'
else
    warn "Socket no disponible — no se pueden listar imágenes"
fi

# ─── Resumen final ────────────────────────────────────────────────────────────
hdr "Resumen"

if [[ $ISSUES -eq 0 ]]; then
    printf "  ${GREEN}${BOLD}✓ k3s parece estar en buen estado${NC}\n"
elif [[ $FIXED -gt 0 ]]; then
    printf "  ${YELLOW}${BOLD}⚠ ${ISSUES} problema(s) detectado(s), ${FIXED} reparado(s)${NC}\n"
else
    printf "  ${RED}${BOLD}✗ ${ISSUES} problema(s) detectado(s) sin reparar${NC}\n"
fi

if $NEED_REBOOT; then
    printf "\n  ${RED}${BOLD}⚡ REBOOT REQUERIDO para aplicar cambios en cmdline.txt${NC}\n"
    printf "\n  ¿Reiniciar ahora? [s/N] "
    read -r resp
    if [[ "${resp,,}" == "s" ]]; then
        printf "  Reiniciando en 3 segundos...\n"
        sleep 3
        reboot
    else
        printf "  Ejecuta manualmente: sudo reboot\n"
    fi
fi

printf "\n  Comandos útiles de diagnóstico:\n"
printf "    journalctl -u k3s -n 50 --no-pager\n"
printf "    systemctl status k3s\n"
printf "    k3s kubectl get pods -A\n"
printf "    k3s ctr images ls\n"
printf "    cat %s\n" "${CMDLINE_FILE:-/boot/cmdline.txt}"
printf "\n"
