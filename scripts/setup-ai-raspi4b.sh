#!/bin/bash
# setup-ai-raspi4b.sh — Instalación del stack IA en Raspi 4B
#
# Ejecutar en: Raspberry Pi 4B (192.168.1.167) con DietPi + k3s
# Idempotente: Sí
#
# Qué hace:
#   A) Localiza llama.cpp y el modelo TinyLlama
#   B) Instala llama.cpp server como servicio init.d en puerto 8081
#   C) Construye imagen Docker ai-analyzer con podman
#   D) Importa la imagen a k3s
#   E) kubectl apply: configmaps + deployments + services + ingresses
#   F) Verifica todos los pods y endpoints
#
# Uso:
#   bash scripts/setup-ai-raspi4b.sh
#   bash scripts/setup-ai-raspi4b.sh --no-build    # omitir build de imagen
#   bash scripts/setup-ai-raspi4b.sh --no-llama    # omitir configuración llama.cpp

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
K8S_DIR="$REPO_DIR/k8s"

# ─── Colores ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'; BOLD='\033[1m'
info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()   { error "$*"; exit 1; }
step()  { echo -e "\n${BOLD}── $* ──${NC}"; }

# ─── Argumentos ───────────────────────────────────────────────────────────────
NO_BUILD=false
NO_LLAMA=false

for arg in "$@"; do
    case "$arg" in
        --no-build) NO_BUILD=true ;;
        --no-llama) NO_LLAMA=true ;;
        --help|-h)
            echo "Uso: $0 [--no-build] [--no-llama]"
            exit 0
            ;;
        *) die "Argumento desconocido: $arg" ;;
    esac
done

# ─── Constantes ───────────────────────────────────────────────────────────────
LLAMA_PORT=8081
LLAMA_SERVICE="/etc/init.d/llama-server"
LLAMA_PIDFILE="/var/run/llama-server.pid"
LLAMA_LOGFILE="/var/log/llama-server.log"

# ─── Verificaciones previas ───────────────────────────────────────────────────
step "Pre-flight checks"

if [ "$EUID" -ne 0 ]; then
    die "Ejecutar como root: sudo bash $0"
fi

if ! command -v kubectl &>/dev/null; then
    die "kubectl no encontrado — ¿está k3s instalado?"
fi

if ! kubectl get nodes &>/dev/null; then
    info "k3s no está corriendo — intentando iniciar..."
    /etc/init.d/k3s start 2>/dev/null || service k3s start 2>/dev/null || true
    sleep 15
    kubectl get nodes || die "No se pudo arrancar k3s"
fi

ok "k3s corriendo: $(kubectl get nodes --no-headers | awk '{print $1,$2}')"

if ! command -v podman &>/dev/null; then
    info "Instalando podman..."
    apt-get install -y --no-install-recommends podman
fi
ok "podman: $(podman --version)"

# ─── A) Localizar llama.cpp y modelo ─────────────────────────────────────────
step "A) Localizando llama.cpp y modelo TinyLlama"

if $NO_LLAMA; then
    info "Saltando configuración de llama.cpp (--no-llama)"
else
    # Buscar el binario del servidor
    LLAMA_BIN=""
    for candidate in \
        /usr/local/bin/llama-server \
        /usr/bin/llama-server \
        /opt/llama.cpp/llama-server \
        /opt/llama.cpp/server \
        /home/dietpi/llama.cpp/llama-server \
        /home/dietpi/llama.cpp/server \
        /root/llama.cpp/llama-server \
        /root/llama.cpp/server; do
        if [ -x "$candidate" ]; then
            LLAMA_BIN="$candidate"
            break
        fi
    done

    if [ -z "$LLAMA_BIN" ]; then
        warn "No se encontró el binario de llama.cpp en las rutas habituales."
        warn "Buscando en todo el sistema (puede tardar)..."
        LLAMA_BIN=$(find / -name "llama-server" -o -name "server" -path "*/llama*" \
            2>/dev/null | grep -v proc | head -1)
    fi

    if [ -z "$LLAMA_BIN" ] || [ ! -x "$LLAMA_BIN" ]; then
        error "No se encontró el binario de llama.cpp"
        error "Compila llama.cpp primero:"
        error "  git clone https://github.com/ggerganov/llama.cpp /opt/llama.cpp"
        error "  cd /opt/llama.cpp && cmake -B build && cmake --build build -j4"
        die "Instala llama.cpp antes de continuar, o usa --no-llama"
    fi
    ok "llama.cpp binario: $LLAMA_BIN"

    # Buscar modelo GGUF de TinyLlama
    LLAMA_MODEL=""
    for candidate in \
        /opt/models/tinyllama*.gguf \
        /opt/llama.cpp/models/tinyllama*.gguf \
        /home/dietpi/models/tinyllama*.gguf \
        /home/dietpi/llama.cpp/models/tinyllama*.gguf \
        /root/models/tinyllama*.gguf \
        /var/lib/llama/tinyllama*.gguf; do
        # Usar glob expansion
        for f in $candidate; do
            if [ -f "$f" ]; then
                LLAMA_MODEL="$f"
                break 2
            fi
        done
    done

    if [ -z "$LLAMA_MODEL" ]; then
        warn "No se encontró modelo TinyLlama .gguf en rutas habituales."
        warn "Buscando en todo el sistema..."
        LLAMA_MODEL=$(find / -name "tinyllama*.gguf" -o -name "TinyLlama*.gguf" \
            2>/dev/null | grep -v proc | head -1)
    fi

    if [ -z "$LLAMA_MODEL" ] || [ ! -f "$LLAMA_MODEL" ]; then
        error "No se encontró el modelo TinyLlama (.gguf)"
        error "Descárgalo con:"
        error "  mkdir -p /opt/models"
        error "  wget -O /opt/models/tinyllama-1.1b-chat-q4.gguf \\"
        error "    https://huggingface.co/TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF/resolve/main/tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf"
        die "Descarga el modelo antes de continuar"
    fi

    # Resolver symlinks — HuggingFace cache usa symlinks; llama-server necesita el path real
    LLAMA_MODEL_REAL=$(realpath "$LLAMA_MODEL" 2>/dev/null || readlink -f "$LLAMA_MODEL")
    MODEL_SIZE=$(stat -c%s "$LLAMA_MODEL_REAL" 2>/dev/null || echo 0)
    if [ "$MODEL_SIZE" -lt 100000000 ]; then
        warn "El archivo del modelo parece muy pequeño ($(du -h "$LLAMA_MODEL_REAL" | cut -f1))"
        warn "Puede ser un symlink roto o descarga incompleta"
        warn "Path real: $LLAMA_MODEL_REAL"
    fi
    LLAMA_MODEL="$LLAMA_MODEL_REAL"
    ok "Modelo: $LLAMA_MODEL ($(du -h "$LLAMA_MODEL" | cut -f1))"
fi

# ─── B) Servicio llama.cpp server ────────────────────────────────────────────
step "B) Configurando servicio llama-server en puerto $LLAMA_PORT"

if $NO_LLAMA; then
    info "Saltando (--no-llama)"
else
    # Detener si ya corre
    if [ -f "$LLAMA_PIDFILE" ] && kill -0 "$(cat "$LLAMA_PIDFILE")" 2>/dev/null; then
        info "llama-server ya corre — reiniciando..."
        kill "$(cat "$LLAMA_PIDFILE")" && sleep 2 || true
        rm -f "$LLAMA_PIDFILE"
    fi

    cat > "$LLAMA_SERVICE" << EOF
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
MODEL="$LLAMA_MODEL"
PORT=$LLAMA_PORT
PIDFILE="$LLAMA_PIDFILE"
LOGFILE="$LLAMA_LOGFILE"

# Parámetros del modelo (ajustar según RAM disponible)
# -c: context size  -t: threads
# NOTA: --n-parallel, --n-predict y --log-disable no son flags válidos
# en versiones recientes de llama.cpp — se gestionan automáticamente.
CTX_SIZE=2048
THREADS=4

do_start() {
    if [ -f "\$PIDFILE" ] && kill -0 "\$(cat \$PIDFILE)" 2>/dev/null; then
        echo "llama-server ya está corriendo (PID \$(cat \$PIDFILE))"
        return 0
    fi
    echo "Iniciando llama-server en :\$PORT (modelo: \$MODEL)..."
    \$DAEMON \\
        --model "\$MODEL" \\
        --port \$PORT \\
        --host 0.0.0.0 \\
        --ctx-size \$CTX_SIZE \\
        --threads \$THREADS \\
        >> "\$LOGFILE" 2>&1 &
    echo \$! > "\$PIDFILE"
    sleep 5
    if kill -0 "\$(cat \$PIDFILE)" 2>/dev/null; then
        echo "llama-server iniciado (PID \$(cat \$PIDFILE)) en :\$PORT"
    else
        echo "ERROR: llama-server no arrancó — revisa \$LOGFILE"
        cat "\$LOGFILE" | tail -5
        return 1
    fi
}

do_stop() {
    if [ ! -f "\$PIDFILE" ] || ! kill -0 "\$(cat \$PIDFILE)" 2>/dev/null; then
        echo "llama-server no está corriendo"
        rm -f "\$PIDFILE"
        return 0
    fi
    echo "Deteniendo llama-server (PID \$(cat \$PIDFILE))..."
    kill "\$(cat \$PIDFILE)"
    sleep 2
    rm -f "\$PIDFILE"
    echo "llama-server detenido"
}

do_status() {
    if [ -f "\$PIDFILE" ] && kill -0 "\$(cat \$PIDFILE)" 2>/dev/null; then
        echo "llama-server corriendo (PID \$(cat \$PIDFILE)) en :\$PORT"
        echo ""
        echo "=== Últimas 20 líneas de log ==="
        tail -20 "\$LOGFILE" 2>/dev/null
    else
        echo "llama-server NO está corriendo"
        return 1
    fi
}

case "\$1" in
    start)   do_start   ;;
    stop)    do_stop    ;;
    restart) do_stop; sleep 1; do_start ;;
    status)  do_status  ;;
    *)
        echo "Uso: \$0 {start|stop|restart|status}"
        exit 1
        ;;
esac
exit 0
EOF
    chmod +x "$LLAMA_SERVICE"
    ok "Servicio llama-server instalado en $LLAMA_SERVICE"

    # Habilitar en arranque
    if command -v update-rc.d &>/dev/null; then
        update-rc.d llama-server defaults
        ok "llama-server habilitado en arranque"
    fi

    # Iniciar llama-server
    info "Iniciando llama-server (puede tardar mientras carga el modelo)..."
    "$LLAMA_SERVICE" start && ok "llama-server iniciado" || warn "Error iniciando llama-server"

    # Esperar hasta 60s a que el servidor esté listo
    info "Esperando que llama.cpp server responda en :$LLAMA_PORT..."
    WAIT=0
    while ! curl -sf "http://127.0.0.1:$LLAMA_PORT/health" &>/dev/null; do
        sleep 3; WAIT=$((WAIT + 3))
        if [ $WAIT -ge 60 ]; then
            warn "llama.cpp server no responde después de ${WAIT}s — continúa de todas formas"
            break
        fi
        echo -n "."
    done
    echo ""
    if curl -sf "http://127.0.0.1:$LLAMA_PORT/health" &>/dev/null; then
        ok "llama.cpp server responde en :$LLAMA_PORT"
    fi
fi

# ─── C) Build imagen ai-analyzer ──────────────────────────────────────────────
step "C) Construyendo imagen ai-analyzer"

if $NO_BUILD; then
    info "Saltando build (--no-build)"
else
    info "Build de ai-analyzer con podman..."
    # --cgroup-manager=cgroupfs necesario en DietPi (no usa systemd como PID 1)
    # La imagen usa python:3.11-alpine (apk, sin dependencias de sd-bus)
    podman build \
        --cgroup-manager=cgroupfs \
        --platform linux/arm64 \
        -t localhost/ai-analyzer:latest \
        "$REPO_DIR/backend/ai-analyzer/"
    ok "Imagen ai-analyzer construida"
fi

# ─── D) Importar imagen a k3s ─────────────────────────────────────────────────
step "D) Importando imagen a k3s"

if $NO_BUILD; then
    info "Saltando importación (--no-build)"
else
    info "Exportando e importando imagen..."
    podman save localhost/ai-analyzer:latest | k3s ctr images import -
    ok "Imagen importada a k3s"
    k3s ctr images list | grep ai-analyzer | head -2
fi

# ─── E) kubectl apply ─────────────────────────────────────────────────────────
step "E) Aplicando manifiestos k8s"

# ai-analyzer (incluye /dashboard y /terminal — HTML servido desde el mismo pod)
info "Aplicando ai-analyzer..."
kubectl apply -f "$K8S_DIR/ai-analyzer-deployment.yaml"
kubectl apply -f "$K8S_DIR/ai-analyzer-svc.yaml"
kubectl apply -f "$K8S_DIR/ai-analyzer-ingress.yaml"
ok "ai-analyzer aplicado (con rutas /dashboard y /terminal integradas)"

# Limpiar recursos del dashboard separado si existían de una instalación anterior
for res in deployment/dashboard service/dashboard ingress/dashboard configmap/dashboard-nginx-conf; do
    kubectl delete $res --ignore-not-found=true 2>/dev/null && \
        info "Recurso legacy eliminado: $res" || true
done

# Rollout restart si la imagen fue reconstruida
if ! $NO_BUILD; then
    kubectl rollout restart deployment/ai-analyzer
fi

# ─── F) Verificación ─────────────────────────────────────────────────────────
step "F) Verificación"

info "Esperando que los pods estén listos..."
kubectl rollout status deployment/ai-analyzer --timeout=120s || warn "ai-analyzer timeout"

echo ""
kubectl get pods -l app=ai-analyzer -o wide
echo ""

PI_IP="192.168.1.167"

# Test health del analizador
if curl -sf "http://$PI_IP/health" | python3 -m json.tool 2>/dev/null; then
    ok "ai-analyzer /health: OK"
else
    warn "ai-analyzer no responde aún en http://$PI_IP/health"
fi

# Test dashboard
if curl -sf "http://$PI_IP/dashboard" -o /dev/null; then
    ok "Dashboard accesible en http://$PI_IP/dashboard"
else
    warn "Dashboard no responde"
fi

# ─── Resumen ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}════════════════════════════════════════════════════${NC}"
ok "Stack IA Raspi 4B instalado"
echo -e "${BOLD}════════════════════════════════════════════════════${NC}"
echo ""
echo "  llama.cpp server  : http://$PI_IP:$LLAMA_PORT"
echo "  AI Analyzer API   : http://$PI_IP/api/history"
echo "  Dashboard visual  : http://$PI_IP/dashboard"
echo "  Terminal en vivo  : http://$PI_IP/terminal"
echo "  Health check      : http://$PI_IP/health"
echo ""
echo "  Logs llama-server : tail -f $LLAMA_LOGFILE"
echo "  Logs ai-analyzer  : kubectl logs -f deploy/ai-analyzer"
echo "  Logs dashboard    : kubectl logs -f deploy/dashboard"
echo ""
if $NO_LLAMA; then
    warn "  llama.cpp: no configurado (--no-llama)"
    warn "  Endpoint esperado: http://$PI_IP:$LLAMA_PORT/completion"
fi
echo ""
echo "  Siguiente paso: ejecutar en la Raspi 3B:"
echo "    bash scripts/setup-sensor-raspi3b.sh"
echo ""
