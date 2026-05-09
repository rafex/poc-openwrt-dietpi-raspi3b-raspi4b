#!/bin/bash
# llama-curl-check.sh
#
# Smoke tests HTTP para llama-server.
# Ejecuta pruebas de:
#   - /health
#   - /props
#   - /metrics
#   - /tokenize
#   - /completion
#   - /embedding
#
# Uso:
#   bash scripts/llama-curl-check.sh
#   bash scripts/llama-curl-check.sh --host 127.0.0.1 --port 8081
#   bash scripts/llama-curl-check.sh --timeout 12

set -u

HOST="127.0.0.1"
PORT="8081"
TIMEOUT="10"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="${2:-}"; shift 2 ;;
    --port) PORT="${2:-}"; shift 2 ;;
    --timeout) TIMEOUT="${2:-}"; shift 2 ;;
    -h|--help)
      cat <<EOF
Uso: $0 [--host IP] [--port N] [--timeout SEG]

Ejemplo:
  bash scripts/llama-curl-check.sh --host 127.0.0.1 --port 8081 --timeout 10
EOF
      exit 0
      ;;
    *)
      echo "[ERROR] Parámetro no reconocido: $1"
      exit 1
      ;;
  esac
done

BASE_URL="http://${HOST}:${PORT}"
FAILS=0

ok()   { printf "[OK]    %s\n" "$*"; }
warn() { printf "[WARN]  %s\n" "$*"; }
info() { printf "[INFO]  %s\n" "$*"; }

run_get() {
  local name="$1"
  local path="$2"
  local out code

  out="$(mktemp)"
  code="$(curl -sS -o "$out" -w '%{http_code}' \
    --connect-timeout 3 --max-time "$TIMEOUT" \
    "${BASE_URL}${path}" 2>/dev/null || echo "000")"

  if [[ "$code" == "200" ]]; then
    ok "${name} ${path} -> HTTP 200"
    head -c 400 "$out" | sed 's/^/        /'
    [[ -s "$out" ]] && echo
  else
    warn "${name} ${path} -> HTTP ${code}"
    head -c 400 "$out" | sed 's/^/        /'
    [[ -s "$out" ]] && echo
    FAILS=$((FAILS + 1))
  fi
  rm -f "$out"
}

run_post() {
  local name="$1"
  local path="$2"
  local payload="$3"
  local out code

  out="$(mktemp)"
  code="$(curl -sS -o "$out" -w '%{http_code}' \
    --connect-timeout 3 --max-time "$TIMEOUT" \
    -H 'Content-Type: application/json' \
    -d "$payload" \
    "${BASE_URL}${path}" 2>/dev/null || echo "000")"

  if [[ "$code" == "200" ]]; then
    ok "${name} ${path} -> HTTP 200"
    head -c 500 "$out" | sed 's/^/        /'
    [[ -s "$out" ]] && echo
  else
    warn "${name} ${path} -> HTTP ${code}"
    head -c 500 "$out" | sed 's/^/        /'
    [[ -s "$out" ]] && echo
    FAILS=$((FAILS + 1))
  fi
  rm -f "$out"
}

info "=== llama-server curl checks ==="
info "Base URL: ${BASE_URL}"
info "Timeout:  ${TIMEOUT}s"
echo

run_get  "Health"   "/health"
run_get  "Props"    "/props"
run_get  "Metrics"  "/metrics"
run_post "Tokenize" "/tokenize"   '{"content":"hola mundo"}'
run_post "Complete" "/completion" '{"prompt":"Di hola en una linea.","n_predict":32,"temperature":0.2}'
run_post "Embedding" "/embedding" '{"content":"seguridad wifi"}'

echo
if [[ "$FAILS" -eq 0 ]]; then
  ok "Todas las pruebas pasaron."
  exit 0
fi

warn "Pruebas con fallo: ${FAILS}"
warn "Nota: algunos endpoints pueden no existir según versión/configuración de llama-server."
exit 1
