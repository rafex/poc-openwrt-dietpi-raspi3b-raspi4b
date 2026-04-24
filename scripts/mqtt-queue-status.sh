#!/bin/bash
# mqtt-queue-status.sh — Estado detallado de Mosquitto + cola del ai-analyzer.
# Uso:
#   bash scripts/mqtt-queue-status.sh
#   bash scripts/mqtt-queue-status.sh --watch
#   bash scripts/mqtt-queue-status.sh --watch --interval 5

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

AI_HOST="${AI_IP:-192.168.1.167}"
ANALYZER_BASE_URL="${ANALYZER_BASE_URL:-http://${AI_HOST}}"
MQTT_HOST="${MQTT_HOST:-127.0.0.1}"
MQTT_PORT="${MQTT_PORT:-1883}"
WATCH=false
INTERVAL=10

while [ $# -gt 0 ]; do
  case "$1" in
    --watch|-w)
      WATCH=true
      ;;
    --interval|-i)
      shift
      INTERVAL="${1:-10}"
      ;;
    --help|-h)
      cat <<USAGE
Uso: $0 [--watch] [--interval N]

Opciones:
  --watch, -w        Refresca continuamente
  --interval, -i N   Segundos entre refrescos (default: 10)

Vars opcionales:
  ANALYZER_BASE_URL  (default: http://${AI_HOST})
  MQTT_HOST          (default: 127.0.0.1)
  MQTT_PORT          (default: 1883)
USAGE
      exit 0
      ;;
    *)
      die "Argumento no soportado: $1"
      ;;
  esac
  shift
done

is_int() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

json_get() {
  local json="$1"
  local key_path="$2"
  python3 - "$key_path" <<'PY' <<<"$json"
import json, sys
path = sys.argv[1].split('.')
try:
    data = json.load(sys.stdin)
except Exception:
    print("")
    raise SystemExit(0)
cur = data
for p in path:
    if isinstance(cur, dict):
        cur = cur.get(p)
    else:
        cur = None
        break
if cur is None:
    print("")
elif isinstance(cur, bool):
    print("true" if cur else "false")
else:
    print(cur)
PY
}

fmt_num() {
  local n="$1"
  if [ -z "$n" ]; then
    echo "0"
    return
  fi
  if is_int "$n"; then
    printf "%d" "$n"
  else
    echo "$n"
  fi
}

get_sys_snapshot() {
  if ! command -v mosquitto_sub >/dev/null 2>&1; then
    return 1
  fi
  mosquitto_sub -h "$MQTT_HOST" -p "$MQTT_PORT" -v -t '\$SYS/broker/#' -W 4 2>/dev/null | head -200
}

extract_topic_value() {
  local dump="$1"
  local topic="$2"
  awk -v t="$topic" '$1==t{ $1=""; sub(/^ /,""); print; exit }' <<<"$dump"
}

print_mosquitto_section() {
  echo
  log_info "=== Mosquitto ==="

  if [ -x /etc/init.d/mosquitto ]; then
    local st
    st="$(/etc/init.d/mosquitto status 2>&1 || true)"
    if echo "$st" | grep -Eiq 'running|start/running|active'; then
      log_ok "Servicio: arriba"
    else
      log_warn "Servicio: posible caída"
    fi
    echo "  status: ${st:-<sin salida>}"
  else
    log_warn "No existe /etc/init.d/mosquitto"
  fi

  local pids
  pids="$(pidof mosquitto 2>/dev/null || true)"
  if [ -n "$pids" ]; then
    log_ok "PID(s): $pids"
  else
    log_warn "No hay PID de mosquitto"
  fi

  if command -v ss >/dev/null 2>&1; then
    if ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq ":${MQTT_PORT}$"; then
      log_ok "Puerto ${MQTT_PORT}: LISTEN"
    else
      log_warn "Puerto ${MQTT_PORT}: no LISTEN"
    fi
  fi

  local sys_dump
  sys_dump="$(get_sys_snapshot || true)"
  if [ -n "$sys_dump" ]; then
    local c_conn c_subs m_recv m_sent m_stored b_recv b_sent
    c_conn="$(extract_topic_value "$sys_dump" '$SYS/broker/clients/connected')"
    c_subs="$(extract_topic_value "$sys_dump" '$SYS/broker/subscriptions/count')"
    m_recv="$(extract_topic_value "$sys_dump" '$SYS/broker/messages/received')"
    m_sent="$(extract_topic_value "$sys_dump" '$SYS/broker/messages/sent')"
    m_stored="$(extract_topic_value "$sys_dump" '$SYS/broker/messages/stored')"
    b_recv="$(extract_topic_value "$sys_dump" '$SYS/broker/load/bytes/received')"
    b_sent="$(extract_topic_value "$sys_dump" '$SYS/broker/load/bytes/sent')"

    echo "  clients_connected : ${c_conn:-n/a}"
    echo "  subscriptions     : ${c_subs:-n/a}"
    echo "  messages_received : ${m_recv:-n/a}"
    echo "  messages_sent     : ${m_sent:-n/a}"
    echo "  messages_stored   : ${m_stored:-n/a}"
    echo "  bytes_received    : ${b_recv:-n/a}"
    echo "  bytes_sent        : ${b_sent:-n/a}"
  else
    log_warn "No se pudieron leer métricas \$SYS (broker local o timeout)"
  fi
}

print_analyzer_section() {
  echo
  log_info "=== AI Analyzer Queue ==="

  local stats_url queue_url
  local stats_json queue_json
  stats_url="${ANALYZER_BASE_URL}/api/stats"
  queue_url="${ANALYZER_BASE_URL}/api/queue"

  stats_json="$(curl -sf --max-time 6 "$stats_url" 2>/dev/null || true)"
  queue_json="$(curl -sf --max-time 6 "$queue_url" 2>/dev/null || true)"

  if [ -z "$stats_json" ] && [ -z "$queue_json" ]; then
    log_error "No se pudo consultar analyzer en ${ANALYZER_BASE_URL}"
    return
  fi

  local pending processing done error queue_size
  local batches_ok batches_err batches_recv llama_calls llama_err mqtt_conn started_at

  if [ -n "$queue_json" ]; then
    pending="$(json_get "$queue_json" pending)"
    processing="$(json_get "$queue_json" processing)"
    done="$(json_get "$queue_json" done)"
    error="$(json_get "$queue_json" error)"
    queue_size="$(json_get "$queue_json" queue_size)"
  fi

  if [ -n "$stats_json" ]; then
    batches_recv="$(json_get "$stats_json" batches_received)"
    batches_ok="$(json_get "$stats_json" analyses_ok)"
    batches_err="$(json_get "$stats_json" analyses_error)"
    llama_calls="$(json_get "$stats_json" llama_calls)"
    llama_err="$(json_get "$stats_json" llama_errors)"
    mqtt_conn="$(json_get "$stats_json" mqtt_connected)"
    started_at="$(json_get "$stats_json" started_at)"

    if [ -z "$pending" ]; then pending="$(json_get "$stats_json" queue.pending)"; fi
    if [ -z "$processing" ]; then processing="$(json_get "$stats_json" queue.processing)"; fi
    if [ -z "$done" ]; then done="$(json_get "$stats_json" queue.done)"; fi
    if [ -z "$error" ]; then error="$(json_get "$stats_json" queue.error)"; fi
    if [ -z "$queue_size" ]; then queue_size="$(json_get "$stats_json" queue.queue_size)"; fi
  fi

  echo "  analyzer_url      : $ANALYZER_BASE_URL"
  echo "  mqtt_connected    : ${mqtt_conn:-unknown}"
  echo "  started_at        : ${started_at:-unknown}"
  echo "  queue_pending     : $(fmt_num "${pending:-0}")"
  echo "  queue_processing  : $(fmt_num "${processing:-0}")"
  echo "  queue_in_memory   : $(fmt_num "${queue_size:-0}")"
  echo "  processed_ok      : $(fmt_num "${done:-${batches_ok:-0}}")"
  echo "  processed_error   : $(fmt_num "${error:-${batches_err:-0}}")"
  echo "  batches_received  : $(fmt_num "${batches_recv:-0}")"
  echo "  llama_calls       : $(fmt_num "${llama_calls:-0}")"
  echo "  llama_errors      : $(fmt_num "${llama_err:-0}")"

  local ok_n err_n total_n
  ok_n="${done:-${batches_ok:-0}}"
  err_n="${error:-${batches_err:-0}}"
  if is_int "$ok_n" && is_int "$err_n"; then
    total_n=$((ok_n + err_n))
    if [ "$total_n" -gt 0 ]; then
      local success_pct
      success_pct=$((100 * ok_n / total_n))
      echo "  success_rate      : ${success_pct}% (${ok_n}/${total_n})"
    fi
  fi
}

print_k8s_section() {
  if ! command -v kubectl >/dev/null 2>&1; then
    return
  fi

  echo
  log_info "=== k3s / ai-analyzer pod ==="

  local pod_line pod_name pod_phase pod_ready
  pod_line="$(kubectl get pods -l app=ai-analyzer -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\t"}{.status.containerStatuses[0].ready}{"\n"}{end}' 2>/dev/null | head -1)"
  if [ -n "$pod_line" ]; then
    pod_name="$(awk '{print $1}' <<<"$pod_line")"
    pod_phase="$(awk '{print $2}' <<<"$pod_line")"
    pod_ready="$(awk '{print $3}' <<<"$pod_line")"
    echo "  pod_name          : ${pod_name:-?}"
    echo "  pod_phase         : ${pod_phase:-?}"
    echo "  pod_ready         : ${pod_ready:-?}"

    local recent_logs err_count warn_count
    recent_logs="$(kubectl logs "$pod_name" --since=10m 2>/dev/null || true)"
    if [ -n "$recent_logs" ]; then
      err_count="$(printf '%s\n' "$recent_logs" | rg -ic "error|traceback|exception" || true)"
      warn_count="$(printf '%s\n' "$recent_logs" | rg -ic "warn|warning" || true)"
      echo "  logs_10m_errors   : ${err_count:-0}"
      echo "  logs_10m_warnings : ${warn_count:-0}"
    fi
  else
    log_warn "No se encontró pod app=ai-analyzer"
  fi
}

print_sqlite_section() {
  local db
  for db in /opt/analyzer/data/sensor.db /data/sensor.db; do
    [ -f "$db" ] || continue
    echo
    log_info "=== SQLite (${db}) ==="
    if ! command -v sqlite3 >/dev/null 2>&1; then
      log_warn "sqlite3 no instalado; omitiendo detalle"
      return
    fi

    local q
    q="SELECT status,COUNT(*) FROM batches GROUP BY status ORDER BY status;"
    sqlite3 "$db" "$q" 2>/dev/null | sed 's/|/ = /g' | sed 's/^/  /' || true

    local last_batch
    last_batch="$(sqlite3 "$db" "SELECT IFNULL(MAX(id),0) FROM batches;" 2>/dev/null || echo 0)"
    echo "  last_batch_id     : ${last_batch:-0}"
    return
  done
}

run_once() {
  echo
  echo "============================================================"
  echo " MQTT + Queue Status  |  $(date '+%Y-%m-%d %H:%M:%S')"
  echo "============================================================"

  print_mosquitto_section
  print_analyzer_section
  print_k8s_section
  print_sqlite_section
}

if $WATCH; then
  is_int "$INTERVAL" || die "--interval debe ser entero"
  while true; do
    run_once
    sleep "$INTERVAL"
  done
else
  run_once
fi
