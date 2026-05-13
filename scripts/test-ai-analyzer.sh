#!/bin/bash
# test-ai-analyzer.sh — Tests funcionales directos al backend Java (GraalVM Native Image)
#
# Cubre todos los endpoints del ApiServer:
#   GET  /health
#   GET  /api/analyses
#   GET  /api/alerts
#   GET  /api/actions
#   GET  /api/anomalies
#   GET  /api/stats
#   GET  /api/profiles
#   GET  /api/reports
#   GET  /api/summaries
#   GET  /api/whitelist
#   POST /api/whitelist
#   DEL  /api/whitelist
#   GET  /api/portal/risk-message
#   POST /api/ingest                  (inyecta batch realista)
#   GET  /api/ingest                  (debe retornar 405)
#   POST /api/chat
#   GET  /api/chat/history
#   DEL  /api/chat/session
#   GET  /events                      (SSE — verifica cabeceras)
#   GET  /                            (root — metadata de endpoints)
#
# Pipeline end-to-end:
#   Inyecta batch → espera análisis → verifica en /api/analyses
#
# Uso:
#   bash scripts/test-ai-analyzer.sh
#   bash scripts/test-ai-analyzer.sh --host 192.168.1.167
#   bash scripts/test-ai-analyzer.sh --host 192.168.1.167 --port 5000
#   bash scripts/test-ai-analyzer.sh --quick          # solo smoke tests (sin pipeline LLM)
#   bash scripts/test-ai-analyzer.sh --verbose        # muestra respuestas completas
#   bash scripts/test-ai-analyzer.sh --no-color
#   bash scripts/test-ai-analyzer.sh --timeout 10
#   bash scripts/test-ai-analyzer.sh --wait 90        # segundos esperando análisis (default 60)

set -uo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
HOST="${AI_HOST:-192.168.1.167}"
PORT="${AI_PORT:-5000}"
TIMEOUT=8
WAIT_ANALYSIS=60
QUICK=false
VERBOSE=false
COLOR=true

# ── Parseo de args ────────────────────────────────────────────────────────────
for arg in "$@"; do
    case "$arg" in
        --host=*)    HOST="${arg#--host=}" ;;
        --host)      ;;  # handled by shift pattern below (positional)
        --port=*)    PORT="${arg#--port=}" ;;
        --timeout=*) TIMEOUT="${arg#--timeout=}" ;;
        --wait=*)    WAIT_ANALYSIS="${arg#--wait=}" ;;
        --quick)     QUICK=true ;;
        --verbose)   VERBOSE=true ;;
        --no-color)  COLOR=false ;;
        -h|--help)
            sed -n '2,25p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            # Permite --host 1.2.3.4 (sin =)
            [[ "$arg" =~ ^[0-9]+\.[0-9]+ ]] && HOST="$arg"
            ;;
    esac
done

BASE_URL="http://${HOST}:${PORT}"

# ── Colores ───────────────────────────────────────────────────────────────────
if $COLOR; then
    _R='\033[0;31m' _G='\033[0;32m' _Y='\033[0;33m'
    _C='\033[0;36m' _B='\033[1;34m' _D='\033[2m' _0='\033[0m'
else
    _R='' _G='' _Y='' _C='' _B='' _D='' _0=''
fi

# ── Contadores ────────────────────────────────────────────────────────────────
PASS=0; FAIL=0; SKIP=0
FAILED_TESTS=()

# ── Helpers ───────────────────────────────────────────────────────────────────
_section() { printf "\n${_B}══ %s ══${_0}\n" "$*"; }
_pass()    { PASS=$((PASS+1)); printf "  ${_G}✓${_0} %s\n" "$*"; }
_fail()    { FAIL=$((FAIL+1)); FAILED_TESTS+=("$*"); printf "  ${_R}✗${_0} %s\n" "$*"; }
_skip()    { SKIP=$((SKIP+1)); printf "  ${_Y}○${_0} %s ${_D}(omitido)${_0}\n" "$*"; }
_info()    { printf "  ${_C}·${_0} %s\n" "$*"; }
_verbose() { $VERBOSE && printf "${_D}%s${_0}\n" "$*" || true; }

# curl silencioso que retorna el cuerpo; guarda HTTP code en $HTTP_CODE
http_get() {
    local url="$1" extra="${2:-}"
    HTTP_CODE=$(curl -s -o /tmp/_tai_body -w "%{http_code}" \
        --max-time "$TIMEOUT" $extra "$url" 2>/dev/null || echo "000")
    BODY=$(cat /tmp/_tai_body 2>/dev/null || echo "")
    _verbose "  GET $url → HTTP $HTTP_CODE"
    _verbose "  $(echo "$BODY" | head -c 300)"
}

http_post() {
    local url="$1" data="$2" ct="${3:-application/json}"
    HTTP_CODE=$(curl -s -o /tmp/_tai_body -w "%{http_code}" \
        --max-time "$TIMEOUT" \
        -X POST -H "Content-Type: $ct" --data "$data" "$url" 2>/dev/null || echo "000")
    BODY=$(cat /tmp/_tai_body 2>/dev/null || echo "")
    _verbose "  POST $url → HTTP $HTTP_CODE"
    _verbose "  req: $(echo "$data" | head -c 200)"
    _verbose "  res: $(echo "$BODY" | head -c 300)"
}

http_delete() {
    local url="$1"
    HTTP_CODE=$(curl -s -o /tmp/_tai_body -w "%{http_code}" \
        --max-time "$TIMEOUT" -X DELETE "$url" 2>/dev/null || echo "000")
    BODY=$(cat /tmp/_tai_body 2>/dev/null || echo "")
    _verbose "  DELETE $url → HTTP $HTTP_CODE"
    _verbose "  $(echo "$BODY" | head -c 200)"
}

http_head_sse() {
    # Solo obtiene cabeceras de /events (no consume el stream)
    HTTP_CODE=$(curl -s -o /tmp/_tai_sse_head -w "%{http_code}" \
        --max-time 4 -I "$BASE_URL/events" 2>/dev/null || echo "000")
    BODY=$(cat /tmp/_tai_sse_head 2>/dev/null || echo "")
}

assert_http() {
    local expected="$1" label="$2"
    if [[ "$HTTP_CODE" == "$expected" ]]; then
        _pass "$label (HTTP $HTTP_CODE)"
        return 0
    else
        _fail "$label — esperado HTTP $expected, obtenido HTTP $HTTP_CODE"
        [[ -n "$BODY" ]] && _info "Respuesta: $(echo "$BODY" | head -c 200)"
        return 1
    fi
}

assert_body_contains() {
    local needle="$1" label="$2"
    if echo "$BODY" | grep -q "$needle"; then
        _pass "$label (contiene '$needle')"
    else
        _fail "$label — respuesta no contiene '$needle'"
        [[ -n "$BODY" ]] && _info "Respuesta: $(echo "$BODY" | head -c 300)"
    fi
}

assert_json_field() {
    local field="$1" label="$2"
    if echo "$BODY" | grep -q "\"${field}\""; then
        _pass "$label (campo '$field' presente)"
    else
        _fail "$label — falta campo JSON '$field'"
        [[ -n "$BODY" ]] && _info "Respuesta: $(echo "$BODY" | head -c 300)"
    fi
}

assert_is_array() {
    local label="$1"
    local trimmed
    trimmed=$(echo "$BODY" | tr -d '[:space:]' | head -c 1)
    if [[ "$trimmed" == "[" ]]; then
        _pass "$label (respuesta es array JSON)"
    else
        _fail "$label — respuesta no es array JSON (empieza con '$trimmed')"
        [[ -n "$BODY" ]] && _info "Respuesta: $(echo "$BODY" | head -c 200)"
    fi
}

# ── Payloads de test ──────────────────────────────────────────────────────────

# Batch normal: navegación cotidiana
BATCH_NORMAL=$(cat <<'JSON'
{
  "sensor_ip": "192.168.1.181",
  "timestamp": "2026-05-12T10:00:00Z",
  "duration_seconds": 30,
  "interface": "eth0",
  "total_packets": 1247,
  "total_bytes": 2097152,
  "total_bytes_fmt": "2.0 MB",
  "pps": 41.6,
  "bps": 559104,
  "active_src_ips": 4,
  "active_dst_ips": 12,
  "bytes": 2097152,
  "protocols": {"TCP": 892, "UDP": 312, "ICMP": 43},
  "dns_queries": ["youtube.com","google.com","instagram.com"],
  "dns_query_counts": {"youtube.com": 24, "google.com": 8, "instagram.com": 3},
  "http_hosts": ["192.168.1.1"],
  "http_host_counts": {"192.168.1.1": 2},
  "tls_sni_hosts": ["youtube.com","accounts.google.com"],
  "http_requests": ["GET http://192.168.1.1/"],
  "top_talkers": [
    {"ip": "192.168.1.55", "bytes": 1800000, "label": "1.7 MB"},
    {"ip": "192.168.1.60", "bytes": 297152,  "label": "290 KB"}
  ],
  "top_destinations": [
    {"ip": "142.250.80.78", "bytes": 1500000, "label": "1.4 MB"}
  ],
  "top_dst_ports": [{"port": 443, "count": 892}, {"port": 53, "count": 312}],
  "client_domain_counts": {
    "192.168.1.55": {"youtube.com": 24, "google.com": 8, "instagram.com": 3}
  },
  "suspicious": [],
  "suspicious_http_requests": [],
  "lan_devices": [
    {"ip": "192.168.1.55", "mac": "aa:bb:cc:dd:ee:01"},
    {"ip": "192.168.1.60", "mac": "aa:bb:cc:dd:ee:02"}
  ]
}
JSON
)

# Batch con tráfico sospechoso: escaneo de puertos + DGA
BATCH_SUSPICIOUS=$(cat <<'JSON'
{
  "sensor_ip": "192.168.1.181",
  "timestamp": "2026-05-12T22:00:00Z",
  "duration_seconds": 30,
  "interface": "eth0",
  "total_packets": 4800,
  "total_bytes": 524288,
  "total_bytes_fmt": "512 KB",
  "pps": 160.0,
  "bps": 139810,
  "bytes": 524288,
  "active_src_ips": 2,
  "active_dst_ips": 35,
  "protocols": {"TCP": 4200, "UDP": 600},
  "dns_queries": [
    "a4f2k.ru","b7x3q.cc","c9m1p.tk","d2n8v.xyz","e5j4w.biz",
    "instagram.com","tiktok.com","twitter.com",
    "192-168-1-1.nip.io","wp-admin.192-168-1-1.nip.io"
  ],
  "dns_query_counts": {
    "a4f2k.ru": 5, "b7x3q.cc": 5, "c9m1p.tk": 4, "instagram.com": 12,
    "tiktok.com": 8, "twitter.com": 6
  },
  "http_requests": [
    "GET http://192.168.1.1/admin",
    "POST http://192.168.1.181/wp-login.php",
    "GET http://192.168.1.181/.env"
  ],
  "suspicious": ["port_scan:192.168.1.99", "dga:a4f2k.ru", "dga:b7x3q.cc"],
  "suspicious_http_requests": [
    "POST http://192.168.1.181/wp-login.php",
    "GET http://192.168.1.181/.env"
  ],
  "top_talkers": [
    {"ip": "192.168.1.99", "bytes": 480000, "label": "469 KB"}
  ],
  "top_dst_ports": [
    {"port": 22, "count": 45}, {"port": 3389, "count": 30},
    {"port": 445, "count": 25}, {"port": 80, "count": 100}
  ],
  "client_domain_counts": {
    "192.168.1.99": {
      "instagram.com": 12, "tiktok.com": 8, "twitter.com": 6,
      "a4f2k.ru": 5, "b7x3q.cc": 5
    }
  },
  "bytes": 524288,
  "lan_devices": [{"ip": "192.168.1.99", "mac": "de:ad:be:ef:00:99"}]
}
JSON
)

# Batch alto ancho de banda (para anomaly detection)
BATCH_HIGHBW=$(cat <<'JSON'
{
  "sensor_ip": "192.168.1.181",
  "timestamp": "2026-05-12T14:00:00Z",
  "duration_seconds": 30,
  "interface": "eth0",
  "total_packets": 8500,
  "total_bytes": 62914560,
  "total_bytes_fmt": "60.0 MB",
  "pps": 283.3,
  "bps": 16777216,
  "bytes": 62914560,
  "active_src_ips": 1,
  "active_dst_ips": 3,
  "protocols": {"TCP": 8200, "UDP": 300},
  "dns_queries": ["netflix.com","nflxvideo.net"],
  "dns_query_counts": {"netflix.com": 45, "nflxvideo.net": 120},
  "top_talkers": [
    {"ip": "192.168.1.55", "bytes": 62914560, "label": "60.0 MB"}
  ],
  "top_dst_ports": [{"port": 443, "count": 8200}],
  "client_domain_counts": {
    "192.168.1.55": {"netflix.com": 45, "nflxvideo.net": 120}
  },
  "suspicious": ["high_bandwidth:192.168.1.55"],
  "suspicious_http_requests": [],
  "lan_devices": [{"ip": "192.168.1.55", "mac": "aa:bb:cc:dd:ee:01"}]
}
JSON
)

# ────────────────────────────────────────────────────────────────────────────────
# INICIO DE TESTS
# ────────────────────────────────────────────────────────────────────────────────

printf "\n${_B}╔══════════════════════════════════════════════╗${_0}\n"
printf "${_B}║  ai-analyzer — Test Suite (GraalVM Native)   ║${_0}\n"
printf "${_B}╚══════════════════════════════════════════════╝${_0}\n"
printf "  Backend : ${_C}${BASE_URL}${_0}\n"
printf "  Timeout : ${TIMEOUT}s por request\n"
$QUICK && printf "  Modo    : ${_Y}--quick (sin pipeline LLM)${_0}\n"
$VERBOSE && printf "  Verbose : activado\n"

# ── 0. Conectividad básica ────────────────────────────────────────────────────
_section "0. Conectividad"

if ! curl -s --max-time 5 --connect-timeout 4 -o /dev/null "$BASE_URL/health" 2>/dev/null; then
    _fail "No se pudo conectar a $BASE_URL — ¿el backend está corriendo?"
    printf "\n${_R}ABORTANDO: sin conexión al backend${_0}\n"
    exit 1
fi
_pass "TCP $HOST:$PORT accesible"

# ── 1. /health ────────────────────────────────────────────────────────────────
_section "1. GET /health"

http_get "$BASE_URL/health"
assert_http 200 "/health retorna 200"
assert_json_field "status"          "/health tiene campo 'status'"
assert_json_field "mqtt_connected"  "/health tiene campo 'mqtt_connected'"
assert_json_field "batches_total"   "/health tiene campo 'batches_total'"
assert_json_field "analyses_total"  "/health tiene campo 'analyses_total'"
assert_json_field "queue_pending"   "/health tiene campo 'queue_pending'"
assert_body_contains '"status":"ok"' "/health reporta status=ok"

# Mostrar resumen del health
if $VERBOSE || true; then
    started=$(echo "$BODY" | grep -o '"started_at":"[^"]*"' | cut -d'"' -f4)
    mqtt=$(echo "$BODY" | grep -o '"mqtt_connected":[^,}]*' | cut -d: -f2)
    provider=$(echo "$BODY" | grep -o '"chat_provider":"[^"]*"' | cut -d'"' -f4)
    batches=$(echo "$BODY" | grep -o '"batches_total":[0-9]*' | cut -d: -f2)
    pending=$(echo "$BODY" | grep -o '"queue_pending":[0-9]*' | cut -d: -f2)
    _info "  started_at      : $started"
    _info "  mqtt_connected  : $mqtt"
    _info "  chat_provider   : $provider"
    _info "  batches_total   : $batches"
    _info "  queue_pending   : $pending"
fi

# ── 2. / root metadata ────────────────────────────────────────────────────────
_section "2. GET / (root metadata)"

http_get "$BASE_URL/"
assert_http 200 "/ retorna 200"
assert_json_field "service"   "/ tiene campo 'service'"
assert_json_field "endpoints" "/ tiene campo 'endpoints'"
assert_body_contains "/health" "/ lista /health en endpoints"

# ── 3. /api/stats ─────────────────────────────────────────────────────────────
_section "3. GET /api/stats"

http_get "$BASE_URL/api/stats"
assert_http 200 "/api/stats retorna 200"
assert_json_field "batches_total"    "/api/stats tiene 'batches_total'"
assert_json_field "analyses_total"   "/api/stats tiene 'analyses_total'"
assert_json_field "analyses_by_risk" "/api/stats tiene 'analyses_by_risk'"
assert_json_field "llama_calls"      "/api/stats tiene 'llama_calls'"

# ── 4. /api/analyses ──────────────────────────────────────────────────────────
_section "4. GET /api/analyses"

http_get "$BASE_URL/api/analyses"
assert_http 200 "/api/analyses retorna 200"
assert_is_array "/api/analyses retorna array"

http_get "$BASE_URL/api/analyses?limit=5"
assert_http 200 "/api/analyses?limit=5 retorna 200"

http_post "$BASE_URL/api/analyses" "" "application/json"
assert_http 405 "/api/analyses rechaza POST (405)"

# ── 5. /api/alerts ────────────────────────────────────────────────────────────
_section "5. GET /api/alerts"

http_get "$BASE_URL/api/alerts"
assert_http 200 "/api/alerts retorna 200"
assert_is_array "/api/alerts retorna array"

http_get "$BASE_URL/api/alerts?limit=10"
assert_http 200 "/api/alerts?limit=10 retorna 200"

# ── 6. /api/actions ───────────────────────────────────────────────────────────
_section "6. GET /api/actions"

http_get "$BASE_URL/api/actions"
assert_http 200 "/api/actions retorna 200"
assert_is_array "/api/actions retorna array"

http_get "$BASE_URL/api/actions?limit=20"
assert_http 200 "/api/actions?limit=20 retorna 200"

# ── 7. /api/anomalies ─────────────────────────────────────────────────────────
_section "7. GET /api/anomalies"

http_get "$BASE_URL/api/anomalies"
assert_http 200 "/api/anomalies retorna 200"
assert_is_array "/api/anomalies retorna array"

http_get "$BASE_URL/api/anomalies?device_ip=192.168.1.55"
assert_http 200 "/api/anomalies?device_ip=X retorna 200"
assert_is_array "/api/anomalies filtrado por device_ip retorna array"

# ── 8. /api/profiles ──────────────────────────────────────────────────────────
_section "8. GET /api/profiles"

http_get "$BASE_URL/api/profiles"
assert_http 200 "/api/profiles retorna 200"
assert_is_array "/api/profiles retorna array"

# ── 9. /api/reports + /api/summaries ─────────────────────────────────────────
_section "9. GET /api/reports y /api/summaries"

http_get "$BASE_URL/api/reports"
assert_http 200 "/api/reports retorna 200"
assert_is_array "/api/reports retorna array"

http_get "$BASE_URL/api/summaries"
assert_http 200 "/api/summaries retorna 200"
assert_is_array "/api/summaries retorna array"

# ── 10. /api/portal/risk-message ─────────────────────────────────────────────
_section "10. GET /api/portal/risk-message"

http_get "$BASE_URL/api/portal/risk-message"
assert_http 200 "/api/portal/risk-message sin IP retorna 200"
assert_json_field "risk"      "/api/portal/risk-message tiene 'risk'"
assert_json_field "message"   "/api/portal/risk-message tiene 'message'"
assert_json_field "timestamp" "/api/portal/risk-message tiene 'timestamp'"

http_get "$BASE_URL/api/portal/risk-message?ip=192.168.1.55"
assert_http 200 "/api/portal/risk-message?ip=X retorna 200"
assert_body_contains "192.168.1.55" "risk-message incluye la IP consultada"

# Verificar que 'risk' es uno de los valores válidos
risk_val=$(echo "$BODY" | grep -o '"risk":"[^"]*"' | cut -d'"' -f4)
case "$risk_val" in
    BAJO|MEDIO|ALTO) _pass "risk-message tiene valor de riesgo válido ('$risk_val')" ;;
    *)               _fail "risk-message tiene valor de riesgo inválido: '$risk_val'" ;;
esac

# ── 11. /api/whitelist ────────────────────────────────────────────────────────
_section "11. CRUD /api/whitelist"

# GET inicial
http_get "$BASE_URL/api/whitelist"
assert_http 200 "GET /api/whitelist retorna 200"
assert_is_array "GET /api/whitelist retorna array"

# POST — agregar dominio de test
TEST_DOMAIN="test-ai-analyzer-$(date +%s).local"
http_post "$BASE_URL/api/whitelist" "{\"domain\":\"$TEST_DOMAIN\",\"reason\":\"test automatizado\"}"
assert_http 200 "POST /api/whitelist agrega dominio '$TEST_DOMAIN'"

# Verificar que aparece en GET
http_get "$BASE_URL/api/whitelist"
if echo "$BODY" | grep -q "$TEST_DOMAIN"; then
    _pass "Dominio '$TEST_DOMAIN' aparece en GET /api/whitelist"
else
    _fail "Dominio '$TEST_DOMAIN' no encontrado después de POST"
fi

# DELETE
http_delete "$BASE_URL/api/whitelist?domain=$TEST_DOMAIN"
assert_http 200 "DELETE /api/whitelist elimina dominio '$TEST_DOMAIN'"

# Verificar que ya no aparece
http_get "$BASE_URL/api/whitelist"
if echo "$BODY" | grep -q "$TEST_DOMAIN"; then
    _fail "Dominio '$TEST_DOMAIN' aún aparece después de DELETE"
else
    _pass "Dominio '$TEST_DOMAIN' eliminado correctamente"
fi

# POST sin body
http_post "$BASE_URL/api/whitelist" ""
assert_http 400 "POST /api/whitelist sin body retorna 400"

# ── 12. /events SSE ───────────────────────────────────────────────────────────
_section "12. GET /events (SSE)"

http_head_sse
if [[ "$HTTP_CODE" == "200" ]]; then
    _pass "GET /events retorna 200"
    if echo "$BODY" | grep -qi "text/event-stream"; then
        _pass "Content-Type es text/event-stream"
    else
        _fail "Content-Type no es text/event-stream"
        _info "Headers: $(echo "$BODY" | head -5)"
    fi
else
    # curl -I no funciona bien con SSE en algunos servers; probar con timeout corto
    SSE_CODE=$(curl -s -o /tmp/_tai_sse -w "%{http_code}" \
        --max-time 3 "$BASE_URL/events" 2>/dev/null || echo "000")
    SSE_BODY=$(cat /tmp/_tai_sse 2>/dev/null || echo "")
    if [[ "$SSE_CODE" == "200" ]] || [[ "$SSE_CODE" == "000" ]]; then
        # 000 = timeout, lo cual es correcto para SSE (stream abierto)
        _pass "GET /events alcanzable (HTTP $SSE_CODE — stream activo)"
    else
        _fail "GET /events retornó HTTP $SSE_CODE"
    fi
fi

# ── 13. POST /api/ingest — batch normal ───────────────────────────────────────
_section "13. POST /api/ingest (batch normal)"

http_post "$BASE_URL/api/ingest" "$BATCH_NORMAL"
assert_http 200 "POST /api/ingest acepta batch normal"
assert_json_field "batch_id" "/api/ingest retorna batch_id"
assert_body_contains '"queued":true' "/api/ingest confirma encolamiento"

BATCH_ID_NORMAL=$(echo "$BODY" | grep -o '"batch_id":[0-9]*' | grep -o '[0-9]*')
_info "  batch_id = $BATCH_ID_NORMAL"

# GET no permitido
http_get "$BASE_URL/api/ingest"
assert_http 405 "GET /api/ingest rechazado (405)"

# POST sin body
http_post "$BASE_URL/api/ingest" ""
assert_http 400 "POST /api/ingest sin body retorna 400"

# ── 14. POST /api/ingest — batch sospechoso ───────────────────────────────────
_section "14. POST /api/ingest (batch sospechoso — DGA + escaneo)"

http_post "$BASE_URL/api/ingest" "$BATCH_SUSPICIOUS"
assert_http 200 "POST /api/ingest acepta batch sospechoso"
assert_json_field "batch_id" "Batch sospechoso retorna batch_id"

BATCH_ID_SUSP=$(echo "$BODY" | grep -o '"batch_id":[0-9]*' | grep -o '[0-9]*')
_info "  batch_id = $BATCH_ID_SUSP"

# ── 15. POST /api/ingest — alto ancho de banda ───────────────────────────────
_section "15. POST /api/ingest (alto ancho de banda — para anomaly detection)"

http_post "$BASE_URL/api/ingest" "$BATCH_HIGHBW"
assert_http 200 "POST /api/ingest acepta batch high-bandwidth"
BATCH_ID_HBW=$(echo "$BODY" | grep -o '"batch_id":[0-9]*' | grep -o '[0-9]*')
_info "  batch_id = $BATCH_ID_HBW"

# ── 16. Pipeline end-to-end — esperar análisis ────────────────────────────────
if $QUICK; then
    _section "16. Pipeline end-to-end"
    _skip "Pipeline LLM (--quick activado — omite espera de análisis)"
else
    _section "16. Pipeline end-to-end (espera hasta ${WAIT_ANALYSIS}s)"
    _info "Batches inyectados: normal=$BATCH_ID_NORMAL  sospechoso=$BATCH_ID_SUSP  highbw=$BATCH_ID_HBW"
    _info "Esperando que el worker analice..."

    ANALYSIS_FOUND=false
    ELAPSED=0
    STEP=5

    while [[ $ELAPSED -lt $WAIT_ANALYSIS ]]; do
        sleep $STEP
        ELAPSED=$((ELAPSED + STEP))

        http_get "$BASE_URL/api/analyses?limit=10"
        if [[ "$HTTP_CODE" == "200" ]] && echo "$BODY" | grep -q "\"batch_id\":$BATCH_ID_NORMAL"; then
            ANALYSIS_FOUND=true
            break
        fi

        # También aceptar que el batch sospechoso o highbw ya fue analizado
        if [[ "$HTTP_CODE" == "200" ]] && \
           (echo "$BODY" | grep -q "\"batch_id\":$BATCH_ID_SUSP" || \
            echo "$BODY" | grep -q "\"batch_id\":$BATCH_ID_HBW"); then
            ANALYSIS_FOUND=true
            break
        fi

        printf "    ${_D}...${ELAPSED}s${_0}\r"
    done

    if $ANALYSIS_FOUND; then
        _pass "Análisis completado en ~${ELAPSED}s"

        # Verificar campos del análisis
        assert_json_field "risk"     "Análisis tiene campo 'risk'"
        assert_json_field "analysis" "Análisis tiene campo 'analysis'"

        # Verificar que el riesgo del batch sospechoso sea MEDIO o ALTO
        http_get "$BASE_URL/api/analyses?limit=5"
        if echo "$BODY" | grep -qE '"risk":"(MEDIO|ALTO)"'; then
            _pass "LLM clasificó tráfico sospechoso como MEDIO o ALTO"
        else
            _info "Nota: no se detectó riesgo MEDIO/ALTO en los últimos análisis"
        fi

        # Verificar alertas generadas
        http_get "$BASE_URL/api/alerts?limit=20"
        ALERT_COUNT=$(echo "$BODY" | grep -o '"id":[0-9]*' | wc -l | tr -d ' ')
        _info "Alertas en BD: $ALERT_COUNT"

        # Verificar anomalías para el batch high-bandwidth
        http_get "$BASE_URL/api/anomalies"
        ANOMALY_COUNT=$(echo "$BODY" | grep -o '"id":[0-9]*' | wc -l | tr -d ' ')
        _info "Anomalías en BD: $ANOMALY_COUNT"

    else
        _fail "Análisis no completado en ${WAIT_ANALYSIS}s (el worker puede estar ocupado o el LLM lento)"
        _info "Verifica: curl $BASE_URL/api/stats | grep pending"
    fi
fi

# ── 17. /api/chat ─────────────────────────────────────────────────────────────
_section "17. /api/chat"

SESSION_ID="test-session-$(date +%s)"

# POST chat
http_post "$BASE_URL/api/chat" \
    "{\"question\":\"¿Cuántos batches se han procesado?\",\"session_id\":\"$SESSION_ID\"}"

if [[ "$HTTP_CODE" == "200" ]]; then
    _pass "POST /api/chat retorna 200"
    assert_json_field "answer"     "/api/chat tiene campo 'answer'"
    assert_json_field "session_id" "/api/chat tiene campo 'session_id'"
    assert_json_field "provider"   "/api/chat tiene campo 'provider'"
    PROVIDER=$(echo "$BODY" | grep -o '"provider":"[^"]*"' | cut -d'"' -f4)
    _info "  provider = $PROVIDER"
    ANSWER_PREVIEW=$(echo "$BODY" | grep -o '"answer":"[^"]*"' | head -c 120)
    _info "  respuesta : $ANSWER_PREVIEW..."
elif [[ "$HTTP_CODE" == "403" ]]; then
    _skip "POST /api/chat — chat deshabilitado (403, FEATURE_CHAT=false)"
else
    _fail "POST /api/chat retornó HTTP $HTTP_CODE"
fi

# GET historial
http_get "$BASE_URL/api/chat/history?session_id=$SESSION_ID"
if [[ "$HTTP_CODE" == "200" ]]; then
    _pass "GET /api/chat/history retorna 200"
    assert_is_array "GET /api/chat/history retorna array"
else
    _info "GET /api/chat/history — HTTP $HTTP_CODE"
fi

# DELETE sesión
http_delete "$BASE_URL/api/chat/session?session_id=$SESSION_ID"
if [[ "$HTTP_CODE" == "200" ]]; then
    _pass "DELETE /api/chat/session retorna 200"
elif [[ "$HTTP_CODE" == "400" ]]; then
    _info "DELETE /api/chat/session — 400 (sesión ya inexistente, normal si chat estaba off)"
fi

# POST sin question
http_post "$BASE_URL/api/chat" "{\"session_id\":\"$SESSION_ID\"}"
if [[ "$HTTP_CODE" == "400" ]]; then
    _pass "POST /api/chat sin 'question' retorna 400"
elif [[ "$HTTP_CODE" == "403" ]]; then
    _skip "POST /api/chat sin 'question' — chat deshabilitado"
fi

# ── 18. Casos de error ────────────────────────────────────────────────────────
_section "18. Casos de error y validación"

# Content-Type incorrecto
http_post "$BASE_URL/api/ingest" "texto plano" "text/plain"
# Puede ser 200 (backend acepta) o 400 — solo verificamos que no crashea
if [[ "$HTTP_CODE" == "000" ]]; then
    _fail "Backend no respondió a request con content-type incorrecto"
else
    _pass "Backend responde ante content-type incorrecto (HTTP $HTTP_CODE, no crash)"
fi

# Método incorrecto en varios endpoints
for ep in "/api/analyses" "/api/alerts" "/api/actions" "/api/anomalies" \
          "/api/profiles" "/api/reports" "/api/summaries"; do
    http_post "$BASE_URL$ep" "{}"
    if [[ "$HTTP_CODE" == "405" ]]; then
        _pass "POST $ep rechazado con 405"
    else
        _fail "POST $ep — esperado 405, obtenido $HTTP_CODE"
    fi
done

# ── 19. Verificación final de stats ──────────────────────────────────────────
_section "19. Verificación final de contadores"

http_get "$BASE_URL/api/stats"
if [[ "$HTTP_CODE" == "200" ]]; then
    bt=$(echo "$BODY" | grep -o '"batches_total":[0-9]*' | cut -d: -f2)
    at=$(echo "$BODY" | grep -o '"analyses_total":[0-9]*' | cut -d: -f2)
    lc=$(echo "$BODY" | grep -o '"llama_calls":[0-9]*' | cut -d: -f2)
    le=$(echo "$BODY" | grep -o '"llama_errors":[0-9]*' | cut -d: -f2)
    ok=$(echo "$BODY" | grep -o '"analyses_ok":[0-9]*' | cut -d: -f2)
    er=$(echo "$BODY" | grep -o '"analyses_error":[0-9]*' | cut -d: -f2)
    _pass "GET /api/stats final"
    _info "  batches_total   : $bt"
    _info "  analyses_total  : $at"
    _info "  analyses_ok     : $ok"
    _info "  analyses_error  : $er"
    _info "  llama_calls     : $lc"
    _info "  llama_errors    : $le"

    # Advertir si hay demasiados errores
    if [[ -n "$le" && "$le" =~ ^[0-9]+$ && $le -gt 5 ]]; then
        _info "${_Y}AVISO: $le errores de LLM — revisar conexión a llama-server o Groq${_0}"
    fi
fi

# ────────────────────────────────────────────────────────────────────────────────
# RESUMEN
# ────────────────────────────────────────────────────────────────────────────────
TOTAL=$((PASS + FAIL + SKIP))

printf "\n${_B}══ Resumen ══════════════════════════════════════${_0}\n"
printf "  Backend : ${_C}${BASE_URL}${_0}\n"
printf "  Total   : %d tests\n" "$TOTAL"
printf "  ${_G}PASS${_0}    : %d\n" "$PASS"
printf "  ${_R}FAIL${_0}    : %d\n" "$FAIL"
printf "  ${_Y}SKIP${_0}    : %d\n" "$SKIP"

if [[ ${#FAILED_TESTS[@]} -gt 0 ]]; then
    printf "\n${_R}Tests fallidos:${_0}\n"
    for t in "${FAILED_TESTS[@]}"; do
        printf "  ${_R}✗${_0} %s\n" "$t"
    done
fi

printf "\n"
if [[ $FAIL -eq 0 ]]; then
    printf "${_G}✓ Todos los tests pasaron${_0}\n\n"
    exit 0
else
    printf "${_R}✗ %d test(s) fallaron${_0}\n\n" "$FAIL"
    exit 1
fi
