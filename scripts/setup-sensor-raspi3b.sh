#!/bin/bash
# setup-sensor-raspi3b.sh — Instalación del sensor de red en Raspi 3B
#
# Ejecutar en: Raspberry Pi 3B (192.168.1.181) con DietPi
# Idempotente: Sí
#
# Qué hace:
#   A) Instala dependencias: tshark, python3, pip, tcpdump
#   B) Crea /opt/sensor/ y copia sensor.py
#   C) Instala dependencias Python (requests)
#   D) Genera llave SSH para acceder al router OpenWrt
#   E) Instala y habilita servicio init.d
#   F) Verifica captura en eth0
#
# Uso:
#   bash scripts/setup-sensor-raspi3b.sh
#   bash scripts/setup-sensor-raspi3b.sh --no-ssh   # omitir configuración SSH
#   bash scripts/setup-sensor-raspi3b.sh --dry-run  # solo mostrar qué haría

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# ─── Logging global a archivo + consola ───────────────────────────────────────
SCRIPT_NAME="$(basename "$0" .sh)"
DEFAULT_LOG_DIR="/var/log/demo-openwrt/setup"
if mkdir -p "$DEFAULT_LOG_DIR" 2>/dev/null && [ -w "$DEFAULT_LOG_DIR" ]; then
    LOG_DIR="${LOG_DIR:-$DEFAULT_LOG_DIR}"
else
    DEFAULT_LOG_DIR="/tmp/demo-openwrt/setup"
    mkdir -p "$DEFAULT_LOG_DIR" 2>/dev/null || true
    LOG_DIR="${LOG_DIR:-$DEFAULT_LOG_DIR}"
fi
mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR="/tmp/demo-openwrt/setup"
mkdir -p "$LOG_DIR"
TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
LOG_FILE="$LOG_DIR/${SCRIPT_NAME}-${TIMESTAMP}.log"

if [ -z "${SETUP_LOG_INITIALIZED:-}" ]; then
    SETUP_LOG_INITIALIZED=1
    export SETUP_LOG_INITIALIZED
    if command -v tee >/dev/null 2>&1 && command -v mkfifo >/dev/null 2>&1; then
        LOG_PIPE="/tmp/${SCRIPT_NAME}-$$.logpipe"
        mkfifo "$LOG_PIPE"
        tee -a "$LOG_FILE" < "$LOG_PIPE" &
        LOG_TEE_PID=$!
        exec > "$LOG_PIPE" 2>&1
        cleanup_setup_logging() {
            rc=$?
            trap - EXIT INT TERM
            exec 1>&- 2>&-
            wait "$LOG_TEE_PID" 2>/dev/null || true
            rm -f "$LOG_PIPE"
            exit "$rc"
        }
        trap cleanup_setup_logging EXIT INT TERM
    else
        exec >> "$LOG_FILE" 2>&1
    fi
fi
printf '[INFO]  Log file: %s\n' "$LOG_FILE"

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
SETUP_SSH=true
DRY_RUN=false
WAIT_PI4B=true           # esperar que Pi4B esté operativa antes de iniciar el servicio
WAIT_MQTT_S=180          # segundos máximos esperando broker MQTT (Pi4B puede tardar en levantar k3s)
WAIT_HTTP_S=120          # segundos máximos esperando analizador HTTP
WAIT_INTERVAL=10         # intervalo de reintento en segundos

for arg in "$@"; do
    case "$arg" in
        --no-ssh)     SETUP_SSH=false  ;;
        --dry-run)    DRY_RUN=true     ;;
        --no-wait)    WAIT_PI4B=false  ;;
        --wait-mqtt=*)  WAIT_MQTT_S="${arg#*=}" ;;
        --wait-http=*)  WAIT_HTTP_S="${arg#*=}" ;;
        --help|-h)
            echo "Uso: $0 [--no-ssh] [--dry-run] [--no-wait] [--wait-mqtt=N] [--wait-http=N]"
            echo "  --no-ssh          Omitir configuración SSH"
            echo "  --dry-run         Solo mostrar qué haría"
            echo "  --no-wait         No esperar a que Pi4B esté operativa"
            echo "  --wait-mqtt=N     Segundos máximos esperando broker MQTT (default: 180)"
            echo "  --wait-http=N     Segundos máximos esperando analizador HTTP (default: 120)"
            exit 0
            ;;
        *) die "Argumento desconocido: $arg" ;;
    esac
done

run() {
    if $DRY_RUN; then
        echo -e "${YELLOW}[DRY-RUN]${NC} $*"
    else
        "$@"
    fi
}

# ─── Helpers de espera con reintento ──────────────────────────────────────────

# wait_for_port LABEL HOST PORT MAX_S INTERVAL_S
# Espera hasta MAX_S segundos a que HOST:PORT sea alcanzable via TCP.
# Retorna 0 si logra conectar, 1 si agota el timeout.
wait_for_port() {
    local label="$1" host="$2" port="$3"
    local max_s="${4:-120}" interval="${5:-10}"
    local waited=0

    info "Esperando $label ($host:$port) — timeout ${max_s}s, reintento cada ${interval}s"
    while [ "$waited" -lt "$max_s" ]; do
        if nc -z -w3 "$host" "$port" 2>/dev/null; then
            printf '\n'
            ok "$label accesible ($host:$port) tras ${waited}s"
            return 0
        fi
        printf "  · %3ds/%ds — %s (%s:%s) no disponible aún...\r" \
            "$waited" "$max_s" "$label" "$host" "$port"
        sleep "$interval"
        waited=$((waited + interval))
    done
    printf '\n'
    warn "$label ($host:$port) no alcanzable tras ${max_s}s"
    return 1
}

# wait_for_url LABEL URL MAX_S INTERVAL_S
# Espera hasta MAX_S segundos a que URL devuelva un HTTP válido (2xx/3xx/5xx).
# Retorna 0 si responde, 1 si agota el timeout.
wait_for_url() {
    local label="$1" url="$2"
    local max_s="${3:-120}" interval="${4:-10}"
    local waited=0 code

    info "Esperando $label ($url) — timeout ${max_s}s, reintento cada ${interval}s"
    while [ "$waited" -lt "$max_s" ]; do
        code="$(curl -sS -o /dev/null -w '%{http_code}' \
            --connect-timeout 5 --max-time 10 "$url" 2>/dev/null)" || code="000"
        case "$code" in
            200|201|204|301|302|307|308|400|401|403|404|500|503)
                printf '\n'
                ok "$label responde HTTP $code tras ${waited}s"
                return 0
                ;;
        esac
        printf "  · %3ds/%ds — %s (HTTP %s) aún no responde...\r" \
            "$waited" "$max_s" "$label" "$code"
        sleep "$interval"
        waited=$((waited + interval))
    done
    printf '\n'
    warn "$label no respondió en ${max_s}s"
    return 1
}

# wait_for_raspi4b
# Espera con reintentos a que la Pi4B tenga el broker MQTT y el analizador IA
# operativos. Se llama antes de arrancar el servicio sensor para maximizar la
# probabilidad de que la primera publicación MQTT tenga éxito.
wait_for_raspi4b() {
    step "E.0) Esperando que RafexPi4B esté operativa"
    info "Pi4B puede tardar varios minutos en levantar k3s + Mosquitto + ai-analyzer"
    info "  Broker MQTT  : $MQTT_HOST:$MQTT_PORT"
    info "  Analizador   : $ANALYZER_URL"

    # 1) Ping básico — indica que el sistema operativo está vivo
    local ping_ok=false
    local waited=0
    local ping_max=60
    info "Ping a $MQTT_HOST — máximo ${ping_max}s..."
    while [ "$waited" -lt "$ping_max" ]; do
        if ping -c1 -W2 "$MQTT_HOST" &>/dev/null; then
            printf '\n'
            ok "Pi4B responde a ping tras ${waited}s"
            ping_ok=true
            break
        fi
        printf "  · %3ds/%ds — Pi4B sin respuesta a ping...\r" "$waited" "$ping_max"
        sleep "$WAIT_INTERVAL"
        waited=$((waited + WAIT_INTERVAL))
    done
    printf '\n'

    if ! $ping_ok; then
        warn "Pi4B no responde a ping — puede estar apagada o arrancando"
        warn "El sensor iniciará igualmente; se conectará a Pi4B cuando esté lista"
        return 0
    fi

    # 2) Puerto MQTT (Mosquitto)
    if ! wait_for_port "broker MQTT" "$MQTT_HOST" "$MQTT_PORT" \
            "$WAIT_MQTT_S" "$WAIT_INTERVAL"; then
        warn "Broker MQTT no disponible en ${WAIT_MQTT_S}s"
        warn "El sensor publicará los batches en cuanto Pi4B levante Mosquitto"
    fi

    # 3) Endpoint HTTP del analizador IA
    local HEALTH_URL="${ANALYZER_URL%/ingest}/health"
    if ! wait_for_url "analizador IA" "$HEALTH_URL" "$WAIT_HTTP_S" "$WAIT_INTERVAL"; then
        warn "Analizador IA no disponible en ${WAIT_HTTP_S}s"
        warn "Verifica que setup-ai-raspi4b.sh se haya ejecutado correctamente en Pi4B"
    fi
}

# ─── Constantes ───────────────────────────────────────────────────────────────
HOSTNAME_NEW="RafexPi3B"
RASPI3B_MAC="b8:27:eb:5a:ec:33"
RASPI3B_IP="192.168.1.181"
SENSOR_DIR="/opt/sensor"
KEYS_DIR="/opt/keys"
SSH_KEY="$KEYS_DIR/sensor"
SERVICE_NAME="network-sensor"
SERVICE_FILE="/etc/init.d/$SERVICE_NAME"
INTERFACE="eth0"
ANALYZER_URL="${ANALYZER_URL:-http://192.168.1.167/api/ingest}"
MQTT_HOST="${MQTT_HOST:-192.168.1.167}"
MQTT_PORT="${MQTT_PORT:-1883}"
MQTT_TOPIC="${MQTT_TOPIC:-rafexpi/sensor/batch}"
ROUTER_IP="${ROUTER_IP:-192.168.1.1}"

# ─── Hostname ─────────────────────────────────────────────────────────────────
step "Configurando hostname: $HOSTNAME_NEW"

if ! $DRY_RUN; then
    HOSTNAME_CURRENT=$(hostname)
    if [ "$HOSTNAME_CURRENT" = "$HOSTNAME_NEW" ]; then
        ok "Hostname ya es $HOSTNAME_NEW"
    else
        echo "$HOSTNAME_NEW" > /etc/hostname
        sed -i "s/\b${HOSTNAME_CURRENT}\b/${HOSTNAME_NEW}/g" /etc/hosts
        hostname "$HOSTNAME_NEW"
        ok "Hostname cambiado: $HOSTNAME_CURRENT → $HOSTNAME_NEW (efectivo en próximo reinicio)"
    fi
else
    echo -e "${YELLOW}[DRY-RUN]${NC} echo $HOSTNAME_NEW > /etc/hostname"
fi

# ─── Verificaciones previas ────────────────────────────────────────────────────
step "Pre-flight checks"

if [ "$EUID" -ne 0 ] && ! $DRY_RUN; then
    die "Este script debe ejecutarse como root (sudo bash $0)"
fi

# Verificar que eth0 existe
if ip link show "$INTERFACE" &>/dev/null; then
    SENSOR_IP=$(ip addr show "$INTERFACE" | awk '/inet / {print $2}' | cut -d/ -f1 | head -1)
    ok "Interfaz $INTERFACE detectada: ${SENSOR_IP:-sin IP}"
else
    warn "Interfaz $INTERFACE no encontrada — continuando de todas formas"
    SENSOR_IP="192.168.1.181"
fi

info "  Sensor IP      : $SENSOR_IP"
info "  Analyzer URL   : $ANALYZER_URL"
info "  Router IP      : $ROUTER_IP"
info "  SSH key        : $SSH_KEY"
info "  Modo dry-run   : $DRY_RUN"

# ─── A) Dependencias del sistema ──────────────────────────────────────────────
step "A) Instalando dependencias del sistema"

run apt-get update -qq
run apt-get install -y --no-install-recommends \
    tshark \
    tcpdump \
    python3 \
    python3-pip \
    python3-requests \
    openssh-client \
    iproute2 \
    curl \
    netcat-openbsd

ok "Dependencias instaladas"

# Verificar tshark
if command -v tshark &>/dev/null; then
    ok "tshark: $(tshark --version 2>&1 | head -1)"
else
    die "tshark no instalado correctamente"
fi

# Permitir a usuarios no-root capturar (setuid en dumpcap)
if ! $DRY_RUN; then
    # En DietPi/Debian: tshark puede necesitar pertenecer al grupo wireshark
    if getent group wireshark &>/dev/null; then
        usermod -aG wireshark root 2>/dev/null || true
        chmod +x /usr/bin/dumpcap 2>/dev/null || true
    fi
fi
ok "Permisos de captura configurados"

# ─── B) Directorio y sensor.py ────────────────────────────────────────────────
step "B) Instalando sensor.py en $SENSOR_DIR"

run mkdir -p "$SENSOR_DIR"
run cp "$REPO_DIR/sensor/sensor.py" "$SENSOR_DIR/sensor.py"
run chmod +x "$SENSOR_DIR/sensor.py"
ok "sensor.py instalado en $SENSOR_DIR"

# Si el servicio ya corría, reiniciarlo para aplicar el nuevo sensor.py
if ! $DRY_RUN && [ -f /var/run/network-sensor.pid ] && \
   kill -0 "$(cat /var/run/network-sensor.pid)" 2>/dev/null; then
    info "Servicio ya corriendo — reiniciando para aplicar sensor.py actualizado..."
    "$SERVICE_FILE" restart 2>/dev/null || true
fi

# ─── C) Dependencias Python ───────────────────────────────────────────────────
step "C) Instalando dependencias Python"

# requests suele ya estar instalado con python3-requests
# pero por si acaso:
if ! python3 -c "import requests" &>/dev/null; then
    run pip3 install --break-system-packages requests 2>/dev/null || \
    run pip3 install requests
fi
ok "python3-requests disponible"

if ! python3 -c "import paho.mqtt.client" &>/dev/null; then
    run pip3 install --break-system-packages paho-mqtt 2>/dev/null || \
    run pip3 install paho-mqtt
fi
ok "paho-mqtt disponible"

# ─── D) Llave SSH para el router ──────────────────────────────────────────────
step "D) Configurando llave SSH para el router"

if $SETUP_SSH; then
    run mkdir -p "$KEYS_DIR"
    run chmod 700 "$KEYS_DIR"

    if [ -f "$SSH_KEY" ] && ! $DRY_RUN; then
        ok "Llave SSH ya existe: $SSH_KEY"
    else
        run ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -C "sensor@raspi3b"
        ok "Llave SSH generada: $SSH_KEY"
    fi

    if ! $DRY_RUN; then
        PUB_KEY=$(cat "${SSH_KEY}.pub")
        echo ""
        warn "╔══════════════════════════════════════════════════════════╗"
        warn "║  ACCIÓN MANUAL REQUERIDA                                 ║"
        warn "╚══════════════════════════════════════════════════════════╝"
        echo ""
        echo "Agrega esta llave pública al router OpenWrt:"
        echo ""
        echo "  ssh root@$ROUTER_IP \\"
        echo "    'echo \"$PUB_KEY\" >> /etc/dropbear/authorized_keys'"
        echo ""
        echo "O ejecuta desde esta Pi (si ya tienes acceso SSH al router):"
        echo ""
        echo "  ssh-copy-id -i $SSH_KEY root@$ROUTER_IP"
        echo ""

        # Intentar agregar automáticamente si tenemos acceso con contraseña
        info "Intentando agregar llave automáticamente (puede pedir contraseña)..."
        if ssh-copy-id -i "${SSH_KEY}.pub" -o StrictHostKeyChecking=no \
            "root@$ROUTER_IP" 2>/dev/null; then
            ok "Llave copiada automáticamente al router"
        else
            warn "No se pudo copiar automáticamente — agrega la llave manualmente"
        fi
    fi
else
    info "SSH omitido (--no-ssh)"
fi

# Verificar SSH al router
if $SETUP_SSH && ! $DRY_RUN && [ -f "$SSH_KEY" ]; then
    if ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o BatchMode=yes \
        -o ConnectTimeout=5 "root@$ROUTER_IP" "echo pong" 2>/dev/null | grep -q pong; then
        ok "SSH al router: OK"
    else
        warn "SSH al router no disponible — el sensor usará solo captura local"
    fi
fi

# ─── D.1) Reserva DHCP permanente en el router ────────────────────────────────
step "D.1) Reserva DHCP permanente en router OpenWrt para $HOSTNAME_NEW"

reserve_dhcp_on_router() {
    local ROUTER="$ROUTER_IP"
    local KEY="$SSH_KEY"
    local NAME="$HOSTNAME_NEW"
    local MAC="$RASPI3B_MAC"
    local IP="$RASPI3B_IP"

    # SSH hacia el router — usamos la llave del sensor (generada en paso D)
    if [ ! -f "$KEY" ]; then
        warn "Llave SSH $KEY no existe aún — saltando reserva DHCP automática"
        warn "Ejecuta después: sh scripts/openwrt-reserve-raspi.sh --mac $MAC --ip $IP"
        return
    fi

    if ! ssh -i "$KEY" -o StrictHostKeyChecking=no -o BatchMode=yes \
         -o ConnectTimeout=5 "root@$ROUTER" "echo pong" 2>/dev/null | grep -q pong; then
        warn "No se puede alcanzar el router via SSH — saltando reserva DHCP automática"
        warn "Ejecuta después: sh scripts/openwrt-reserve-raspi.sh --mac $MAC --ip $IP"
        return
    fi

    ssh -i "$KEY" -o StrictHostKeyChecking=no -o BatchMode=yes "root@$ROUTER" "
        # Buscar entrada existente por IP o MAC
        EXISTING_IDX=''
        IDX=0
        while uci get dhcp.@host[\$IDX] > /dev/null 2>&1; do
            CUR_IP=\$(uci get dhcp.@host[\$IDX].ip 2>/dev/null)
            CUR_MAC=\$(uci get dhcp.@host[\$IDX].mac 2>/dev/null)
            if [ \"\$CUR_IP\" = '$IP' ] || [ \"\$CUR_MAC\" = '$MAC' ]; then
                EXISTING_IDX=\$IDX
                break
            fi
            IDX=\$((IDX + 1))
        done

        if [ -n \"\$EXISTING_IDX\" ]; then
            echo 'Actualizando reserva existente (índice '\$EXISTING_IDX')...'
            uci set dhcp.@host[\$EXISTING_IDX].name='$NAME'
            uci set dhcp.@host[\$EXISTING_IDX].mac='$MAC'
            uci set dhcp.@host[\$EXISTING_IDX].ip='$IP'
            uci set dhcp.@host[\$EXISTING_IDX].leasetime='infinite'
        else
            echo 'Creando nueva reserva DHCP...'
            uci add dhcp host
            uci set dhcp.@host[-1].name='$NAME'
            uci set dhcp.@host[-1].mac='$MAC'
            uci set dhcp.@host[-1].ip='$IP'
            uci set dhcp.@host[-1].leasetime='infinite'
        fi
        uci commit dhcp
        /etc/init.d/dnsmasq reload 2>/dev/null || /etc/init.d/dnsmasq restart 2>/dev/null
        echo 'Reserva aplicada'
    " && ok "Reserva DHCP: $NAME ($MAC) → $IP (infinite)" \
      || warn "No se pudo configurar la reserva — hazlo manualmente:"
    warn "  sh scripts/openwrt-reserve-raspi.sh --mac $RASPI3B_MAC --ip $RASPI3B_IP"
}

if $DRY_RUN; then
    echo -e "${YELLOW}[DRY-RUN]${NC} Configuraría reserva DHCP: $HOSTNAME_NEW ($RASPI3B_MAC) → $RASPI3B_IP"
else
    reserve_dhcp_on_router
fi

# ─── E.0) Esperar que Pi4B esté operativa ─────────────────────────────────────
# El sensor necesita el broker MQTT y el analizador activos para publicar batches.
# Pi4B arranca k3s + varios pods, lo que puede tardar varios minutos tras el boot.
if ! $DRY_RUN && $WAIT_PI4B; then
    wait_for_raspi4b
elif $DRY_RUN; then
    echo -e "${YELLOW}[DRY-RUN]${NC} Esperaría hasta ${WAIT_MQTT_S}s a broker MQTT y ${WAIT_HTTP_S}s a analizador en $MQTT_HOST"
else
    info "Espera a Pi4B omitida (--no-wait)"
fi

# ─── E) Servicio init.d ───────────────────────────────────────────────────────
step "E) Instalando servicio init.d"

if ! $DRY_RUN; then
    cat > "$SERVICE_FILE" << EOF
#!/bin/sh
### BEGIN INIT INFO
# Provides:          network-sensor
# Required-Start:    \$network \$remote_fs
# Required-Stop:     \$network
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Network traffic sensor for AI analysis
### END INIT INFO

DAEMON=/usr/bin/python3
DAEMON_ARGS="$SENSOR_DIR/sensor.py"
NAME=network-sensor
PIDFILE=/var/run/network-sensor.pid
LAUNCHER_PIDFILE=/var/run/network-sensor-launcher.pid
LOGFILE=/var/log/network-sensor.log

export SENSOR_IFACE="$INTERFACE"
export SENSOR_IP="$SENSOR_IP"
export MQTT_HOST="$MQTT_HOST"
export MQTT_PORT="$MQTT_PORT"
export MQTT_TOPIC="$MQTT_TOPIC"
export ANALYZER_URL="$ANALYZER_URL"
export BATCH_INTERVAL="30"
export ROUTER_IP="$ROUTER_IP"
export ROUTER_USER="root"
export SSH_KEY="$SSH_KEY"
export USE_ROUTER_SSH="$SETUP_SSH"
export LOG_LEVEL="INFO"

# Tiempo máximo esperando al broker MQTT en cada arranque (segundos).
# Pi4B puede tardar en levantar k3s + Mosquitto tras un reboot.
WAIT_MQTT_MAX_S="${WAIT_MQTT_S}"
WAIT_INTERVAL_S="${WAIT_INTERVAL}"

log_svc() { printf '[%s] %s\n' "\$(date '+%Y-%m-%dT%H:%M:%S')" "\$*" >> "\$LOGFILE"; }

# Espera hasta WAIT_MQTT_MAX_S segundos a que el broker MQTT esté accesible.
# No bloquea el arranque del sistema porque do_start lanza este código en background.
# Si el broker no responde en el timeout, inicia el sensor igualmente para que
# capture tráfico local; el sensor reintentará la conexión MQTT de forma autónoma.
wait_for_mqtt() {
    local waited=0
    log_svc "Esperando broker MQTT \${MQTT_HOST}:\${MQTT_PORT} (max \${WAIT_MQTT_MAX_S}s, cada \${WAIT_INTERVAL_S}s)..."
    while [ "\$waited" -lt "\$WAIT_MQTT_MAX_S" ]; do
        if nc -z -w3 "\$MQTT_HOST" "\$MQTT_PORT" 2>/dev/null; then
            log_svc "Broker MQTT accesible tras \${waited}s"
            return 0
        fi
        log_svc "  [\${waited}s/\${WAIT_MQTT_MAX_S}s] MQTT no disponible aún — reintentando..."
        sleep "\$WAIT_INTERVAL_S"
        waited=\$((waited + WAIT_INTERVAL_S))
    done
    log_svc "WARN: broker MQTT no disponible tras \${WAIT_MQTT_MAX_S}s — iniciando sensor de todas formas"
    return 0
}

# Lanzador en background: espera al broker y luego arranca el sensor.
# Se ejecuta como subshell para que do_start retorne de inmediato y no bloquee
# la secuencia de arranque del sistema (el kernel y otros servicios siguen subiendo).
_launch_sensor() {
    wait_for_mqtt
    log_svc "Lanzando \$DAEMON \$DAEMON_ARGS"
    \$DAEMON \$DAEMON_ARGS >> "\$LOGFILE" 2>&1 &
    SENSOR_PID=\$!
    echo "\$SENSOR_PID" > "\$PIDFILE"
    log_svc "\$NAME iniciado (PID \$SENSOR_PID)"
    rm -f "\$LAUNCHER_PIDFILE"
}

do_start() {
    # Si el sensor ya corre, no hacer nada
    if [ -f "\$PIDFILE" ] && kill -0 "\$(cat \$PIDFILE)" 2>/dev/null; then
        echo "\$NAME ya está corriendo (PID \$(cat \$PIDFILE))"
        return 0
    fi
    # Si ya hay un lanzador esperando al broker, no duplicar
    if [ -f "\$LAUNCHER_PIDFILE" ] && kill -0 "\$(cat \$LAUNCHER_PIDFILE)" 2>/dev/null; then
        echo "\$NAME: lanzador ya en espera (PID \$(cat \$LAUNCHER_PIDFILE)) — esperando broker MQTT"
        return 0
    fi
    log_svc "=== \$NAME start — lanzador en background (esperará broker MQTT hasta \${WAIT_MQTT_MAX_S}s) ==="
    echo "\$NAME: iniciando lanzador en background (esperará broker MQTT hasta \${WAIT_MQTT_MAX_S}s)..."
    _launch_sensor &
    echo \$! > "\$LAUNCHER_PIDFILE"
}

do_stop() {
    # Detener lanzador si todavía está esperando al broker
    if [ -f "\$LAUNCHER_PIDFILE" ] && kill -0 "\$(cat \$LAUNCHER_PIDFILE)" 2>/dev/null; then
        echo "Deteniendo lanzador (PID \$(cat \$LAUNCHER_PIDFILE))..."
        kill "\$(cat \$LAUNCHER_PIDFILE)" 2>/dev/null || true
        rm -f "\$LAUNCHER_PIDFILE"
    fi
    # Detener sensor si ya arrancó
    if [ ! -f "\$PIDFILE" ] || ! kill -0 "\$(cat \$PIDFILE)" 2>/dev/null; then
        echo "\$NAME no está corriendo"
        rm -f "\$PIDFILE"
        return 0
    fi
    echo "Deteniendo \$NAME (PID \$(cat \$PIDFILE))..."
    kill "\$(cat \$PIDFILE)"
    sleep 1
    rm -f "\$PIDFILE"
    log_svc "=== \$NAME detenido ==="
    echo "\$NAME detenido"
}

do_status() {
    if [ -f "\$LAUNCHER_PIDFILE" ] && kill -0 "\$(cat \$LAUNCHER_PIDFILE)" 2>/dev/null; then
        echo "\$NAME: lanzador en espera (PID \$(cat \$LAUNCHER_PIDFILE)) — esperando broker MQTT en \${MQTT_HOST}:\${MQTT_PORT}"
        return 0
    fi
    if [ -f "\$PIDFILE" ] && kill -0 "\$(cat \$PIDFILE)" 2>/dev/null; then
        echo "\$NAME corriendo (PID \$(cat \$PIDFILE))"
        echo ""
        echo "=== Últimas 30 líneas de log ==="
        tail -30 "\$LOGFILE" 2>/dev/null
    else
        echo "\$NAME NO está corriendo"
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
    chmod +x "$SERVICE_FILE"
    ok "Servicio instalado en $SERVICE_FILE"

    # Habilitar en arranque (update-rc.d o similar)
    if command -v update-rc.d &>/dev/null; then
        update-rc.d "$SERVICE_NAME" defaults
        ok "Servicio habilitado en arranque (update-rc.d)"
    elif command -v systemctl &>/dev/null && systemctl is-system-running &>/dev/null; then
        systemctl enable "$SERVICE_NAME" 2>/dev/null || true
    fi
else
    run cp "$REPO_DIR/sensor/sensor.service" "$SERVICE_FILE"
    run chmod +x "$SERVICE_FILE"
fi

# Iniciar el servicio
info "Iniciando $SERVICE_NAME..."
run "$SERVICE_FILE" start || warn "No se pudo iniciar el servicio — verifica: $SERVICE_FILE status"

# ─── F) Verificación ─────────────────────────────────────────────────────────
step "F) Verificación"

sleep 3  # dar tiempo al servicio de arrancar

if ! $DRY_RUN; then
    if [ -f /var/run/network-sensor.pid ] && \
       kill -0 "$(cat /var/run/network-sensor.pid)" 2>/dev/null; then
        ok "Servicio corriendo (PID $(cat /var/run/network-sensor.pid))"
    else
        warn "Servicio no parece estar corriendo — revisa el log:"
        warn "  tail -50 /var/log/network-sensor.log"
    fi

    info "Probando captura de 5 segundos en $INTERFACE..."
    if timeout 5 tshark -i "$INTERFACE" -c 5 -Q 2>/dev/null; then
        ok "tshark captura correctamente en $INTERFACE"
    else
        warn "tshark no capturó paquetes en 5s (¿interfaz sin tráfico?)"
    fi

    # Test de conectividad con el analizador (verificación final tras la espera del paso E.0)
    info "Verificando conectividad con el analizador..."
    HEALTH_URL="${ANALYZER_URL%/ingest}/health"
    HEALTH_CODE="$(curl -sS -o /dev/null -w '%{http_code}' \
        --connect-timeout 5 --max-time 10 "$HEALTH_URL" 2>/dev/null)" || HEALTH_CODE="000"
    case "$HEALTH_CODE" in
        200|301|302|500|503)
            ok "Analizador IA responde HTTP $HEALTH_CODE en $(echo "$ANALYZER_URL" | cut -d/ -f3)" ;;
        000)
            warn "Analizador IA aún no disponible (HTTP 000 / sin conexión)"
            warn "  → Revisa el estado de Pi4B con: bash scripts/health-raspi4b.sh" ;;
        *)
            warn "Analizador IA respondió HTTP $HEALTH_CODE — puede estar inicializándose" ;;
    esac
fi

# ─── Resumen ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}════════════════════════════════════════════════════${NC}"
ok "Sensor Raspi 3B instalado y activo"
echo -e "${BOLD}════════════════════════════════════════════════════${NC}"
echo ""
echo "  Sensor en      : $INTERFACE ($SENSOR_IP)"
echo "  Analizador IA  : $ANALYZER_URL"
echo "  Batch interval : 30s"
echo ""
echo "  Logs           : tail -f /var/log/network-sensor.log"
echo "  Estado         : /etc/init.d/network-sensor status"
echo "  Reiniciar      : /etc/init.d/network-sensor restart"
echo ""
echo "  Dashboards (en la Raspi 4B):"
echo "    http://192.168.1.167/dashboard   — UI visual"
echo "    http://192.168.1.167/terminal    — terminal en vivo"
echo ""
