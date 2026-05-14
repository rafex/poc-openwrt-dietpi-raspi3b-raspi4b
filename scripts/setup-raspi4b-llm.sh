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
CUSTOM_MODEL_PATH=""

# ── Modelo preferido ───────────────────────────────────────────────────────────
# Qwen2.5-1.5B-Instruct-Q4_K_M: mejor español y razonamiento que 0.5B,
# ~16 tok/s en Pi 4B, cabe holgado en 4 GB RAM (~1.1 GB en disco).
MODEL_DIR="/opt/models"
MODEL_FILENAME="qwen2.5-1.5b-instruct-q4_k_m.gguf"
MODEL_HF_REPO="Qwen/Qwen2.5-1.5B-Instruct-GGUF"
MODEL_HF_URL="https://huggingface.co/${MODEL_HF_REPO}/resolve/main/${MODEL_FILENAME}"

parse_common_flags "$@"
ARGS=("${REM_ARGS[@]}")
REM_ARGS=()
for a in "${ARGS[@]}"; do
  case "$a" in
    --model-path=*)
      CUSTOM_MODEL_PATH="${a#--model-path=}"
      ;;
    --model-path)
      die "Usa --model-path=/ruta/al/modelo.gguf"
      ;;
    *)
      REM_ARGS+=("$a")
      ;;
  esac
done
init_log_dir "llm"
need_root

[ "${#REM_ARGS[@]}" -eq 0 ] || die "Argumentos no soportados: ${REM_ARGS[*]}"

log_info "--- setup-raspi4b-llm ---"
ensure_cmd bash curl

# ── Descarga del modelo si no existe ─────────────────────────────────────────
# Se omite si --model-path fue especificado (el usuario ya tiene el modelo).
# Descarga a /opt/models/ con curl (sigue redirects de HuggingFace → CDN).
# Si huggingface-cli está disponible lo usa como alternativa más robusta.
download_model_if_needed() {
  [ -n "$CUSTOM_MODEL_PATH" ] && return 0   # el usuario indicó un modelo propio

  local dest="${MODEL_DIR}/${MODEL_FILENAME}"

  # Ya descargado
  if [ -f "$dest" ]; then
    log_ok "Modelo ya existe: $dest ($(du -sh "$dest" 2>/dev/null | cut -f1))"
    return 0
  fi

  # Buscar en HF cache (snapshot con symlink nombrado)
  local hf_snap
  hf_snap="$(find /root /home -maxdepth 14 -type f \
    -path "*/models--Qwen--Qwen2.5-1.5B-Instruct-GGUF/snapshots/*/${MODEL_FILENAME}" \
    2>/dev/null | head -1)"
  if [ -n "$hf_snap" ]; then
    log_ok "Modelo encontrado en HF cache: $hf_snap"
    return 0
  fi

  log_info "Descargando ${MODEL_FILENAME} (~1.1 GB) — puede tardar varios minutos..."
  run_cmd mkdir -p "$MODEL_DIR"

  if $DRY_RUN; then
    log_info "[dry-run] curl -fL $MODEL_HF_URL → $dest"
    return 0
  fi

  if command -v huggingface-cli >/dev/null 2>&1; then
    log_info "Usando huggingface-cli..."
    huggingface-cli download "$MODEL_HF_REPO" "$MODEL_FILENAME" \
      --local-dir "$MODEL_DIR" --local-dir-use-symlinks False \
      && log_ok "Descarga completada: $dest" \
      || die "huggingface-cli falló. Prueba manualmente: wget -O $dest $MODEL_HF_URL"
  else
    log_info "Usando curl (huggingface-cli no disponible)..."
    curl -fL --progress-bar \
      -o "${dest}.tmp" "$MODEL_HF_URL" \
      && mv "${dest}.tmp" "$dest" \
      && log_ok "Descarga completada: $dest ($(du -sh "$dest" | cut -f1))" \
      || { rm -f "${dest}.tmp"; die "curl falló. Prueba: wget -O $dest $MODEL_HF_URL"; }
  fi
}

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
  if [ -n "$CUSTOM_MODEL_PATH" ]; then
    if [ -f "$CUSTOM_MODEL_PATH" ]; then
      realpath "$CUSTOM_MODEL_PATH" 2>/dev/null || readlink -f "$CUSTOM_MODEL_PATH" || echo "$CUSTOM_MODEL_PATH"
      return 0
    fi
    die "Modelo no encontrado en --model-path: $CUSTOM_MODEL_PATH"
  fi

  local f
  # Prioridad: 1.5B → 0.5B → TinyLlama (último recurso)
  for f in \
    /opt/models/qwen2.5-1.5b*.gguf \
    /opt/models/Qwen2.5-1.5B*.gguf \
    /opt/models/*qwen*1.5*.gguf \
    /opt/llama.cpp/models/qwen2.5-1.5b*.gguf \
    /opt/llama.cpp/models/*qwen*1.5*.gguf \
    /root/.cache/huggingface/hub/models--Qwen--Qwen2.5-1.5B-Instruct-GGUF/snapshots/*/*.gguf \
    /home/*/.cache/huggingface/hub/models--Qwen--Qwen2.5-1.5B-Instruct-GGUF/snapshots/*/*.gguf \
    /opt/models/qwen2.5-0.5b*.gguf \
    /opt/models/Qwen2.5-0.5B*.gguf \
    /opt/models/*qwen*0.5*.gguf \
    /opt/llama.cpp/models/qwen2.5-0.5b*.gguf \
    /opt/llama.cpp/models/*qwen*0.5*.gguf \
    /root/.cache/huggingface/hub/models--Qwen--Qwen2.5-0.5B-Instruct-GGUF/snapshots/*/*.gguf \
    /home/*/.cache/huggingface/hub/models--Qwen--Qwen2.5-0.5B-Instruct-GGUF/snapshots/*/*.gguf \
    /opt/models/tinyllama*.gguf \
    /opt/llama.cpp/models/tinyllama*.gguf \
    /root/.cache/huggingface/hub/models--*/snapshots/*/*.gguf \
    /home/*/.cache/huggingface/hub/models--*/snapshots/*/*.gguf \
    /root/.cache/llama.cpp/*/*.gguf \
    /home/*/.cache/llama.cpp/*/*.gguf; do
    [ -f "$f" ] && { realpath "$f" 2>/dev/null || readlink -f "$f" || echo "$f"; return 0; }
  done

  # Fallback robusto: find en rutas típicas (1.5B primero, luego 0.5B, luego tinyllama)
  if command -v find >/dev/null 2>&1; then
    f="$(find /home /root /opt -maxdepth 14 -type f \
      \( -iname '*qwen*1.5*.gguf' -o -iname '*qwen*0.5*.gguf' -o -iname '*tinyllama*.gguf' \) \
      2>/dev/null | head -1)"
    [ -n "$f" ] && { realpath "$f" 2>/dev/null || readlink -f "$f" || echo "$f"; return 0; }
  fi
  return 1
}

LLAMA_BIN="$(find_llama_bin || true)"
[ -n "$LLAMA_BIN" ] || die "No se encontró binario llama-server"

# Descargar Qwen2.5-1.5B-Instruct-Q4_K_M si no hay ningún modelo disponible
download_model_if_needed

MODEL_PATH="$(find_model || true)"
[ -n "$MODEL_PATH" ] || die "No se encontró modelo .gguf.
Sugerencia: usa --model-path=/ruta/al/modelo.gguf
  o deja que el script lo descargue en ${MODEL_DIR}/${MODEL_FILENAME}"

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
CTX_SIZE=2048
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
