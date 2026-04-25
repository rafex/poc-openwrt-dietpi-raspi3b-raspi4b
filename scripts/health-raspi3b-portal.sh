#!/bin/bash
# health-raspi3b-portal.sh — Estado completo de RafexPi3B-B (192.168.1.182)
#
# Servicios verificados:
#   • Red                   — ping desde la máquina admin
#   • SSH                   — acceso con llave /opt/keys/captive-portal
#   • captive-portal-node   — contenedor podman (frontend nginx)
#   • captive-portal-node-backend — contenedor podman (Python backend)
#   • HTTP endpoints        — /portal, /accepted, /health desde admin
#   • Topología             — si está en modo split_portal o legacy
#   • Conectividad al AI    — alcanza al analizador en Pi4B
#
# Uso:
#   bash scripts/health-raspi3b-portal.sh              # reporte completo
#   bash scripts/health-raspi3b-portal.sh --summary    # solo resumen final
#
# Nota: Este nodo solo es activo en topología split_portal.
#       En topología legacy, el portal corre en la Pi4B (k3s).
#       El script reporta WARNING si el nodo está en modo legacy y no tiene
#       contenedores activos — no es un fallo crítico.
#
# Ejecutar desde: máquina admin (192.168.1.113)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

# ─── Colores ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

hdr()  { printf "\n${BOLD}${CYAN}━━━ %s ━━━${NC}\n" "$*"; }
ok()   { printf "  ${GREEN}✓${NC} %s\n" "$*";  PASS=$((PASS+1)); }
fail() { printf "  ${RED}✗${NC} %s\n" "$*";    FAIL=$((FAIL+1)); }
warn() { printf "  ${YELLOW}!${NC} %s\n" "$*"; WARN=$((WARN+1)); }
info() { printf "  ${BLUE}·${NC} %s\n" "$*"; }

PASS=0; FAIL=0; WARN=0
SUMMARY_ONLY=false

for arg in "$@"; do
    case "$arg" in
        --summary|-s) SUMMARY_ONLY=true ;;
        --help|-h)
            echo "Uso: $0 [--summary]"
            echo "  --summary : mostrar solo el resumen final, sin detalles"
            exit 0 ;;
    esac
done

TARGET_IP="${PORTAL_NODE_IP:-192.168.1.182}"
AI_IP="${RASPI4B_IP:-192.168.1.167}"
# Sin -i: la máquina admin usa sus propias llaves SSH (~/.ssh/) para las Raspis.
# El SSH_KEY de common.sh es solo para el router OpenWrt (Dropbear).
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -o BatchMode=yes -o ConnectTimeout=5 -o LogLevel=ERROR"

pi3b_portal_ssh() { ssh $SSH_OPTS "root@$TARGET_IP" "$@" 2>/dev/null; }

CONTAINER_PORTAL="captive-portal-node"
CONTAINER_BACKEND="captive-portal-node-backend"

if ! $SUMMARY_ONLY; then
    printf "\n${BOLD}╔══════════════════════════════════════════════════╗${NC}\n"
    printf   "${BOLD}║  RafexPi3B-B — Nodo Portal           %-11s║${NC}\n" "$(date '+%H:%M:%S')"
    printf   "${BOLD}╚══════════════════════════════════════════════════╝${NC}\n"
    printf "  IP: %s\n" "$TARGET_IP"
fi

# ─── 1. Ping ──────────────────────────────────────────────────────────────────
$SUMMARY_ONLY || hdr "1. Red"
if ping -c1 -W2 "$TARGET_IP" &>/dev/null; then
    ok "Ping a $TARGET_IP — responde"
else
    fail "Ping a $TARGET_IP — sin respuesta"
    printf "\n${RED}RESULTADO${NC}: CRÍTICO — no se puede llegar a $TARGET_IP\n"
    printf "RESUMEN_SALUD raspi3b-portal PASS=%d WARN=%d FAIL=%d STATUS=CRITICO\n" \
        "$PASS" "$WARN" "$FAIL"
    exit 2
fi

# ─── 2. SSH ───────────────────────────────────────────────────────────────────
$SUMMARY_ONLY || hdr "2. SSH"
if pi3b_portal_ssh 'echo ok' &>/dev/null; then
    ok "SSH root@$TARGET_IP — acceso OK"
else
    fail "SSH root@$TARGET_IP — sin acceso (verifica ~/.ssh/ o ~/.ssh/config)"
    printf "\n${RED}RESULTADO${NC}: CRÍTICO — SSH no disponible en $TARGET_IP\n"
    printf "RESUMEN_SALUD raspi3b-portal PASS=%d WARN=%d FAIL=%d STATUS=CRITICO\n" \
        "$PASS" "$WARN" "$FAIL"
    exit 2
fi

# Recoger información remota en un solo SSH
REMOTE_INFO=$(pi3b_portal_ssh '
    echo "UPTIME=$(uptime -p 2>/dev/null || uptime)"
    echo "LOADAVG=$(cat /proc/loadavg | cut -d" " -f1-3)"
    echo "MEM_FREE=$(awk "/MemFree/{print \$2}" /proc/meminfo)kB"
    echo "MEM_TOTAL=$(awk "/MemTotal/{print \$2}" /proc/meminfo)kB"
    echo "DISK_USE=$(df -h / | awk "NR==2{print \$5}")"

    # Topología activa
    if [ -f /etc/demo-openwrt/topology.env ]; then
        TOPO=$(grep "^TOPOLOGY=" /etc/demo-openwrt/topology.env | cut -d= -f2 | tr -d '"'"'"' ')
        echo "TOPOLOGY=${TOPO:-legacy}"
    else
        echo "TOPOLOGY=legacy"
    fi

    # Podman disponible
    if command -v podman >/dev/null 2>&1; then
        echo "PODMAN_OK=yes"
        echo "PODMAN_VER=$(podman --version 2>/dev/null | cut -d" " -f3)"
        # Contenedores corriendo
        RUNNING=$(podman ps --format "{{.Names}}" 2>/dev/null)
        echo "CONTAINERS_RUNNING<<EOF"
        echo "$RUNNING"
        echo "EOF"
        # Estado específico de cada contenedor
        for c in captive-portal-node captive-portal-node-backend; do
            if echo "$RUNNING" | grep -qx "$c"; then
                echo "CONT_${c//-/_}=running"
            else
                # Verificar si existe pero detenido
                if podman ps -a --format "{{.Names}}" 2>/dev/null | grep -qx "$c"; then
                    ST=$(podman inspect "$c" --format "{{.State.Status}}" 2>/dev/null)
                    echo "CONT_${c//-/_}=$ST"
                else
                    echo "CONT_${c//-/_}=not_found"
                fi
            fi
        done
    else
        echo "PODMAN_OK=no"
        echo "CONT_captive_portal_node=not_found"
        echo "CONT_captive_portal_node_backend=not_found"
    fi

    # Conectividad al AI
    if curl -sf --connect-timeout 3 --max-time 5 "http://'"$AI_IP"'/health" >/dev/null 2>&1; then
        echo "AI_REACH=ok"
    else
        echo "AI_REACH=fail"
    fi
    # Energía — rayo amarillo de subvoltaje (vcgencmd get_throttled)
    _VC=""
    for _p in vcgencmd /usr/bin/vcgencmd /opt/vc/bin/vcgencmd; do
        command -v "$_p" >/dev/null 2>&1 && _VC="$_p" && break
        [ -x "$_p" ] && _VC="$_p" && break
    done
    if [ -n "$_VC" ]; then
        echo "VCGENCMD_OK=yes"
        echo "THROTTLE_RAW=$($_VC get_throttled 2>/dev/null | cut -d= -f2)"
        echo "CPU_TEMP=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo unknown)"
    else
        echo "VCGENCMD_OK=no"
        echo "THROTTLE_RAW=unknown"
        echo "CPU_TEMP=unknown"
    fi
' 2>/dev/null || echo "REMOTE_INFO_FAILED=1")

eval "$REMOTE_INFO" 2>/dev/null || true

# ─── 3. Sistema ───────────────────────────────────────────────────────────────
if ! $SUMMARY_ONLY; then
    hdr "3. Sistema"
    info "Uptime     : ${UPTIME:-desconocido}"
    info "Load       : ${LOADAVG:-?}"
    info "Disco      : ${DISK_USE:-?}"
    info "Topología  : ${TOPOLOGY:-legacy}"
    if [ -n "${MEM_TOTAL:-}" ] && [ -n "${MEM_FREE:-}" ] && [ "$MEM_TOTAL" -gt 0 ]; then
        MEM_PCT=$(( (MEM_TOTAL - MEM_FREE) * 100 / MEM_TOTAL ))
        info "RAM        : ${MEM_PCT}% usada (${MEM_FREE}kB libre de ${MEM_TOTAL}kB)"
    fi
fi

# ─── Energía y temperatura ────────────────────────────────────────────────────
$SUMMARY_ONLY || hdr "Energía y temperatura"
if [ "${VCGENCMD_OK:-no}" = "yes" ] && [ "${THROTTLE_RAW:-unknown}" != "unknown" ]; then
    _T="${THROTTLE_RAW:-0x0}"
    _T_DEC=$(( _T )) 2>/dev/null || _T_DEC=0
    if [ "$_T_DEC" -eq 0 ]; then
        ok "Energía: OK — sin problemas [raw:${_T}]"
    elif [ "$(( _T_DEC & 0xF ))" -ne 0 ]; then
        _issues=""
        [ "$(( _T_DEC & 0x1 ))" -ne 0 ] && _issues="${_issues}SUBVOLTAJE "
        [ "$(( _T_DEC & 0x2 ))" -ne 0 ] && _issues="${_issues}FRECUENCIA-LIMITADA "
        [ "$(( _T_DEC & 0x4 ))" -ne 0 ] && _issues="${_issues}THROTTLED "
        [ "$(( _T_DEC & 0x8 ))" -ne 0 ] && _issues="${_issues}TEMP-SOFT-LIMIT "
        fail "⚡ RAYO ACTIVO: ${_issues}[raw:${_T}] — cambia la fuente de alimentación"
    else
        _issues=""
        [ "$(( _T_DEC & 0x10000 ))" -ne 0 ] && _issues="${_issues}subvoltaje "
        [ "$(( _T_DEC & 0x20000 ))" -ne 0 ] && _issues="${_issues}frecuencia-limitada "
        [ "$(( _T_DEC & 0x40000 ))" -ne 0 ] && _issues="${_issues}throttled "
        [ "$(( _T_DEC & 0x80000 ))" -ne 0 ] && _issues="${_issues}temp-soft-limit "
        warn "⚡ Rayo pasado (desde último reboot): ${_issues}[raw:${_T}]"
        ! $SUMMARY_ONLY && info "Para limpiar el historial de throttling: reinicia la Pi"
    fi
    if ! $SUMMARY_ONLY && [ "${CPU_TEMP:-unknown}" != "unknown" ] && \
       [ "$CPU_TEMP" -gt 1000 ] 2>/dev/null; then
        info "Temperatura CPU: $(( CPU_TEMP / 1000 )).$(( (CPU_TEMP % 1000) / 100 ))°C"
    fi
elif [ "${VCGENCMD_OK:-}" = "no" ]; then
    warn "vcgencmd no disponible — energía sin verificar (apt install libraspberrypi-bin)"
fi

# Nota de topología
if [ "${TOPOLOGY:-legacy}" = "legacy" ]; then
    ! $SUMMARY_ONLY && warn "Topología 'legacy': el portal principal corre en Pi4B (k3s), no aquí"
fi

# ─── 4. Podman ────────────────────────────────────────────────────────────────
$SUMMARY_ONLY || hdr "4. Podman"
if [ "${PODMAN_OK:-no}" = "yes" ]; then
    ok "Podman disponible (v${PODMAN_VER:-?})"
else
    fail "Podman NO disponible — sin runtime de contenedores"
fi

# ─── 5. Contenedor frontend (nginx) ───────────────────────────────────────────
$SUMMARY_ONLY || hdr "5. Contenedor $CONTAINER_PORTAL (frontend nginx)"
CONT_PORTAL_STATUS="${CONT_captive_portal_node:-not_found}"
case "$CONT_PORTAL_STATUS" in
    running)  ok "$CONTAINER_PORTAL — corriendo" ;;
    not_found)
        if [ "${TOPOLOGY:-legacy}" = "legacy" ]; then
            warn "$CONTAINER_PORTAL — no existe (topología legacy, esperado)"
        else
            fail "$CONTAINER_PORTAL — no encontrado (topología split_portal activa)"
        fi ;;
    exited|stopped)
        fail "$CONTAINER_PORTAL — detenido (estado: $CONT_PORTAL_STATUS)"
        warn "Reinicia con: ssh root@$TARGET_IP 'podman start $CONTAINER_PORTAL'" ;;
    *)  warn "$CONTAINER_PORTAL — estado: $CONT_PORTAL_STATUS" ;;
esac

# ─── 6. Contenedor backend (Python) ───────────────────────────────────────────
$SUMMARY_ONLY || hdr "6. Contenedor $CONTAINER_BACKEND (Python backend)"
CONT_BACKEND_STATUS="${CONT_captive_portal_node_backend:-not_found}"
case "$CONT_BACKEND_STATUS" in
    running)  ok "$CONTAINER_BACKEND — corriendo" ;;
    not_found)
        if [ "${TOPOLOGY:-legacy}" = "legacy" ]; then
            warn "$CONTAINER_BACKEND — no existe (topología legacy, esperado)"
        else
            fail "$CONTAINER_BACKEND — no encontrado (topología split_portal activa)"
        fi ;;
    exited|stopped)
        fail "$CONTAINER_BACKEND — detenido (estado: $CONT_BACKEND_STATUS)"
        warn "Reinicia con: ssh root@$TARGET_IP 'podman start $CONTAINER_BACKEND'" ;;
    *)  warn "$CONTAINER_BACKEND — estado: $CONT_BACKEND_STATUS" ;;
esac

# ─── 7. HTTP endpoints (desde admin, solo si contenedores corren) ─────────────
if [ "$CONT_PORTAL_STATUS" = "running" ] || [ "$CONT_BACKEND_STATUS" = "running" ]; then
    $SUMMARY_ONLY || hdr "7. HTTP endpoints (desde admin)"
    for ep in / /portal /accepted /health /api/stats; do
        CODE=$(curl -sf -o /dev/null -w "%{http_code}" --connect-timeout 3 --max-time 5 \
            "http://$TARGET_IP$ep" 2>/dev/null || echo "000")
        case "$CODE" in
            200|204)         ok  "GET http://$TARGET_IP$ep → $CODE" ;;
            301|302|307|308) ok  "GET http://$TARGET_IP$ep → $CODE (redirect)" ;;
            000)             fail "GET http://$TARGET_IP$ep → sin respuesta" ;;
            *)               warn "GET http://$TARGET_IP$ep → $CODE" ;;
        esac
    done
else
    $SUMMARY_ONLY || warn "Saltando check HTTP — no hay contenedores activos"
fi

# ─── 8. Conectividad al analizador IA ─────────────────────────────────────────
$SUMMARY_ONLY || hdr "8. Conectividad al analizador IA"
if [ "${AI_REACH:-fail}" = "ok" ]; then
    ok "Analizador IA $AI_IP/health — accesible desde portal node"
else
    warn "Analizador IA $AI_IP/health — NO accesible desde portal node"
    info "El backend del portal necesita alcanzar el AI para consultas de contexto"
fi

# ─── Resumen ──────────────────────────────────────────────────────────────────
printf "\n"
if [ "$FAIL" -eq 0 ] && [ "$WARN" -eq 0 ]; then
    STATUS_STR="OK"; STATUS_COLOR="$GREEN"
elif [ "$FAIL" -eq 0 ]; then
    STATUS_STR="ADVERTENCIAS"; STATUS_COLOR="$YELLOW"
else
    STATUS_STR="FALLOS"; STATUS_COLOR="$RED"
fi

printf "${BOLD}━━━ RESUMEN RafexPi3B-B (Portal node) ━━━${NC}\n"
printf "  ${GREEN}✓ OK:${NC}          %d\n" "$PASS"
printf "  ${YELLOW}! Advertencias:${NC} %d\n" "$WARN"
printf "  ${RED}✗ Fallos:${NC}       %d\n" "$FAIL"
printf "  Estado:         ${STATUS_COLOR}${BOLD}%s${NC}\n" "$STATUS_STR"
printf "\n"

printf "RESUMEN_SALUD raspi3b-portal PASS=%d WARN=%d FAIL=%d STATUS=%s\n" \
    "$PASS" "$WARN" "$FAIL" "$STATUS_STR"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
