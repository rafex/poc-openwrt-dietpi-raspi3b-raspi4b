#!/bin/bash
# health-all.sh — Estado completo de toda la PoC (3 Raspis + router)
#
# Ejecuta los 3 scripts individuales de salud y genera una tabla resumen.
# Todos los checks se ejecutan en paralelo para reducir el tiempo total.
#
# Scripts individuales:
#   health-raspi4b.sh        → RafexPi4B  (192.168.1.167) — IA + k3s + LLM
#   health-raspi3b-sensor.sh → RafexPi3B-A (192.168.1.181) — Sensor de red
#   health-raspi3b-portal.sh → RafexPi3B-B (192.168.1.182) — Portal node
#
# También verifica el router OpenWrt (ping + SSH + nftables).
#
# Uso:
#   bash scripts/health-all.sh              # tabla resumen + detalle de fallos
#   bash scripts/health-all.sh --detail     # mostrar salida completa de cada script
#   bash scripts/health-all.sh --quiet      # solo tabla resumen, sin detalles
#   bash scripts/health-all.sh --watch N    # repetir cada N segundos (Ctrl+C para salir)
#
# Ejecutar desde: máquina admin (192.168.1.113)
# Requiere: bash 4+, ping, ssh, curl, nc

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

# ─── Colores ──────────────────────────────────────────────────────────────────
RED='\033[0;31m';   GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m';  CYAN='\033[0;36m'; MAGENTA='\033[0;35m'
NC='\033[0m';       BOLD='\033[1m';    DIM='\033[2m'

sep()  { printf "${DIM}%s${NC}\n" "──────────────────────────────────────────────────────"; }
hdr()  { printf "\n${BOLD}${CYAN}━━━ %s ━━━${NC}\n" "$*"; }
ok()   { printf "  ${GREEN}✓${NC} %s\n" "$*"; }
fail() { printf "  ${RED}✗${NC} %s\n" "$*"; }
warn() { printf "  ${YELLOW}!${NC} %s\n" "$*"; }
info() { printf "  ${BLUE}·${NC} %s\n" "$*"; }

# ─── Args ─────────────────────────────────────────────────────────────────────
DETAIL=false
QUIET=false
WATCH_INTERVAL=0

while [ $# -gt 0 ]; do
    case "$1" in
        --detail|-d)   DETAIL=true ;;
        --quiet|-q)    QUIET=true ;;
        --watch|-w)
            shift
            WATCH_INTERVAL="${1:-10}"
            ;;
        --help|-h)
            cat <<'EOF'
Uso: health-all.sh [opciones]

  --detail, -d      Mostrar salida completa de cada script individual
  --quiet, -q       Solo tabla resumen, sin sección de fallos
  --watch N, -w N   Refrescar cada N segundos (Ctrl+C para salir)
  --help, -h        Esta ayuda

Ejemplos:
  bash scripts/health-all.sh
  bash scripts/health-all.sh --detail
  bash scripts/health-all.sh --watch 30
  bash scripts/health-all.sh --quiet --watch 60
EOF
            exit 0 ;;
        *) echo "Argumento desconocido: $1  (usa --help)"; exit 1 ;;
    esac
    shift
done

# ─── Directorio temporal para resultados paralelos ────────────────────────────
TMPDIR_HEALTH=$(mktemp -d)
trap 'rm -rf "$TMPDIR_HEALTH"' EXIT

SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -o BatchMode=yes -o ConnectTimeout=5 -o LogLevel=ERROR"

# ─── Función principal (una iteración) ────────────────────────────────────────
run_once() {
    local T_START; T_START=$(date +%s)

    if ! $QUIET; then
        clear 2>/dev/null || printf '\033[H\033[2J'
    fi

    printf "\n${BOLD}╔══════════════════════════════════════════════════════════╗${NC}\n"
    printf   "${BOLD}║     PoC — La IA no es solo de las Big Tech              ║${NC}\n"
    printf   "${BOLD}║     Estado general de infraestructura                   ║${NC}\n"
    printf   "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}\n"
    printf   "  %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
    [ "$WATCH_INTERVAL" -gt 0 ] && printf "  ${DIM}Refrescando cada ${WATCH_INTERVAL}s — Ctrl+C para salir${NC}\n"
    printf "\n"

    # ── Ejecutar los 3 scripts en paralelo ────────────────────────────────────
    info "Ejecutando checks en paralelo..."

    bash "$SCRIPT_DIR/health-raspi4b.sh"        --summary \
        > "$TMPDIR_HEALTH/raspi4b.out" 2>&1;        echo $? > "$TMPDIR_HEALTH/raspi4b.rc" &
    PID_4B=$!

    bash "$SCRIPT_DIR/health-raspi3b-sensor.sh" --summary \
        > "$TMPDIR_HEALTH/raspi3b_sensor.out" 2>&1; echo $? > "$TMPDIR_HEALTH/raspi3b_sensor.rc" &
    PID_3S=$!

    bash "$SCRIPT_DIR/health-raspi3b-portal.sh" --summary \
        > "$TMPDIR_HEALTH/raspi3b_portal.out" 2>&1; echo $? > "$TMPDIR_HEALTH/raspi3b_portal.rc" &
    PID_3P=$!

    # ── Check del router en paralelo (simple ping + SSH + nftables) ───────────
    {
        ROUTER_PASS=0; ROUTER_WARN=0; ROUTER_FAIL=0
        ROUTER_MSGS=""

        if ping -c1 -W2 "$ROUTER_IP" &>/dev/null; then
            ROUTER_PASS=$((ROUTER_PASS+1))
            ROUTER_MSGS="${ROUTER_MSGS}ok Ping $ROUTER_IP\n"
        else
            ROUTER_FAIL=$((ROUTER_FAIL+1))
            ROUTER_MSGS="${ROUTER_MSGS}fail Ping $ROUTER_IP\n"
        fi

        if ssh $SSH_OPTS "root@$ROUTER_IP" 'echo ok' &>/dev/null; then
            ROUTER_PASS=$((ROUTER_PASS+1))
            ROUTER_MSGS="${ROUTER_MSGS}ok SSH root@$ROUTER_IP\n"
        else
            ROUTER_FAIL=$((ROUTER_FAIL+1))
            ROUTER_MSGS="${ROUTER_MSGS}fail SSH root@$ROUTER_IP\n"
        fi

        # nftables captive portal
        if ssh $SSH_OPTS "root@$ROUTER_IP" \
            "nft list table ip captive >/dev/null 2>&1 && echo ok || echo fail" \
            2>/dev/null | grep -q "^ok"; then
            ROUTER_PASS=$((ROUTER_PASS+1))
            ROUTER_MSGS="${ROUTER_MSGS}ok nftables tabla 'ip captive'\n"
        else
            ROUTER_WARN=$((ROUTER_WARN+1))
            ROUTER_MSGS="${ROUTER_MSGS}warn nftables tabla 'ip captive' no encontrada\n"
        fi

        # dnsmasq
        if ssh $SSH_OPTS "root@$ROUTER_IP" \
            "ps | grep -q '[d]nsmasq' && echo ok || echo fail" \
            2>/dev/null | grep -q "^ok"; then
            ROUTER_PASS=$((ROUTER_PASS+1))
            ROUTER_MSGS="${ROUTER_MSGS}ok dnsmasq corriendo\n"
        else
            ROUTER_FAIL=$((ROUTER_FAIL+1))
            ROUTER_MSGS="${ROUTER_MSGS}fail dnsmasq NO corriendo\n"
        fi

        if [ "$ROUTER_FAIL" -eq 0 ] && [ "$ROUTER_WARN" -eq 0 ]; then
            STATUS="OK"
        elif [ "$ROUTER_FAIL" -eq 0 ]; then
            STATUS="ADVERTENCIAS"
        else
            STATUS="FALLOS"
        fi

        printf "%b" "$ROUTER_MSGS" > "$TMPDIR_HEALTH/router.msgs"
        printf "RESUMEN_SALUD router PASS=%d WARN=%d FAIL=%d STATUS=%s\n" \
            "$ROUTER_PASS" "$ROUTER_WARN" "$ROUTER_FAIL" "$STATUS" \
            > "$TMPDIR_HEALTH/router.out"
        echo 0 > "$TMPDIR_HEALTH/router.rc"
    } &
    PID_RT=$!

    # Esperar todos
    wait $PID_4B $PID_3S $PID_3P $PID_RT 2>/dev/null || true

    # ── Parsear resultados ─────────────────────────────────────────────────────
    parse_result() {
        local file="$1"
        local line; line=$(grep "^RESUMEN_SALUD" "$file" 2>/dev/null | tail -1 || echo "")
        if [ -z "$line" ]; then
            echo "PASS=0 WARN=0 FAIL=1 STATUS=ERROR"
            return
        fi
        echo "$line" | sed 's/RESUMEN_SALUD [^ ]* //'
    }

    eval "$(parse_result "$TMPDIR_HEALTH/raspi4b.out"        | sed 's/^/R4B_/')"
    eval "$(parse_result "$TMPDIR_HEALTH/raspi3b_sensor.out" | sed 's/^/R3S_/')"
    eval "$(parse_result "$TMPDIR_HEALTH/raspi3b_portal.out" | sed 's/^/R3P_/')"
    eval "$(parse_result "$TMPDIR_HEALTH/router.out"         | sed 's/^/RT_/')"

    # ── Tabla resumen ─────────────────────────────────────────────────────────
    status_badge() {
        local s="$1"
        case "$s" in
            OK)            printf "${GREEN}${BOLD}  ✓ OK          ${NC}" ;;
            ADVERTENCIAS)  printf "${YELLOW}${BOLD}  ! ADVERTENCIAS${NC}" ;;
            FALLOS|CRITICO|ERROR) printf "${RED}${BOLD}  ✗ FALLOS      ${NC}" ;;
            *)             printf "${BLUE}  ? DESCONOCIDO${NC}" ;;
        esac
    }

    printf "\n"
    sep
    printf "${BOLD}  %-28s  %-16s  %5s  %5s  %5s${NC}\n" \
        "Dispositivo" "Estado" "OK" "WARN" "FAIL"
    sep

    printf "  %-28s  " "RafexPi4B (IA + k3s + LLM)"
    status_badge "${R4B_STATUS:-ERROR}"
    printf "  %5s  %5s  %5s\n" "${R4B_PASS:-?}" "${R4B_WARN:-?}" "${R4B_FAIL:-?}"

    printf "  %-28s  " "RafexPi3B-A (Sensor)"
    status_badge "${R3S_STATUS:-ERROR}"
    printf "  %5s  %5s  %5s\n" "${R3S_PASS:-?}" "${R3S_WARN:-?}" "${R3S_FAIL:-?}"

    printf "  %-28s  " "RafexPi3B-B (Portal node)"
    status_badge "${R3P_STATUS:-ERROR}"
    printf "  %5s  %5s  %5s\n" "${R3P_PASS:-?}" "${R3P_WARN:-?}" "${R3P_FAIL:-?}"

    printf "  %-28s  " "Router OpenWrt (192.168.1.1)"
    status_badge "${RT_STATUS:-ERROR}"
    printf "  %5s  %5s  %5s\n" "${RT_PASS:-?}" "${RT_WARN:-?}" "${RT_FAIL:-?}"

    sep

    # Totales
    TOTAL_PASS=$(( ${R4B_PASS:-0} + ${R3S_PASS:-0} + ${R3P_PASS:-0} + ${RT_PASS:-0} ))
    TOTAL_WARN=$(( ${R4B_WARN:-0} + ${R3S_WARN:-0} + ${R3P_WARN:-0} + ${RT_WARN:-0} ))
    TOTAL_FAIL=$(( ${R4B_FAIL:-0} + ${R3S_FAIL:-0} + ${R3P_FAIL:-0} + ${RT_FAIL:-0} ))

    printf "  ${BOLD}%-28s${NC}                    %5d  %5d  %5d\n" \
        "TOTAL" "$TOTAL_PASS" "$TOTAL_WARN" "$TOTAL_FAIL"
    sep

    # Estado global
    if [ "$TOTAL_FAIL" -eq 0 ] && [ "$TOTAL_WARN" -eq 0 ]; then
        GLOBAL_STATUS="${GREEN}${BOLD}SISTEMA COMPLETAMENTE OPERATIVO${NC}"
    elif [ "$TOTAL_FAIL" -eq 0 ]; then
        GLOBAL_STATUS="${YELLOW}${BOLD}SISTEMA OPERATIVO CON ADVERTENCIAS${NC}"
    else
        GLOBAL_STATUS="${RED}${BOLD}SISTEMA CON FALLOS${NC}"
    fi
    printf "\n  Estado global: %b\n" "$GLOBAL_STATUS"

    # ── Router: detalle de checks ──────────────────────────────────────────────
    if ! $QUIET; then
        hdr "Router OpenWrt (${ROUTER_IP})"
        if [ -f "$TMPDIR_HEALTH/router.msgs" ]; then
            while IFS= read -r line; do
                case "$line" in
                    "ok "*)   ok  "${line#ok }" ;;
                    "warn "*) warn "${line#warn }" ;;
                    "fail "*) fail "${line#fail }" ;;
                    *)        info "$line" ;;
                esac
            done < "$TMPDIR_HEALTH/router.msgs"
        fi
    fi

    # ── Detalle de fallos y advertencias ──────────────────────────────────────
    if ! $QUIET && [ "$TOTAL_FAIL" -gt 0 ]; then
        hdr "Detalle de fallos"
        for f in raspi4b raspi3b_sensor raspi3b_portal; do
            FILE="$TMPDIR_HEALTH/${f}.out"
            [ -f "$FILE" ] || continue
            if grep -q "✗" "$FILE" 2>/dev/null; then
                LABEL=$(grep "^RESUMEN_SALUD" "$FILE" | awk '{print $2}' || echo "$f")
                printf "\n  ${BOLD}[$LABEL]${NC}\n"
                grep "✗\|CRÍTICO\|DETENIDO" "$FILE" | sed 's/^/  /' | head -10
            fi
        done
        printf "\n"
    fi

    # ── Salida completa (--detail) ─────────────────────────────────────────────
    if $DETAIL; then
        for f in raspi4b raspi3b_sensor raspi3b_portal; do
            DEVICE_LABEL="$f"
            case "$f" in
                raspi4b)        DEVICE_LABEL="RafexPi4B" ;;
                raspi3b_sensor) DEVICE_LABEL="RafexPi3B-A (Sensor)" ;;
                raspi3b_portal) DEVICE_LABEL="RafexPi3B-B (Portal)" ;;
            esac
            hdr "Detalle completo — $DEVICE_LABEL"
            cat "$TMPDIR_HEALTH/${f}.out" 2>/dev/null || echo "  (sin salida)"
        done
    fi

    # ── URLs útiles ────────────────────────────────────────────────────────────
    if ! $QUIET; then
        hdr "URLs del sistema"
        printf "  %-30s  %s\n" "Dashboard IA"     "http://${RASPI4B_IP:-192.168.1.167}/dashboard"
        printf "  %-30s  %s\n" "Terminal en vivo" "http://${RASPI4B_IP:-192.168.1.167}/terminal"
        printf "  %-30s  %s\n" "Chat SOC"         "http://${RASPI4B_IP:-192.168.1.167}/chat"
        printf "  %-30s  %s\n" "API historial"    "http://${RASPI4B_IP:-192.168.1.167}/api/history"
        printf "  %-30s  %s\n" "Health analizador" "http://${RASPI4B_IP:-192.168.1.167}/health"
        printf "  %-30s  %s\n" "llama.cpp server" "http://${RASPI4B_IP:-192.168.1.167}:8081/health"
        printf "  %-30s  %s\n" "Portal cautivo"   "http://${PORTAL_IP:-192.168.1.167}/portal"
        printf "  %-30s  %s\n" "Portal node"      "http://${PORTAL_NODE_IP:-192.168.1.182}/portal"
    fi

    # ── Tiempo total ──────────────────────────────────────────────────────────
    local T_END; T_END=$(date +%s)
    printf "\n  ${DIM}Checks completados en $((T_END - T_START))s${NC}\n\n"

    return "$TOTAL_FAIL"
}

# ─── Modo watch o ejecución única ─────────────────────────────────────────────
if [ "$WATCH_INTERVAL" -gt 0 ]; then
    while true; do
        run_once || true
        printf "  ${DIM}Próxima actualización en ${WATCH_INTERVAL}s...${NC}\n"
        sleep "$WATCH_INTERVAL"
    done
else
    run_once
    EXIT_CODE=$?
    exit $EXIT_CODE
fi
