#!/bin/bash
# raspi4b-clean-k3s.sh — Elimina k3s completo de la Raspi 4B y libera recursos
#
# Qué hace:
#   1. Para y elimina todos los pods/deployments de k3s
#   2. Ejecuta el desinstalador oficial de k3s (/usr/local/bin/k3s-uninstall.sh)
#   3. Elimina directorios de datos de k3s y containerd embebido
#   4. Elimina namespaces de red virtuales huérfanos (flannel/cni)
#   5. Libera puertos ocupados por k3s (6443, 10250, 10251, 10252)
#   6. Opcional: elimina la imagen ai-analyzer de podman (para reimportar limpio)
#
# Uso:
#   bash scripts/raspi4b-clean-k3s.sh              # interactivo
#   bash scripts/raspi4b-clean-k3s.sh --force      # sin confirmación
#   bash scripts/raspi4b-clean-k3s.sh --dry-run    # ver qué haría sin ejecutar
#   bash scripts/raspi4b-clean-k3s.sh --keep-image # no borrar imagen podman
#
# Ejecutar directamente en la Raspi 4B como root.

set -euo pipefail

# ─── Colores ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

hdr()   { printf "\n${BOLD}${CYAN}━━━ %s ━━━${NC}\n" "$*"; }
ok()    { printf "  ${GREEN}✓${NC} %s\n" "$*"; }
warn()  { printf "  ${YELLOW}!${NC} %s\n" "$*"; }
info()  { printf "  ${BLUE}·${NC} %s\n" "$*"; }
skip()  { printf "  ${BLUE}↷${NC} %s (no encontrado, omitiendo)\n" "$*"; }
die()   { printf "${RED}ERROR${NC}: %s\n" "$*" >&2; exit 1; }

FORCE=false
DRY_RUN=false
KEEP_IMAGE=false

for arg in "$@"; do
    case "$arg" in
        --force|-f)      FORCE=true ;;
        --dry-run|-n)    DRY_RUN=true ;;
        --keep-image)    KEEP_IMAGE=true ;;
        --help|-h)
            sed -n '2,24p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *) die "Argumento desconocido: $arg" ;;
    esac
done

[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Ejecutar como root"

run() {
    if $DRY_RUN; then
        printf "  [dry-run] %s\n" "$*"
    else
        "$@"
    fi
}

# ─── Cabecera ─────────────────────────────────────────────────────────────────
printf "\n${BOLD}╔══════════════════════════════════════════════════╗${NC}\n"
printf   "${BOLD}║  k3s Cleanup — Raspi 4B              %-11s║${NC}\n" "$(date '+%H:%M:%S')"
printf   "${BOLD}╚══════════════════════════════════════════════════╝${NC}\n"
$DRY_RUN && printf "  ${YELLOW}Modo dry-run — no se ejecuta nada${NC}\n"

# ─── Estado actual ────────────────────────────────────────────────────────────
hdr "Estado actual"

K3S_RUNNING=false
if systemctl is-active --quiet k3s 2>/dev/null; then
    K3S_RUNNING=true
    info "k3s.service: activo"
    if command -v k3s &>/dev/null; then
        info "Pods corriendo:"
        k3s kubectl get pods -A --no-headers 2>/dev/null | sed 's/^/    /' || true
    fi
else
    info "k3s.service: inactivo o no encontrado"
fi

MEM_BEFORE="$(awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)"
info "Memoria disponible ahora: ${MEM_BEFORE} MB"

# ─── Confirmación ─────────────────────────────────────────────────────────────
if ! $FORCE && ! $DRY_RUN; then
    printf "\n${YELLOW}${BOLD}⚠  ATENCIÓN — Esta operación:${NC}\n"
    printf "   • Eliminará k3s y todos sus datos del sistema\n"
    printf "   • Borrará /var/lib/rancher/k3s y /etc/rancher/k3s\n"
    printf "   • Eliminará containerd embebido de k3s (no afecta podman)\n"
    printf "   • Mosquitto y llama-server seguirán funcionando\n"
    printf "   • ai-analyzer se reimplementará con podman directo\n"
    printf "\n"
    printf "  Escribe ${BOLD}CLEAN${NC} para confirmar: "
    read -r CONFIRM
    [[ "$CONFIRM" == "CLEAN" ]] || { printf "Cancelado.\n"; exit 0; }
fi

# ─── PASO 1: Parar workloads k3s ordenadamente ───────────────────────────────
hdr "1. Parando workloads de k3s"

if $K3S_RUNNING && command -v kubectl &>/dev/null; then
    info "Escalando deployments a 0..."
    for deploy in $(k3s kubectl get deployments -A --no-headers 2>/dev/null | awk '{print $2}' || true); do
        ns="$(k3s kubectl get deployments -A --no-headers 2>/dev/null | grep "$deploy" | awk '{print $1}' | head -1)"
        run k3s kubectl scale deployment "$deploy" -n "${ns:-default}" --replicas=0 2>/dev/null || true
    done
    sleep 3

    info "Eliminando pods en ejecución..."
    run k3s kubectl delete pods --all -A --grace-period=5 2>/dev/null || true
    ok "Workloads detenidos"
else
    skip "kubectl — k3s no activo, omitiendo parada de pods"
fi

# ─── PASO 2: Parar servicio k3s ──────────────────────────────────────────────
hdr "2. Parando servicio k3s"

if systemctl list-unit-files k3s.service &>/dev/null 2>&1; then
    run systemctl stop k3s 2>/dev/null || true
    run systemctl disable k3s 2>/dev/null || true
    ok "k3s.service detenido y deshabilitado"
else
    skip "k3s.service"
fi

# ─── PASO 3: Ejecutar desinstalador oficial ───────────────────────────────────
hdr "3. Desinstalador oficial de k3s"

if [[ -x "/usr/local/bin/k3s-uninstall.sh" ]]; then
    info "Ejecutando /usr/local/bin/k3s-uninstall.sh ..."
    if ! $DRY_RUN; then
        /usr/local/bin/k3s-uninstall.sh 2>/dev/null || true
    else
        printf "  [dry-run] /usr/local/bin/k3s-uninstall.sh\n"
    fi
    ok "Desinstalador oficial ejecutado"
elif [[ -x "/usr/local/bin/k3s-agent-uninstall.sh" ]]; then
    run /usr/local/bin/k3s-agent-uninstall.sh 2>/dev/null || true
    ok "k3s-agent-uninstall.sh ejecutado"
else
    warn "Desinstalador oficial no encontrado — limpiando manualmente"
fi

# ─── PASO 4: Limpiar binarios y archivos de k3s ──────────────────────────────
hdr "4. Limpiando binarios y archivos"

declare -a K3S_BINARIES=(
    /usr/local/bin/k3s
    /usr/local/bin/kubectl
    /usr/local/bin/crictl
    /usr/local/bin/ctr
    /usr/local/bin/k3s-uninstall.sh
    /usr/local/bin/k3s-agent-uninstall.sh
)
for f in "${K3S_BINARIES[@]}"; do
    if [[ -f "$f" ]]; then
        run rm -f "$f"
        info "Eliminado: $f"
    fi
done

declare -a K3S_DIRS=(
    /var/lib/rancher/k3s
    /etc/rancher/k3s
    /run/k3s
    /var/lib/kubelet
    /etc/kubernetes
    /var/lib/etcd
    /var/log/k3s*
)
for d in "${K3S_DIRS[@]}"; do
    if [[ -e "$d" ]]; then
        run rm -rf "$d"
        info "Eliminado: $d"
    fi
done

declare -a K3S_CONFIGS=(
    /etc/systemd/system/k3s.service
    /etc/systemd/system/k3s.service.d
    /usr/local/lib/systemd/system/k3s.service
    /lib/systemd/system/k3s.service
)
for f in "${K3S_CONFIGS[@]}"; do
    if [[ -e "$f" ]]; then
        run rm -rf "$f"
        info "Eliminado: $f"
    fi
done

run systemctl daemon-reload 2>/dev/null || true
ok "Binarios y archivos de k3s eliminados"

# ─── PASO 5: Limpiar interfaces de red virtuales de k3s/flannel ──────────────
hdr "5. Limpiando interfaces de red virtuales"

for iface in flannel.1 cni0 kube-ipvs0 dummy0; do
    if ip link show "$iface" &>/dev/null 2>&1; then
        run ip link delete "$iface" 2>/dev/null || true
        info "Interfaz eliminada: $iface"
    fi
done

# Limpiar reglas iptables de k3s si quedaron
if command -v iptables &>/dev/null; then
    run iptables -F FORWARD 2>/dev/null || true
    run iptables -F CNI-FORWARD 2>/dev/null || true
    run iptables -t nat -F KUBE-SERVICES 2>/dev/null || true
    run iptables -t nat -F KUBE-POSTROUTING 2>/dev/null || true
    info "Reglas iptables de k3s limpiadas"
fi

# CNI config
if [[ -d "/etc/cni" ]]; then
    run rm -rf /etc/cni
    info "Eliminado: /etc/cni"
fi
if [[ -d "/opt/cni" ]]; then
    run rm -rf /opt/cni
    info "Eliminado: /opt/cni"
fi
if [[ -d "/var/lib/cni" ]]; then
    run rm -rf /var/lib/cni
    info "Eliminado: /var/lib/cni"
fi

ok "Interfaces de red y CNI limpiados"

# ─── PASO 6: Eliminar imagen ai-analyzer de podman (opcional) ────────────────
hdr "6. Imagen ai-analyzer en podman"

if $KEEP_IMAGE; then
    info "Conservando imagen podman (--keep-image)"
elif command -v podman &>/dev/null; then
    if podman image exists localhost/ai-analyzer:latest 2>/dev/null; then
        run podman rmi localhost/ai-analyzer:latest 2>/dev/null || true
        info "Imagen localhost/ai-analyzer:latest eliminada de podman"
        info "Se reconstruirá limpia en el siguiente deploy"
    else
        info "Imagen ai-analyzer no encontrada en podman (ya limpia)"
    fi
else
    skip "podman no encontrado"
fi

# ─── PASO 7: Verificar estado final ──────────────────────────────────────────
hdr "7. Estado final del sistema"

MEM_AFTER="$(awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)"
MEM_FREED=$((MEM_AFTER - MEM_BEFORE))

ok "Memoria disponible: ${MEM_AFTER} MB  (+${MEM_FREED} MB liberados)"

info "Verificando servicios que deben seguir activos:"
for svc in mosquitto; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        ok "  $svc: activo"
    else
        warn "  $svc: inactivo — puede necesitar reinicio"
    fi
done

if [[ -f "/var/run/llama-server.pid" ]] && kill -0 "$(cat /var/run/llama-server.pid 2>/dev/null)" 2>/dev/null; then
    ok "  llama-server: activo"
else
    warn "  llama-server: inactivo (normal si no se ha iniciado aún)"
fi

info "Verificando que k3s fue eliminado:"
if command -v k3s &>/dev/null; then
    warn "k3s aún presente en PATH — puede requerir reboot"
else
    ok "k3s eliminado del sistema"
fi

printf "\n${BOLD}${GREEN}✓ Limpieza de k3s completada.${NC}\n\n"
printf "  Siguiente paso — desplegar ai-analyzer con podman:\n"
printf "    bash scripts/setup-raspi4b-ai-analyzer.sh\n"
printf "\n"
printf "  Si mosquitto o llama-server están inactivos:\n"
printf "    systemctl restart mosquitto\n"
printf "    /etc/init.d/llama-server restart\n"
printf "\n"
