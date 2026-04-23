#!/bin/bash
# Instala/configura solo llama.cpp server en Raspi4B.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib/raspi4b-common.sh
. "$SCRIPT_DIR/lib/raspi4b-common.sh"

LLAMA_PORT=8081
LLAMA_SERVICE="/etc/init.d/llama-server"
LLAMA_PIDFILE="/var/run/llama-server.pid"
LLAMA_LOGFILE="/var/log/llama-server.log"

parse_common_flags "$@"
init_log_dir "llm"
need_root

[ "${#REM_ARGS[@]}" -eq 0 ] || die "Argumentos no soportados: ${REM_ARGS[*]}"

log_info "--- setup-raspi4b-llm ---"
ensure_cmd bash curl

find_llama_bin() {
  local c
  for c in \
    /usr/local/bin/llama-server \
    /usr/bin/llama-server \
    /opt/llama.cpp/llama-server \
    /home/dietpi/llama.cpp/llama-server \
    /root/llama.cpp/llama-server; do
    [ -x "$c" ] && { echo "$c"; return 0; }
  done
  return 1
}

find_model() {
  local f
  for f in \
    /opt/models/qwen2.5-0.5b*.gguf \
    /opt/models/Qwen2.5-0.5B*.gguf \
    /opt/llama.cpp/models/qwen2.5-0.5b*.gguf \
    /opt/models/tinyllama*.gguf \
    /opt/llama.cpp/models/tinyllama*.gguf \
    /root/.cache/llama.cpp/*/*.gguf \
    /home/dietpi/.cache/llama.cpp/*/*.gguf; do
    [ -f "$f" ] && { realpath "$f" 2>/dev/null || readlink -f "$f" || echo "$f"; return 0; }
  done
  return 1
}

LLAMA_BIN="$(find_llama_bin || true)"
[ -n "$LLAMA_BIN" ] || die "No se encontró binario llama-server"
MODEL_PATH="$(find_model || true)"
[ -n "$MODEL_PATH" ] || die "No se encontró modelo .gguf (Qwen2.5-0.5B o TinyLlama)"

log_ok "Binario: $LLAMA_BIN"
log_ok "Modelo : $MODEL_PATH"

if ! $ONLY_VERIFY; then
  if [ -f "$LLAMA_PIDFILE" ] && kill -0 "$(cat "$LLAMA_PIDFILE" 2>/dev/null)" 2>/dev/null; then
    run_cmd kill "$(cat "$LLAMA_PIDFILE")" || true
    run_cmd rm -f "$LLAMA_PIDFILE"
  fi

  if ! $DRY_RUN; then
    cat > "$LLAMA_SERVICE" <<SRV
#!/bin/sh
### BEGIN INIT INFO
# Provides:          llama-server
# Required-Start:    \$network \$remote_fs
# Required-Stop:     \$network
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: llama.cpp inference server
### END INIT INFO
DAEMON="$LLAMA_BIN"
MODEL="$MODEL_PATH"
PORT=$LLAMA_PORT
PIDFILE="$LLAMA_PIDFILE"
LOGFILE="$LLAMA_LOGFILE"
CTX_SIZE=4096
THREADS=4
N_PARALLEL=1
do_start() {
  if [ -f "\$PIDFILE" ] && kill -0 "\$(cat \$PIDFILE 2>/dev/null)" 2>/dev/null; then
    echo "llama-server ya está corriendo"
    return 0
  fi
  \$DAEMON --model "\$MODEL" --port \$PORT --host 0.0.0.0 --ctx-size \$CTX_SIZE --threads \$THREADS --parallel \$N_PARALLEL >> "\$LOGFILE" 2>&1 &
  echo \$! > "\$PIDFILE"
  sleep 3
}
do_stop() {
  if [ -f "\$PIDFILE" ] && kill -0 "\$(cat \$PIDFILE 2>/dev/null)" 2>/dev/null; then
    kill "\$(cat \$PIDFILE)" || true
  fi
  rm -f "\$PIDFILE"
}
case "\$1" in
  start) do_start ;;
  stop) do_stop ;;
  restart) do_stop; sleep 1; do_start ;;
  status) [ -f "\$PIDFILE" ] && kill -0 "\$(cat \$PIDFILE 2>/dev/null)" 2>/dev/null ;;
  *) echo "Uso: \$0 {start|stop|restart|status}"; exit 1 ;;
esac
SRV
  else
    log_info "[dry-run] escribir $LLAMA_SERVICE"
  fi

  run_cmd chmod +x "$LLAMA_SERVICE"
  run_cmd update-rc.d llama-server defaults || true

  if ! $DRY_RUN; then
    cat > /usr/local/bin/llama-watchdog <<W
#!/bin/sh
PIDFILE="$LLAMA_PIDFILE"
SERVICE="$LLAMA_SERVICE"
LOGFILE="$LLAMA_LOGFILE"
if ! [ -f "\$PIDFILE" ] || ! kill -0 "\$(cat \$PIDFILE 2>/dev/null)" 2>/dev/null; then
  echo "\$(date '+%Y-%m-%d %T') [watchdog] relanzando" >> "\$LOGFILE"
  "\$SERVICE" start >> "\$LOGFILE" 2>&1
fi
W
    chmod 755 /usr/local/bin/llama-watchdog
    echo "* * * * * root /usr/local/bin/llama-watchdog" > /etc/cron.d/llama-watchdog
    chmod 644 /etc/cron.d/llama-watchdog
  else
    log_info "[dry-run] instalar watchdog cron"
  fi

  run_cmd "$LLAMA_SERVICE" restart
fi

if $DRY_RUN; then
  log_ok "Dry-run completado"
  exit 0
fi

WAIT=0
while ! curl -sf "http://127.0.0.1:$LLAMA_PORT/health" >/dev/null 2>&1; do
  sleep 2
  WAIT=$((WAIT + 2))
  [ "$WAIT" -ge 60 ] && die "llama-server no respondió en 60s"
done

log_ok "llama-server activo en :$LLAMA_PORT"
log_ok "setup-raspi4b-llm completado"
