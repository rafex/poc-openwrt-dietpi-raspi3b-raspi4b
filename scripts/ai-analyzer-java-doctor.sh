#!/usr/bin/env bash
# Diagnóstico rápido de LLM + AI Analyzer Java en Raspi4B.
set -u

LLM_PORT="${LLM_PORT:-8081}"
ANALYZER_PORT="${ANALYZER_PORT:-5000}"
MQTT_HOST="${MQTT_HOST:-127.0.0.1}"
MQTT_TOPIC_BATCH="${MQTT_TOPIC_BATCH:-rafexpi/sensor/batch}"
JAVA_LOG_PRIMARY="/var/logs/ai-analyzer-java.log.0"
JAVA_LOG_FALLBACK="/tmp/ai-analyzer-java.log.0"
LLAMA_LOG="/var/log/llama-server.log"
INJECT_TEST=false

for arg in "$@"; do
  case "$arg" in
    --inject-test) INJECT_TEST=true ;;
    --llm-port=*) LLM_PORT="${arg#*=}" ;;
    --analyzer-port=*) ANALYZER_PORT="${arg#*=}" ;;
    --mqtt-host=*) MQTT_HOST="${arg#*=}" ;;
    --mqtt-topic=*) MQTT_TOPIC_BATCH="${arg#*=}" ;;
    --help|-h)
      cat <<EOF
Uso:
  bash scripts/ai-analyzer-java-doctor.sh [opciones]

Opciones:
  --inject-test            Inserta un batch sintético en /api/ingest
  --llm-port=8081          Puerto de llama-server
  --analyzer-port=5000     Puerto de ai-analyzer Java
  --mqtt-host=127.0.0.1    Host del broker MQTT
  --mqtt-topic=...         Topic de batches
EOF
      exit 0
      ;;
    *)
      echo "[WARN] argumento ignorado: $arg"
      ;;
  esac
done

OK=0
WARN=0
FAIL=0

log_info() { printf '[INFO]  %s\n' "$*"; }
log_ok()   { printf '[OK]    %s\n' "$*"; OK=$((OK+1)); }
log_warn() { printf '[WARN]  %s\n' "$*"; WARN=$((WARN+1)); }
log_fail() { printf '[FAIL]  %s\n' "$*"; FAIL=$((FAIL+1)); }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

check_proc() {
  if ps aux | grep -E "llama-server|ai-analyzer" | grep -v grep >/dev/null 2>&1; then
    log_ok "Procesos llama-server/ai-analyzer detectados"
    ps aux | grep -E "llama-server|ai-analyzer" | grep -v grep | sed 's/^/        /'
  else
    log_fail "No se detectaron procesos llama-server/ai-analyzer"
  fi
}

check_ports() {
  if ! have_cmd ss; then
    log_warn "No existe comando ss; se omite validación de puertos"
    return
  fi
  local out
  out="$(ss -lntp 2>/dev/null | grep -E ":${LLM_PORT}|:${ANALYZER_PORT}" || true)"
  if [ -n "$out" ]; then
    log_ok "Puertos en escucha detectados (:${LLM_PORT} / :${ANALYZER_PORT})"
    printf '%s\n' "$out" | sed 's/^/        /'
  else
    log_fail "No se detectaron puertos :${LLM_PORT} ni :${ANALYZER_PORT} en escucha"
  fi
}

check_llm_health() {
  if ! have_cmd curl; then
    log_fail "curl no está instalado"
    return
  fi
  if curl -fsS "http://127.0.0.1:${LLM_PORT}/health" >/dev/null 2>&1; then
    log_ok "LLM /health responde en :${LLM_PORT}"
  else
    log_fail "LLM /health no responde en :${LLM_PORT}"
  fi
}

check_analyzer_api() {
  if ! have_cmd curl; then
    log_fail "curl no está instalado"
    return
  fi
  local stats queue hist
  stats="$(curl -fsS "http://127.0.0.1:${ANALYZER_PORT}/api/stats" 2>/dev/null || true)"
  queue="$(curl -fsS "http://127.0.0.1:${ANALYZER_PORT}/api/queue" 2>/dev/null || true)"
  hist="$(curl -fsS "http://127.0.0.1:${ANALYZER_PORT}/api/history" 2>/dev/null || true)"
  if [ -n "$stats" ] && [ -n "$queue" ] && [ -n "$hist" ]; then
    log_ok "API analyzer responde (/api/stats, /api/queue, /api/history)"
    printf '%s\n' "$stats" | sed 's/^/        stats: /'
    printf '%s\n' "$queue" | sed 's/^/        queue: /'
    printf '%s\n' "$hist" | head -c 220 | sed 's/^/        history: /'
    printf '\n'
  else
    log_fail "API analyzer no responde correctamente en :${ANALYZER_PORT}"
  fi
}

inject_test_batch() {
  if ! $INJECT_TEST; then
    return
  fi
  log_info "Inyectando batch de prueba en /api/ingest..."
  local body resp
  body='{"timestamp":"2026-05-13T12:00:00Z","sensor_ip":"192.168.1.181","duration_seconds":30,"total_packets":12,"total_bytes_fmt":"12 KB","active_src_ips":1,"dns_queries":["example.org"],"suspicious":[]}'
  resp="$(curl -fsS -X POST "http://127.0.0.1:${ANALYZER_PORT}/api/ingest" \
    -H 'Content-Type: application/json' \
    -d "$body" 2>/dev/null || true)"
  if [ -n "$resp" ]; then
    log_ok "Batch de prueba aceptado por analyzer"
    printf '%s\n' "$resp" | sed 's/^/        /'
  else
    log_fail "No se pudo inyectar batch de prueba en /api/ingest"
  fi
}

check_mqtt_flow_hint() {
  if ! have_cmd mosquitto_sub; then
    log_warn "mosquitto_sub no está instalado; omito prueba rápida MQTT"
    return
  fi
  log_info "Prueba rápida MQTT (2s) en topic ${MQTT_TOPIC_BATCH}..."
  local out
  out="$(timeout 2s mosquitto_sub -h "$MQTT_HOST" -t "$MQTT_TOPIC_BATCH" -C 1 -W 2 2>/dev/null || true)"
  if [ -n "$out" ]; then
    log_ok "Se observó al menos 1 mensaje MQTT en ${MQTT_TOPIC_BATCH}"
  else
    log_warn "No se observó mensaje MQTT en 2s (puede ser normal si no hubo batch en ventana)"
  fi
}

check_logs() {
  if [ -f "$LLAMA_LOG" ]; then
    log_ok "Log LLM encontrado: $LLAMA_LOG"
    tail -n 5 "$LLAMA_LOG" | sed 's/^/        /'
  else
    log_warn "No existe log LLM en $LLAMA_LOG"
  fi

  if [ -f "$JAVA_LOG_PRIMARY" ]; then
    log_ok "Log analyzer Java encontrado: $JAVA_LOG_PRIMARY"
    tail -n 8 "$JAVA_LOG_PRIMARY" | sed 's/^/        /'
  elif [ -f "$JAVA_LOG_FALLBACK" ]; then
    log_ok "Log analyzer Java encontrado (fallback): $JAVA_LOG_FALLBACK"
    tail -n 8 "$JAVA_LOG_FALLBACK" | sed 's/^/        /'
  else
    log_warn "No se encontró log analyzer Java ni en /var/logs ni /tmp"
  fi
}

main() {
  log_info "=== Doctor LLM + AI Analyzer Java ==="
  log_info "LLM_PORT=${LLM_PORT} ANALYZER_PORT=${ANALYZER_PORT} MQTT_HOST=${MQTT_HOST}"
  check_proc
  check_ports
  check_llm_health
  check_analyzer_api
  inject_test_batch
  check_mqtt_flow_hint
  check_logs
  printf '\n'
  log_info "Resumen: OK=${OK} WARN=${WARN} FAIL=${FAIL}"
  if [ "$FAIL" -gt 0 ]; then
    exit 2
  fi
}

main
