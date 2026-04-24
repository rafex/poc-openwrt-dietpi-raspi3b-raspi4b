#!/bin/sh
# llm-status.sh — Estado detallado de llama-server y modelo cargado.
# Uso:
#   sh scripts/llm-status.sh
set -e

LLAMA_SERVICE="/etc/init.d/llama-server"
LLAMA_PIDFILE="/var/run/llama-server.pid"
LLAMA_PORT="${LLAMA_PORT:-8081}"

log_info()  { printf '[INFO]  %s\n' "$*"; }
log_ok()    { printf '[OK]    %s\n' "$*"; }
log_warn()  { printf '[WARN]  %s\n' "$*"; }
log_error() { printf '[ERROR] %s\n' "$*" >&2; }

get_pid() {
  if [ -f "$LLAMA_PIDFILE" ]; then
    pid="$(cat "$LLAMA_PIDFILE" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      echo "$pid"
      return 0
    fi
  fi

  pid="$(ps w | awk '/[l]lama-server/{print $1; exit}')"
  [ -n "$pid" ] && { echo "$pid"; return 0; }
  return 1
}

get_model_from_proc() {
  pid="$1"
  [ -r "/proc/$pid/cmdline" ] || return 1

  model="$(tr '\000' '\n' < "/proc/$pid/cmdline" | awk 'prev=="--model"{print; exit}{prev=$0}')"
  [ -n "$model" ] && { echo "$model"; return 0; }

  model="$(tr '\000' '\n' < "/proc/$pid/cmdline" | sed -n 's/^--model=//p' | head -1)"
  [ -n "$model" ] && { echo "$model"; return 0; }
  return 1
}

get_model_from_service() {
  [ -f "$LLAMA_SERVICE" ] || return 1
  model="$(sed -n 's/^MODEL="\(.*\)"$/\1/p; s/^MODEL=\(.*\)$/\1/p' "$LLAMA_SERVICE" | head -1)"
  [ -n "$model" ] && { echo "$model"; return 0; }
  return 1
}

printf '\n'
log_info "Estado LLM detallado"

if [ -x "$LLAMA_SERVICE" ]; then
  log_ok "Servicio detectado: $LLAMA_SERVICE"
else
  log_warn "Servicio no encontrado: $LLAMA_SERVICE"
fi

PID="$(get_pid || true)"
if [ -n "$PID" ]; then
  log_ok "Proceso corriendo (PID $PID)"
else
  log_warn "Proceso detenido"
fi

if command -v curl >/dev/null 2>&1; then
  HEALTH_CODE="$(curl -s -o /tmp/llm-health.$$ -w '%{http_code}' "http://127.0.0.1:${LLAMA_PORT}/health" 2>/dev/null || echo 000)"
  if [ "$HEALTH_CODE" = "200" ]; then
    log_ok "HTTP /health responde en :$LLAMA_PORT"
    HEALTH_BODY="$(cat /tmp/llm-health.$$ 2>/dev/null || true)"
    [ -n "$HEALTH_BODY" ] && log_info "Health: $HEALTH_BODY"
  else
    log_warn "HTTP /health no responde en :$LLAMA_PORT (HTTP $HEALTH_CODE)"
  fi
  rm -f /tmp/llm-health.$$ >/dev/null 2>&1 || true
else
  log_warn "curl no está disponible; se omite health check"
fi

MODEL_RUNNING=""
MODEL_CONFIG=""

if [ -n "$PID" ]; then
  MODEL_RUNNING="$(get_model_from_proc "$PID" || true)"
fi
MODEL_CONFIG="$(get_model_from_service || true)"

if [ -n "$MODEL_RUNNING" ]; then
  log_ok "Modelo en ejecución: $MODEL_RUNNING"
elif [ -n "$MODEL_CONFIG" ]; then
  log_warn "No se pudo leer modelo desde el proceso; modelo configurado: $MODEL_CONFIG"
else
  log_error "No se pudo determinar el modelo"
fi

if [ -n "$MODEL_CONFIG" ]; then
  log_info "Modelo configurado en servicio: $MODEL_CONFIG"
fi

if [ -n "$PID" ]; then
  CMDLINE="$(tr '\000' ' ' < "/proc/$PID/cmdline" 2>/dev/null || true)"
  [ -n "$CMDLINE" ] && log_info "Cmdline: $CMDLINE"
fi
