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

for arg in "$@"; do
    case "$arg" in
        --no-ssh)   SETUP_SSH=false ;;
        --dry-run)  DRY_RUN=true    ;;
        --help|-h)
            echo "Uso: $0 [--no-ssh] [--dry-run]"
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
    curl

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

do_start() {
    if [ -f "\$PIDFILE" ] && kill -0 "\$(cat \$PIDFILE)" 2>/dev/null; then
        echo "\$NAME ya está corriendo (PID \$(cat \$PIDFILE))"
        return 0
    fi
    echo "Iniciando \$NAME..."
    \$DAEMON \$DAEMON_ARGS >> "\$LOGFILE" 2>&1 &
    echo \$! > "\$PIDFILE"
    echo "\$NAME iniciado (PID \$(cat \$PIDFILE))"
}

do_stop() {
    if [ ! -f "\$PIDFILE" ] || ! kill -0 "\$(cat \$PIDFILE)" 2>/dev/null; then
        echo "\$NAME no está corriendo"
        rm -f "\$PIDFILE"
        return 0
    fi
    echo "Deteniendo \$NAME (PID \$(cat \$PIDFILE))..."
    kill "\$(cat \$PIDFILE)"
    sleep 1
    rm -f "\$PIDFILE"
    echo "\$NAME detenido"
}

do_status() {
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

    # Test de conectividad con el analizador
    info "Probando conectividad con el analizador..."
    if curl -sf "${ANALYZER_URL%/ingest}/health" -o /dev/null; then
        ok "Analizador IA responde en $(echo "$ANALYZER_URL" | cut -d/ -f3)"
    else
        warn "Analizador IA no disponible aún — asegúrate de ejecutar setup-ai-raspi4b.sh en la 4B"
    fi
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
