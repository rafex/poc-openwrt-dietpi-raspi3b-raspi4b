#!/bin/bash
# health-raspi4b.sh — Estado completo de RafexPi4B (192.168.1.167)
#
# Servicios verificados:
#   • Red     — ping desde la máquina admin
#   • SSH     — acceso con llave /opt/keys/captive-portal
#   • k3s     — proceso Kubernetes ligero
#   • llama-server — motor de inferencia llama.cpp (puerto 8081)
#   • mosquitto    — broker MQTT (puerto 1883)
#   • Traefik      — ingress controller (pod k3s)
#   • ai-analyzer  — pod k3s con el analizador IA (HTTP /health)
#   • captive-portal — pod k3s activo
#   • HTTP endpoints — /health, /dashboard, /terminal, /api/stats
#
# Uso:
#   bash scripts/health-raspi4b.sh              # reporte completo
#   bash scripts/health-raspi4b.sh --summary    # solo resumen final
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

TARGET_IP="${RASPI4B_IP:-192.168.1.167}"
LLAMA_PORT=8081
MQTT_PORT=1883
# Sin -i: la máquina admin usa sus propias llaves SSH (~/.ssh/) para las Raspis.
# El SSH_KEY de common.sh es solo para el router OpenWrt (Dropbear).
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -o BatchMode=yes -o ConnectTimeout=5 -o LogLevel=ERROR"

# Wrapper SSH para la Pi4B
pi4b_ssh() { ssh $SSH_OPTS "root@$TARGET_IP" "$@" 2>/dev/null; }

if ! $SUMMARY_ONLY; then
    printf "\n${BOLD}╔══════════════════════════════════════════════════╗${NC}\n"
    printf   "${BOLD}║  RafexPi4B — IA + k3s + LLM  %-18s║${NC}\n" "$(date '+%H:%M:%S')"
    printf   "${BOLD}╚══════════════════════════════════════════════════╝${NC}\n"
    printf "  IP: %s\n" "$TARGET_IP"
fi

# ─── 1. Ping ──────────────────────────────────────────────────────────────────
$SUMMARY_ONLY || hdr "1. Red"
if ping -c1 -W2 "$TARGET_IP" &>/dev/null; then
    ok "Ping a $TARGET_IP — responde"
else
    fail "Ping a $TARGET_IP — sin respuesta"
    # Si no responde al ping, no tiene caso continuar con SSH
    printf "\n${RED}RESULTADO${NC}: CRÍTICO — no se puede llegar a $TARGET_IP\n"
    printf "RESUMEN_SALUD raspi4b PASS=%d WARN=%d FAIL=%d STATUS=CRITICO\n" \
        "$PASS" "$WARN" "$FAIL"
    exit 2
fi

# ─── 2. SSH ───────────────────────────────────────────────────────────────────
$SUMMARY_ONLY || hdr "2. SSH"
if pi4b_ssh 'echo ok' &>/dev/null; then
    ok "SSH root@$TARGET_IP — acceso OK"
else
    fail "SSH root@$TARGET_IP — sin acceso (verifica ~/.ssh/ o ~/.ssh/config)"
    printf "\n${RED}RESULTADO${NC}: CRÍTICO — SSH no disponible en $TARGET_IP\n"
    printf "RESUMEN_SALUD raspi4b PASS=%d WARN=%d FAIL=%d STATUS=CRITICO\n" \
        "$PASS" "$WARN" "$FAIL"
    exit 2
fi

# Recoger información del sistema remoto de una sola vez
REMOTE_INFO=$(pi4b_ssh '
    echo "UPTIME=$(uptime -p 2>/dev/null || uptime)"
    echo "LOADAVG=$(cat /proc/loadavg | cut -d" " -f1-3)"
    echo "MEM_FREE=$(awk "/MemFree/{print \$2}" /proc/meminfo)kB"
    echo "MEM_TOTAL=$(awk "/MemTotal/{print \$2}" /proc/meminfo)kB"
    echo "DISK_USE=$(df -h / | awk "NR==2{print \$5}")"
    # k3s
    ps aux 2>/dev/null | grep -q "[k]3s server" && echo K3S_PROC=running || echo K3S_PROC=stopped
    # llama-server
    if [ -f /var/run/llama-server.pid ] && kill -0 $(cat /var/run/llama-server.pid) 2>/dev/null; then
        echo "LLAMA_PID=$(cat /var/run/llama-server.pid)"
    else
        echo "LLAMA_PID="
    fi
    # mosquitto
    if service mosquitto status 2>/dev/null | grep -q "running\|active"; then
        echo "MOSQUITTO=running"
    elif pgrep -x mosquitto >/dev/null 2>&1; then
        echo "MOSQUITTO=running"
    else
        echo "MOSQUITTO=stopped"
    fi
    # Energía — rayo amarillo de subvoltaje (vcgencmd get_throttled)
    # Bits activos (0-3): problema AHORA. Bits pasados (16-19): ocurrió desde el reboot.
    # 0x1/0x10000=subvoltaje  0x2/0x20000=frec-limitada  0x4/0x40000=throttled  0x8/0x80000=temp-limit
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
    # Calcular % memoria usada
    if [ -n "${MEM_TOTAL:-}" ] && [ -n "${MEM_FREE:-}" ] && [ "$MEM_TOTAL" -gt 0 ]; then
        MEM_PCT=$(( (MEM_TOTAL - MEM_FREE) * 100 / MEM_TOTAL ))
        info "RAM     : ${MEM_PCT}% usada (${MEM_FREE}kB libre de ${MEM_TOTAL}kB)"
    fi
fi

# ─── Energía y temperatura ────────────────────────────────────────────────────
# Siempre se evalúa (afecta los contadores PASS/FAIL/WARN del resumen).
# vcgencmd get_throttled devuelve un bitmask hex:
#   bits  0-3  : problema ACTIVO ahora  → el rayo está encendido en este momento
#   bits 16-19 : evento PASADO desde el último reboot → el rayo apareció y se fue
#   0x0        : sin problemas
$SUMMARY_ONLY || hdr "Energía y temperatura"
if [ "${VCGENCMD_OK:-no}" = "yes" ] && [ "${THROTTLE_RAW:-unknown}" != "unknown" ]; then
    _T="${THROTTLE_RAW:-0x0}"
    _T_DEC=$(( _T )) 2>/dev/null || _T_DEC=0
    if [ "$_T_DEC" -eq 0 ]; then
        ok "Energía: OK — sin problemas [raw:${_T}]"
    elif [ "$(( _T_DEC & 0xF ))" -ne 0 ]; then
        # Problema ACTIVO — el rayo estaría visible ahora mismo
        _issues=""
        [ "$(( _T_DEC & 0x1 ))" -ne 0 ] && _issues="${_issues}SUBVOLTAJE "
        [ "$(( _T_DEC & 0x2 ))" -ne 0 ] && _issues="${_issues}FRECUENCIA-LIMITADA "
        [ "$(( _T_DEC & 0x4 ))" -ne 0 ] && _issues="${_issues}THROTTLED "
        [ "$(( _T_DEC & 0x8 ))" -ne 0 ] && _issues="${_issues}TEMP-SOFT-LIMIT "
        fail "⚡ RAYO ACTIVO: ${_issues}[raw:${_T}] — cambia la fuente de alimentación"
    else
        # Solo eventos pasados — el rayo apareció tras el reboot pero ya no está
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

# ─── 4. k3s ───────────────────────────────────────────────────────────────────
$SUMMARY_ONLY || hdr "4. k3s (Kubernetes ligero)"
if [ "${K3S_PROC:-stopped}" = "running" ]; then
    ok "k3s server — proceso corriendo"
    # Obtener estado de pods
    PODS=$(pi4b_ssh 'k3s kubectl get pods -A --no-headers 2>/dev/null' 2>/dev/null || echo "")
    if [ -n "$PODS" ]; then
        PODS_RUNNING=$(echo "$PODS" | grep -c "Running" || true)
        PODS_TOTAL=$(echo "$PODS"   | wc -l | tr -d ' ')
        ok "Pods en Running: $PODS_RUNNING / $PODS_TOTAL"
        if ! $SUMMARY_ONLY; then
            echo "$PODS" | awk '{printf "    %-20s %-30s %-12s %s\n",$1,$2,$4,$5}' | head -15
        fi
    else
        warn "No se pudo consultar pods (k3s puede estar iniciando)"
    fi
else
    fail "k3s server — proceso NO corriendo"
fi

# ─── 5. llama.cpp server ──────────────────────────────────────────────────────
$SUMMARY_ONLY || hdr "5. llama.cpp server (puerto $LLAMA_PORT)"
if [ -n "${LLAMA_PID:-}" ]; then
    ok "llama-server corriendo (PID $LLAMA_PID)"
else
    fail "llama-server NO corriendo (sin PID en /var/run/llama-server.pid)"
fi

# HTTP health de llama desde la máquina admin
LLAMA_HTTP=$(curl -sf --connect-timeout 3 --max-time 5 \
    "http://$TARGET_IP:$LLAMA_PORT/health" 2>/dev/null || echo "")
if [ -n "$LLAMA_HTTP" ]; then
    STATUS_LLM=$(echo "$LLAMA_HTTP" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); print(d.get('status','?'))" 2>/dev/null || echo "ok")
    ok "HTTP :$LLAMA_PORT/health → status=$STATUS_LLM"
    if ! $SUMMARY_ONLY; then
        echo "$LLAMA_HTTP" | python3 -m json.tool 2>/dev/null | head -6 | sed 's/^/    /'
    fi
else
    fail "HTTP :$LLAMA_PORT/health — sin respuesta desde admin"
fi

# ─── 6. Mosquitto MQTT ────────────────────────────────────────────────────────
$SUMMARY_ONLY || hdr "6. Mosquitto MQTT (puerto $MQTT_PORT)"
if [ "${MOSQUITTO:-stopped}" = "running" ]; then
    ok "mosquitto — servicio corriendo"
else
    fail "mosquitto — servicio DETENIDO"
fi

# Verificar puerto MQTT desde admin (nc -z -w2 es compatible con busybox)
if nc -z -w2 "$TARGET_IP" "$MQTT_PORT" 2>/dev/null; then
    ok "Puerto TCP $MQTT_PORT — accesible desde admin"
else
    warn "Puerto TCP $MQTT_PORT — no accesible desde admin (¿firewall?)"
fi

# ─── 7. Traefik ───────────────────────────────────────────────────────────────
$SUMMARY_ONLY || hdr "7. Traefik (ingress controller)"
TRAEFIK_POD=$(pi4b_ssh \
    'k3s kubectl get pods -n kube-system -l "app.kubernetes.io/name=traefik" \
     --no-headers 2>/dev/null | head -1' 2>/dev/null || echo "")
if echo "$TRAEFIK_POD" | grep -q "Running"; then
    ok "Traefik pod — Running"
    ! $SUMMARY_ONLY && echo "    $TRAEFIK_POD"
elif [ -n "$TRAEFIK_POD" ]; then
    warn "Traefik pod — estado: $TRAEFIK_POD"
else
    fail "Traefik pod — no encontrado en kube-system"
fi

# ─── 8. ai-analyzer ───────────────────────────────────────────────────────────
$SUMMARY_ONLY || hdr "8. ai-analyzer (pod k3s)"
AI_POD=$(pi4b_ssh \
    'k3s kubectl get pods -l app=ai-analyzer --no-headers 2>/dev/null | head -1' \
    2>/dev/null || echo "")
if echo "$AI_POD" | grep -q "Running"; then
    ok "ai-analyzer pod — Running"
    ! $SUMMARY_ONLY && echo "    $AI_POD"
elif [ -n "$AI_POD" ]; then
    warn "ai-analyzer pod — estado: $AI_POD"
else
    fail "ai-analyzer pod — no encontrado"
fi

# HTTP health del analizador
AI_HEALTH=$(curl -sf --connect-timeout 3 --max-time 5 \
    "http://$TARGET_IP/health" 2>/dev/null || echo "")
if [ -n "$AI_HEALTH" ]; then
    ok "HTTP /health — responde"
    if ! $SUMMARY_ONLY; then
        echo "$AI_HEALTH" | python3 -m json.tool 2>/dev/null | head -10 | sed 's/^/    /'
    fi
else
    fail "HTTP /health — sin respuesta"
fi

# Estadísticas
AI_STATS=$(curl -sf --connect-timeout 3 --max-time 5 \
    "http://$TARGET_IP/api/stats" 2>/dev/null || echo "")
if ! $SUMMARY_ONLY && [ -n "$AI_STATS" ]; then
    info "Estadísticas analizador:"
    echo "$AI_STATS" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(f'    batches_recibidos : {d.get(\"batches_received\",\"?\")}')
print(f'    análisis_ok       : {d.get(\"analyses_ok\",\"?\")}')
print(f'    análisis_error    : {d.get(\"analyses_error\",\"?\")}')
print(f'    llamadas_llm      : {d.get(\"llama_calls\",\"?\")}')
print(f'    errores_llm       : {d.get(\"llama_errors\",\"?\")}')
print(f'    mqtt_conectado    : {d.get(\"mqtt_connected\",\"?\")}')
" 2>/dev/null || true
fi

# ─── 9. Portal cautivo ────────────────────────────────────────────────────────
$SUMMARY_ONLY || hdr "9. Portal cautivo (pod k3s)"
PORTAL_PODS=$(pi4b_ssh \
    'k3s kubectl get pods -l "app in (captive-portal-lentium,captive-portal)" \
     --no-headers 2>/dev/null' 2>/dev/null || echo "")
if [ -z "$PORTAL_PODS" ]; then
    # Buscar con selector más amplio
    PORTAL_PODS=$(pi4b_ssh \
        'k3s kubectl get pods --no-headers 2>/dev/null | grep -i "portal\|lentium"' \
        2>/dev/null || echo "")
fi
if echo "$PORTAL_PODS" | grep -q "Running"; then
    PORTAL_ACTIVE=$(echo "$PORTAL_PODS" | grep "Running" | awk '{print $1}' | head -1)
    ok "Portal activo: $PORTAL_ACTIVE"
    ! $SUMMARY_ONLY && echo "$PORTAL_PODS" | sed 's/^/    /'
elif [ -n "$PORTAL_PODS" ]; then
    warn "Portal(es) encontrados pero no Running:"
    ! $SUMMARY_ONLY && echo "$PORTAL_PODS" | sed 's/^/    /'
else
    fail "Sin pods de portal cautivo"
fi

# ─── 10. HTTP endpoints desde admin ───────────────────────────────────────────
$SUMMARY_ONLY || hdr "10. HTTP endpoints (desde admin)"
for ep in /health /dashboard /terminal /api/history /api/stats; do
    CODE=$(curl -sf -o /dev/null -w "%{http_code}" --connect-timeout 3 --max-time 5 \
        "http://$TARGET_IP$ep" 2>/dev/null || echo "000")
    case "$CODE" in
        200|204) ok "GET http://$TARGET_IP$ep → $CODE" ;;
        301|302|307) ok "GET http://$TARGET_IP$ep → $CODE (redirect)" ;;
        000)     fail "GET http://$TARGET_IP$ep → sin respuesta (timeout/error)" ;;
        *)       warn "GET http://$TARGET_IP$ep → $CODE" ;;
    esac
done

# ─── Resumen ──────────────────────────────────────────────────────────────────
printf "\n"
if [ "$FAIL" -eq 0 ] && [ "$WARN" -eq 0 ]; then
    STATUS_STR="OK"
    STATUS_COLOR="$GREEN"
elif [ "$FAIL" -eq 0 ]; then
    STATUS_STR="ADVERTENCIAS"
    STATUS_COLOR="$YELLOW"
else
    STATUS_STR="FALLOS"
    STATUS_COLOR="$RED"
fi

printf "${BOLD}━━━ RESUMEN RafexPi4B ━━━${NC}\n"
printf "  ${GREEN}✓ OK:${NC}          %d\n" "$PASS"
printf "  ${YELLOW}! Advertencias:${NC} %d\n" "$WARN"
printf "  ${RED}✗ Fallos:${NC}       %d\n" "$FAIL"
printf "  Estado:         ${STATUS_COLOR}${BOLD}%s${NC}\n" "$STATUS_STR"
printf "\n"

# Línea de resumen estructurado para health-all.sh
printf "RESUMEN_SALUD raspi4b PASS=%d WARN=%d FAIL=%d STATUS=%s\n" \
    "$PASS" "$WARN" "$FAIL" "$STATUS_STR"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
