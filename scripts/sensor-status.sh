#!/bin/bash
# sensor-status.sh — Estado completo del sistema sensor + IA
#
# Ejecutar en: Raspberry Pi 4B (tiene acceso a kubectl)
# Muestra estado de: sensor (3B), llama-server, ai-analyzer, dashboard
#
# Uso:
#   bash scripts/sensor-status.sh
#   bash scripts/sensor-status.sh --follow   # tail -f en logs del analizador
#   bash scripts/sensor-status.sh --test     # tests funcionales automáticos

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'
hdr()  { echo -e "\n${BOLD}${CYAN}━━━ $* ━━━${NC}"; }
ok2()  { echo -e "  ${GREEN}✓${NC} $*"; }
fail() { echo -e "  ${RED}✗${NC} $*"; }
info2(){ echo -e "  ${BLUE}·${NC} $*"; }
warn2(){ echo -e "  ${YELLOW}!${NC} $*"; }

PI4_IP="192.168.1.167"
PI3_IP="192.168.1.181"
LLAMA_PORT=8081
FOLLOW=false
RUN_TESTS=false

for arg in "$@"; do
    case "$arg" in
        --follow|-f)  FOLLOW=true    ;;
        --test|-t)    RUN_TESTS=true ;;
        --help|-h)
            echo "Uso: $0 [--follow] [--test]"
            echo "  --follow  : tail -f logs del ai-analyzer"
            echo "  --test    : ejecutar tests funcionales"
            exit 0
            ;;
    esac
done

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   RafexPi — Network Sensor + AI Status      ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo -e "  $(date '+%Y-%m-%d %H:%M:%S')"

# ─── k3s pods ────────────────────────────────────────────────────────────────
hdr "Pods k3s"
kubectl get pods -l "app in (ai-analyzer,dashboard)" -o wide 2>/dev/null \
    || warn2 "No se pudo consultar k3s"

# ─── llama.cpp server ─────────────────────────────────────────────────────────
hdr "llama.cpp server (Raspi 4B :$LLAMA_PORT)"

if [ -f /var/run/llama-server.pid ] && \
   kill -0 "$(cat /var/run/llama-server.pid)" 2>/dev/null; then
    ok2 "Proceso corriendo (PID $(cat /var/run/llama-server.pid))"
else
    fail "Proceso NO corriendo"
fi

if curl -sf "http://127.0.0.1:$LLAMA_PORT/health" &>/dev/null; then
    ok2 "HTTP /health responde en :$LLAMA_PORT"
    HEALTH=$(curl -sf "http://127.0.0.1:$LLAMA_PORT/health" | python3 -m json.tool 2>/dev/null)
    echo "$HEALTH" | head -5 | sed 's/^/    /'
else
    fail "HTTP /health no responde en :$LLAMA_PORT"
fi

# ─── ai-analyzer ─────────────────────────────────────────────────────────────
hdr "ai-analyzer (k8s pod)"

POD_AI=$(kubectl get pods -l app=ai-analyzer -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$POD_AI" ]; then
    STATUS=$(kubectl get pod "$POD_AI" -o jsonpath='{.status.phase}' 2>/dev/null)
    ok2 "Pod: $POD_AI ($STATUS)"

    READY=$(kubectl get pod "$POD_AI" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)
    [ "$READY" = "true" ] && ok2 "Ready: true" || warn2 "Ready: $READY"
fi

if curl -sf "http://$PI4_IP/health" &>/dev/null; then
    ok2 "HTTP /health responde"
    curl -sf "http://$PI4_IP/health" | python3 -m json.tool 2>/dev/null | head -15 | sed 's/^/    /'
else
    fail "HTTP /health no responde en http://$PI4_IP/health"
fi

# Estadísticas del analizador
if curl -sf "http://$PI4_IP/api/stats" &>/dev/null; then
    echo ""
    info2 "Estadísticas:"
    curl -sf "http://$PI4_IP/api/stats" | python3 -m json.tool 2>/dev/null | sed 's/^/    /'
fi

# ─── dashboard ────────────────────────────────────────────────────────────────
hdr "Dashboard"

for path in /dashboard /terminal; do
    CODE=$(curl -sf -o /dev/null -w "%{http_code}" "http://$PI4_IP$path" 2>/dev/null)
    if [ "$CODE" = "200" ]; then
        ok2 "http://$PI4_IP$path → $CODE"
    else
        fail "http://$PI4_IP$path → $CODE"
    fi
done

# ─── sensor (Raspi 3B) ────────────────────────────────────────────────────────
hdr "Sensor Raspi 3B ($PI3_IP)"

# Verificar SSH al sensor (si tenemos llave)
SENSOR_KEY="/opt/keys/sensor-admin"  # llave para acceder a la 3B desde la 4B
if [ -f "$SENSOR_KEY" ]; then
    SENSOR_STATUS=$(ssh -i "$SENSOR_KEY" \
        -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5 \
        "root@$PI3_IP" \
        "if [ -f /var/run/network-sensor.pid ] && kill -0 \$(cat /var/run/network-sensor.pid) 2>/dev/null; then echo running; else echo stopped; fi" \
        2>/dev/null)
    if [ "$SENSOR_STATUS" = "running" ]; then
        ok2 "Servicio network-sensor: corriendo"
        ssh -i "$SENSOR_KEY" -o StrictHostKeyChecking=no -o BatchMode=yes \
            "root@$PI3_IP" "tail -5 /var/log/network-sensor.log" 2>/dev/null \
            | sed 's/^/    /'
    elif [ "$SENSOR_STATUS" = "stopped" ]; then
        fail "Servicio network-sensor: DETENIDO"
    else
        warn2 "No se pudo conectar a la Raspi 3B via SSH"
    fi
else
    warn2 "Sin llave SSH para la 3B ($SENSOR_KEY no existe)"
    info2 "Verifica el sensor manualmente: ssh root@$PI3_IP"
fi

# Ver último análisis recibido
hdr "Último análisis IA"

if curl -sf "http://$PI4_IP/api/history?limit=1" &>/dev/null; then
    LAST=$(curl -sf "http://$PI4_IP/api/history?limit=1")
    COUNT=$(echo "$LAST" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('count',0))" 2>/dev/null)
    if [ "${COUNT:-0}" -gt 0 ]; then
        echo "$LAST" | python3 -c "
import sys, json
d = json.load(sys.stdin)
if not d.get('items'): exit()
item = d['items'][-1]
print(f'  ID        : {item.get(\"id\",\"?\")}')
print(f'  Timestamp : {item.get(\"timestamp\",\"?\")}')
print(f'  Riesgo    : {item.get(\"risk\",\"?\")}')
print(f'  Paquetes  : {item.get(\"packets\",\"?\")}')
print(f'  Bytes     : {item.get(\"bytes_fmt\",\"?\")}')
print(f'  Alertas   : {len(item.get(\"suspicious\",[]))}')
print(f'  Inferencia: {item.get(\"elapsed_s\",\"?\")}s')
print()
print('  Análisis:')
analysis = item.get('analysis','(vacío)')
for line in analysis.split('\n')[:10]:
    print(f'    {line}')
" 2>/dev/null
    else
        info2 "Sin análisis todavía — esperando datos del sensor"
    fi
fi

# ─── Tests funcionales ────────────────────────────────────────────────────────
if $RUN_TESTS; then
    hdr "Tests funcionales"
    PASS=0; FAIL=0

    run_test() {
        local desc="$1"; local cmd="$2"; local expect="$3"
        if eval "$cmd" &>/dev/null; then
            ok2 "Test $((PASS+FAIL+1)): $desc"
            PASS=$((PASS+1))
        else
            fail "Test $((PASS+FAIL+1)): $desc"
            FAIL=$((FAIL+1))
        fi
    }

    run_test "llama.cpp server :$LLAMA_PORT"  "curl -sf http://127.0.0.1:$LLAMA_PORT/health"
    run_test "ai-analyzer /health"            "curl -sf http://$PI4_IP/health"
    run_test "ai-analyzer /api/history"       "curl -sf http://$PI4_IP/api/history"
    run_test "ai-analyzer /api/stats"         "curl -sf http://$PI4_IP/api/stats"
    run_test "dashboard /dashboard"           "curl -sf http://$PI4_IP/dashboard"
    run_test "dashboard /terminal"            "curl -sf http://$PI4_IP/terminal"
    run_test "SSE stream (1s)"                "curl -sf -m 1 http://$PI4_IP/api/stream" || true

    # Test de ingesta con datos simulados
    info2 "Enviando batch de prueba al analizador..."
    TEST_PAYLOAD='{"timestamp":"'$(date -u +%FT%TZ)'","duration_seconds":30,"sensor_ip":"192.168.1.181","interface":"eth0","total_packets":142,"total_bytes":89234,"total_bytes_fmt":"87.1 KB","pps":4.7,"bps":23800,"active_src_ips":5,"active_dst_ips":12,"top_talkers":[{"ip":"192.168.1.55","bytes":45000,"label":"43.9 KB"}],"top_destinations":[{"ip":"8.8.8.8","bytes":12000,"label":"11.7 KB"}],"top_dst_ports":[{"port":443,"count":45},{"port":80,"count":12},{"port":53,"count":38}],"protocols":{"TCP":89,"UDP":48,"ICMP":5},"dns_queries":["google.com","youtube.com","api.example.com"],"http_hosts":["example.com"],"http_requests":[],"suspicious":[],"arp_events":[],"lan_devices":["192.168.1.55","192.168.1.181","192.168.1.167"]}'
    HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" \
        -X POST "http://$PI4_IP/api/ingest" \
        -H "Content-Type: application/json" \
        -d "$TEST_PAYLOAD" 2>/dev/null)
    if [ "$HTTP_CODE" = "200" ]; then
        ok2 "POST /api/ingest (batch de prueba): $HTTP_CODE"
        PASS=$((PASS+1))
    else
        fail "POST /api/ingest: HTTP $HTTP_CODE"
        FAIL=$((FAIL+1))
    fi

    echo ""
    echo -e "  Resultado: ${GREEN}${PASS} OK${NC} / ${RED}${FAIL} FAIL${NC}"
fi

# ─── Resumen de URLs ──────────────────────────────────────────────────────────
hdr "URLs del sistema"
echo "  Dashboard visual : http://$PI4_IP/dashboard"
echo "  Terminal en vivo : http://$PI4_IP/terminal"
echo "  API historial    : http://$PI4_IP/api/history"
echo "  API stream SSE   : http://$PI4_IP/api/stream"
echo "  Health check     : http://$PI4_IP/health"
echo "  llama.cpp server : http://$PI4_IP:$LLAMA_PORT/health"
echo ""
echo -e "  Logs: kubectl logs -f deploy/ai-analyzer"

if $FOLLOW; then
    echo ""
    info2 "Siguiendo logs de ai-analyzer (Ctrl+C para salir)..."
    kubectl logs -f deploy/ai-analyzer
fi
