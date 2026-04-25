#!/bin/bash
# health-raspi3b-sensor.sh — Estado completo de RafexPi3B-A (192.168.1.181)
#
# Servicios verificados:
#   • Red           — ping desde la máquina admin
#   • SSH           — acceso con llave /opt/keys/captive-portal
#   • network-sensor — servicio init.d del sensor de tráfico
#   • tshark        — proceso de captura en modo promiscuo
#   • paho-mqtt     — publicación al broker (último mensaje MQTT)
#   • Python 3      — versión instalada
#   • Interfaz eth0 — presencia y modo promiscuo
#   • Conectividad  — alcanza al broker MQTT en Pi4B
#
# Uso:
#   bash scripts/health-raspi3b-sensor.sh              # reporte completo
#   bash scripts/health-raspi3b-sensor.sh --summary    # solo resumen final
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

TARGET_IP="${RASPI3B_IP:-192.168.1.181}"
BROKER_IP="${RASPI4B_IP:-192.168.1.167}"
MQTT_PORT=1883
# Sin -i: la máquina admin usa sus propias llaves SSH (~/.ssh/) para las Raspis.
# El SSH_KEY de common.sh es solo para el router OpenWrt (Dropbear).
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -o BatchMode=yes -o ConnectTimeout=5 -o LogLevel=ERROR"

pi3b_ssh() { ssh $SSH_OPTS "root@$TARGET_IP" "$@" 2>/dev/null; }

if ! $SUMMARY_ONLY; then
    printf "\n${BOLD}╔══════════════════════════════════════════════════╗${NC}\n"
    printf   "${BOLD}║  RafexPi3B-A — Sensor de Red        %-11s║${NC}\n" "$(date '+%H:%M:%S')"
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
    printf "RESUMEN_SALUD raspi3b-sensor PASS=%d WARN=%d FAIL=%d STATUS=CRITICO\n" \
        "$PASS" "$WARN" "$FAIL"
    exit 2
fi

# ─── 2. SSH ───────────────────────────────────────────────────────────────────
$SUMMARY_ONLY || hdr "2. SSH"
if pi3b_ssh 'echo ok' &>/dev/null; then
    ok "SSH root@$TARGET_IP — acceso OK"
else
    fail "SSH root@$TARGET_IP — sin acceso (verifica ~/.ssh/ o ~/.ssh/config)"
    printf "\n${RED}RESULTADO${NC}: CRÍTICO — SSH no disponible en $TARGET_IP\n"
    printf "RESUMEN_SALUD raspi3b-sensor PASS=%d WARN=%d FAIL=%d STATUS=CRITICO\n" \
        "$PASS" "$WARN" "$FAIL"
    exit 2
fi

# Recoger información del sistema remoto de una sola vez (reduce round-trips SSH)
REMOTE_INFO=$(pi3b_ssh '
    echo "UPTIME=$(uptime -p 2>/dev/null || uptime)"
    echo "LOADAVG=$(cat /proc/loadavg | cut -d" " -f1-3)"
    echo "MEM_FREE=$(awk "/MemFree/{print \$2}" /proc/meminfo)kB"
    echo "MEM_TOTAL=$(awk "/MemTotal/{print \$2}" /proc/meminfo)kB"
    echo "DISK_USE=$(df -h / | awk "NR==2{print \$5}")"
    echo "PY_VER=$(python3 --version 2>&1 | cut -d" " -f2)"

    # network-sensor init.d
    if [ -f /var/run/network-sensor.pid ]; then
        PID=$(cat /var/run/network-sensor.pid)
        if kill -0 "$PID" 2>/dev/null; then
            echo "SENSOR_STATUS=running"
            echo "SENSOR_PID=$PID"
        else
            echo "SENSOR_STATUS=stale_pid"
            echo "SENSOR_PID=$PID"
        fi
    else
        # Intentar via init.d
        if /etc/init.d/network-sensor status 2>/dev/null | grep -qi "running"; then
            echo "SENSOR_STATUS=running"
            echo "SENSOR_PID=unknown"
        else
            echo "SENSOR_STATUS=stopped"
            echo "SENSOR_PID="
        fi
    fi

    # tshark (hijo de network-sensor)
    if pgrep -x tshark >/dev/null 2>&1; then
        echo "TSHARK_STATUS=running"
        echo "TSHARK_PID=$(pgrep -x tshark | head -1)"
    else
        echo "TSHARK_STATUS=stopped"
        echo "TSHARK_PID="
    fi

    # Interfaz en modo promiscuo
    PROMISC=$(ip link show eth0 2>/dev/null | grep -c PROMISC || echo 0)
    echo "ETH0_PROMISC=$PROMISC"
    echo "ETH0_STATE=$(ip link show eth0 2>/dev/null | awk "/state/{print \$9}" | head -1)"

    # Último log del sensor
    if [ -f /var/log/network-sensor.log ]; then
        echo "LOG_LINES=$(wc -l < /var/log/network-sensor.log)"
        echo "LOG_LAST=$(tail -1 /var/log/network-sensor.log 2>/dev/null | cut -c1-80)"
    else
        echo "LOG_LINES=0"
        echo "LOG_LAST=(sin log)"
    fi

    # Conectividad al broker MQTT
    if nc -z -w3 '"$BROKER_IP"' '"$MQTT_PORT"' 2>/dev/null; then
        echo "MQTT_REACH=ok"
    else
        echo "MQTT_REACH=fail"
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
    info "Uptime  : ${UPTIME:-desconocido}"
    info "Load    : ${LOADAVG:-?}"
    info "Disco   : ${DISK_USE:-?}"
    info "Python  : ${PY_VER:-no encontrado}"
    if [ -n "${MEM_TOTAL:-}" ] && [ -n "${MEM_FREE:-}" ] && [ "$MEM_TOTAL" -gt 0 ]; then
        MEM_PCT=$(( (MEM_TOTAL - MEM_FREE) * 100 / MEM_TOTAL ))
        info "RAM     : ${MEM_PCT}% usada (${MEM_FREE}kB libre de ${MEM_TOTAL}kB)"
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

# ─── 4. network-sensor ────────────────────────────────────────────────────────
$SUMMARY_ONLY || hdr "4. network-sensor (init.d)"
case "${SENSOR_STATUS:-unknown}" in
    running)
        ok "network-sensor — corriendo (PID ${SENSOR_PID:-?})"
        ;;
    stale_pid)
        fail "network-sensor — PID obsoleto (${SENSOR_PID:-?} no existe)"
        warn "Reinicia con: ssh root@$TARGET_IP '/etc/init.d/network-sensor restart'"
        ;;
    stopped)
        fail "network-sensor — DETENIDO"
        warn "Inicia con:   ssh root@$TARGET_IP '/etc/init.d/network-sensor start'"
        ;;
    *)
        warn "network-sensor — estado desconocido"
        ;;
esac

# ─── 5. tshark ────────────────────────────────────────────────────────────────
$SUMMARY_ONLY || hdr "5. tshark (captura en modo promiscuo)"
if [ "${TSHARK_STATUS:-stopped}" = "running" ]; then
    ok "tshark — proceso corriendo (PID ${TSHARK_PID:-?})"
else
    fail "tshark — proceso NO corriendo"
    info "tshark es iniciado por network-sensor automáticamente"
fi

# ─── 6. Interfaz de red ───────────────────────────────────────────────────────
$SUMMARY_ONLY || hdr "6. Interfaz eth0"
if [ "${ETH0_STATE:-}" = "UP" ]; then
    ok "eth0 — UP"
else
    warn "eth0 — estado: ${ETH0_STATE:-desconocido}"
fi
if [ "${ETH0_PROMISC:-0}" -gt 0 ]; then
    ok "eth0 — modo PROMISCUO activo (captura todo el tráfico LAN)"
else
    warn "eth0 — NO está en modo promiscuo (sensor puede perder paquetes)"
fi

# ─── 7. Conectividad al broker MQTT ───────────────────────────────────────────
$SUMMARY_ONLY || hdr "7. Conectividad al broker MQTT"
if [ "${MQTT_REACH:-fail}" = "ok" ]; then
    ok "Broker MQTT $BROKER_IP:$MQTT_PORT — accesible desde sensor"
else
    fail "Broker MQTT $BROKER_IP:$MQTT_PORT — NO accesible desde sensor"
    info "El sensor no puede publicar batches al analizador"
fi

# También verificar desde admin
if nc -z -w2 "$BROKER_IP" "$MQTT_PORT" 2>/dev/null; then
    ok "Broker MQTT $BROKER_IP:$MQTT_PORT — accesible desde admin"
else
    warn "Broker MQTT $BROKER_IP:$MQTT_PORT — no accesible desde admin"
fi

# ─── 8. Logs del sensor ───────────────────────────────────────────────────────
if ! $SUMMARY_ONLY; then
    hdr "8. Logs del sensor (últimas 5 líneas)"
    info "Total líneas en log: ${LOG_LINES:-0}"
    if [ -n "${LOG_LAST:-}" ] && [ "${LOG_LAST:-}" != "(sin log)" ]; then
        LAST_LOGS=$(pi3b_ssh 'tail -5 /var/log/network-sensor.log 2>/dev/null' 2>/dev/null || echo "")
        if [ -n "$LAST_LOGS" ]; then
            echo "$LAST_LOGS" | sed 's/^/    /'
        else
            info "Último log: ${LOG_LAST:-vacío}"
        fi
    else
        warn "Sin archivo de log en /var/log/network-sensor.log"
    fi
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

printf "${BOLD}━━━ RESUMEN RafexPi3B-A (Sensor) ━━━${NC}\n"
printf "  ${GREEN}✓ OK:${NC}          %d\n" "$PASS"
printf "  ${YELLOW}! Advertencias:${NC} %d\n" "$WARN"
printf "  ${RED}✗ Fallos:${NC}       %d\n" "$FAIL"
printf "  Estado:         ${STATUS_COLOR}${BOLD}%s${NC}\n" "$STATUS_STR"
printf "\n"

printf "RESUMEN_SALUD raspi3b-sensor PASS=%d WARN=%d FAIL=%d STATUS=%s\n" \
    "$PASS" "$WARN" "$FAIL" "$STATUS_STR"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
