#!/bin/sh
# setup-openwrt-wifi-repeater.sh
#
# Convierte el OpenWrt en repetidor WiFi.
# Se ejecuta DESDE LA MÁQUINA ADMIN — aplica la configuración en el router
# via SSH, sin necesidad de copiar ningún archivo al router.
#
#   radio STA  → cliente hacia la red de casa    (WWAN / WAN)
#   radio AP   → AP para los clientes del portal (LAN)
#
# Las credenciales se leen LOCALMENTE desde un archivo .env.
#
# Uso:
#   sh setup-openwrt-wifi-repeater.sh
#   sh setup-openwrt-wifi-repeater.sh --host 192.168.1.1
#   sh setup-openwrt-wifi-repeater.sh --host 192.168.1.1 --ssh-user root
#   sh setup-openwrt-wifi-repeater.sh --env-file secrets/openwrt.env
#   sh setup-openwrt-wifi-repeater.sh --dry-run
#   sh setup-openwrt-wifi-repeater.sh --help
#
# Archivo .env (ver secrets/openwrt.env.example en el repo):
#   HOME_SSID="NombreWiFiCasa"
#   HOME_PASS="PasswordCasa"
#   AP_SSID="OpenWrt-Portal"
#   AP_PASS="PasswordAP"    # opcional — vacío o ausente = AP abierto sin contraseña
#   # WIFI_STA="radio0"     # opcional — autodetectado desde el router
#   # WIFI_AP="radio1"      # opcional — autodetectado desde el router
#
# Prerequisitos en la máquina admin:
#   cp secrets/openwrt.env.example secrets/openwrt.env
#   # editar con valores reales
#   ssh-copy-id root@192.168.1.1    # (recomendado, evita pedir password)

set -eu

# ── Logging ───────────────────────────────────────────────────────────────────

log_info()  { printf '[INFO]  %s\n' "$*"; }
log_ok()    { printf '[OK]    %s\n' "$*"; }
log_warn()  { printf '[WARN]  %s\n' "$*"; }
log_error() { printf '[ERROR] %s\n' "$*" >&2; }
die()       { log_error "$*"; exit 1; }

# ── Flags ─────────────────────────────────────────────────────────────────────

ENV_FILE=""
HOST="192.168.1.1"
SSH_USER="root"
DRY_RUN=false

while [ $# -gt 0 ]; do
    case "$1" in
        --host)
            [ -n "${2:-}" ] || die "--host requiere un argumento"
            HOST="$2"; shift 2
            ;;
        --host=*)
            HOST="${1#--host=}"; shift
            ;;
        --ssh-user)
            [ -n "${2:-}" ] || die "--ssh-user requiere un argumento"
            SSH_USER="$2"; shift 2
            ;;
        --ssh-user=*)
            SSH_USER="${1#--ssh-user=}"; shift
            ;;
        --env-file)
            [ -n "${2:-}" ] || die "--env-file requiere un argumento"
            ENV_FILE="$2"; shift 2
            ;;
        --env-file=*)
            ENV_FILE="${1#--env-file=}"; shift
            ;;
        --dry-run)
            DRY_RUN=true; shift
            ;;
        --help|-h)
            sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            die "Argumento desconocido: $1  (usa --help)"
            ;;
    esac
done

# ── SSH helpers ───────────────────────────────────────────────────────────────
#
# Opciones SSH para uso no interactivo:
#   BatchMode=yes      → falla si pide password (no cuelga esperando input)
#   ConnectTimeout=10  → timeout de conexión
#   StrictHostKeyChecking=no → no preguntar por fingerprint (red local de lab)

SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no"

# Ejecuta un comando en el router via SSH
_r() {
    ssh $SSH_OPTS "${SSH_USER}@${HOST}" "$@"
}

# Ejecuta un bloque de comandos (leído desde stdin) en el router via SSH
_r_pipe() {
    ssh $SSH_OPTS "${SSH_USER}@${HOST}" sh
}

# Verifica que el router sea accesible antes de empezar
_check_ssh() {
    log_info "Verificando conexión SSH a ${SSH_USER}@${HOST}..."
    if ! _r "echo ok" >/dev/null 2>&1; then
        log_error "No se puede conectar a ${SSH_USER}@${HOST}"
        log_error ""
        log_error "Verificar:"
        log_error "  1. Router encendido y accesible: ping ${HOST}"
        log_error "  2. SSH habilitado en el router"
        log_error "  3. Clave SSH configurada: ssh-copy-id ${SSH_USER}@${HOST}"
        log_error "  4. Usuario y contraseña correctos"
        exit 1
    fi
    log_ok "Conexión SSH a ${HOST} OK"
}

# ── Escaping para valores en comandos UCI remotos ────────────────────────────
#
# Los valores se incrustan en un heredoc (expansión local) dentro de strings
# entre comillas simples para el shell remoto.
# _q escapa las comillas simples en el valor para que sean seguras en ese contexto.
#   Ejemplo: "Mi WiFi's" → "Mi WiFi'\''s"

_q() { printf '%s' "$1" | sed "s/'/'\\\\''/g"; }

# ── Cargar .env LOCALMENTE ────────────────────────────────────────────────────
#
# Orden de búsqueda (el primero que exista):
#   1. --env-file <ruta>  (argumento explícito)
#   2. $(dirname $0)/../secrets/openwrt.env  (ubicación estándar del repo)
#   3. $(dirname $0)/openwrt.env  (junto al script)
#   4. ./openwrt.env  (directorio de trabajo)

_load_env() {
    local f="$1"
    [ -f "$f" ] || { log_warn "Archivo no encontrado: $f"; return 1; }
    [ -r "$f" ] || die "Sin permiso de lectura: $f"

    # Advertir si el archivo tiene permisos demasiado abiertos
    local perms
    perms=$(ls -la "$f" 2>/dev/null | awk '{print $1}')
    case "$perms" in
        -rw-------|-r--------) ;;
        *)
            log_warn "ATENCIÓN: $f tiene permisos $perms — recomendado chmod 600"
            ;;
    esac

    log_info "Cargando credenciales desde: $f"
    # shellcheck source=/dev/null
    . "$f"
    return 0
}

ENV_LOADED=false
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

if [ -n "$ENV_FILE" ]; then
    _load_env "$ENV_FILE" || die "No se pudo cargar el archivo .env: $ENV_FILE"
    ENV_LOADED=true
else
    for candidate in \
        "${SCRIPT_DIR}/../secrets/openwrt.env" \
        "${SCRIPT_DIR}/openwrt.env" \
        "./secrets/openwrt.env" \
        "./openwrt.env"
    do
        if _load_env "$candidate" 2>/dev/null; then
            ENV_FILE="$candidate"
            ENV_LOADED=true
            break
        fi
    done
fi

if ! $ENV_LOADED; then
    log_error "No se encontró ningún archivo .env con credenciales."
    log_error ""
    log_error "Opciones:"
    log_error "  1. Crear secrets/openwrt.env con el contenido:"
    log_error "       HOME_SSID=\"NombreWiFiCasa\""
    log_error "       HOME_PASS=\"PasswordCasa\""
    log_error "       AP_SSID=\"OpenWrt-Portal\""
    log_error "       AP_PASS=\"PasswordAP\"   # opcional"
    log_error "     chmod 600 secrets/openwrt.env"
    log_error ""
    log_error "  2. Pasar la ruta explícita:"
    log_error "     sh $0 --env-file /ruta/archivo.env"
    log_error ""
    log_error "  Ver plantilla en: secrets/openwrt.env.example"
    exit 1
fi

# ── Validar variables obligatorias ────────────────────────────────────────────

_require_var() {
    local name="$1" val=""
    eval "val=\${$name:-}"
    [ -n "$val" ] || die "Variable obligatoria no definida en el .env: $name"
}

_require_var HOME_SSID
_require_var HOME_PASS
_require_var AP_SSID
# AP_PASS es OPCIONAL: si está vacío o ausente, el AP queda abierto (sin clave)
AP_PASS="${AP_PASS:-}"

[ ${#HOME_PASS} -ge 8 ] || die "HOME_PASS demasiado corta (mínimo 8 caracteres para WPA2)"
if [ -n "$AP_PASS" ]; then
    [ ${#AP_PASS} -ge 8 ] || \
        die "AP_PASS demasiado corta (mínimo 8 caracteres). Para AP abierto, deja AP_PASS vacío."
fi

log_ok "Credenciales cargadas — HOME_SSID='${HOME_SSID}'  AP_SSID='${AP_SSID}'"
if [ -n "$AP_PASS" ]; then
    log_info "AP: protegido con WPA2 (contraseña no se muestra en logs)"
else
    log_warn "AP: SIN contraseña — red abierta (cualquiera puede conectarse)"
fi

# ── Autodetectar radios desde el router (via SSH) ─────────────────────────────
#
# Ejecuta uci show wireless en el router y parsea el resultado localmente.
# Solo se llama si WIFI_STA o WIFI_AP no están definidos en el .env.

_detect_radios_remote() {
    log_info "Consultando radios del router (${HOST})..."
    _r '
        r2g="" r5g=""
        for dev in $(uci show wireless | sed -n "s/^wireless\.\([^=]*\)=wifi-device$/\1/p"); do
            band=$(uci -q get "wireless.$dev.band" 2>/dev/null || true)
            case "$band" in
                2g) [ -z "$r2g" ] && r2g="$dev" ;;
                5g) [ -z "$r5g" ] && r5g="$dev" ;;
            esac
            if [ -z "$r2g" ] || [ -z "$r5g" ]; then
                ch=$(uci -q get "wireless.$dev.channel" 2>/dev/null || true)
                case "$ch" in
                    [1-9]|1[0-4])              [ -z "$r2g" ] && r2g="$dev" ;;
                    3[6-9]|4[0-9]|5[0-9]|6[0-4]|1[0-4][0-9]|16[0-5]) [ -z "$r5g" ] && r5g="$dev" ;;
                esac
            fi
        done
        r2g="${r2g:-radio0}"
        r5g="${r5g:-radio1}"
        printf "%s %s\n" "$r2g" "$r5g"
    '
}

WIFI_STA="${WIFI_STA:-}"
WIFI_AP="${WIFI_AP:-}"

if $DRY_RUN; then
    # En dry-run no hay SSH — usar defaults o valores del .env
    WIFI_STA="${WIFI_STA:-radio0}"
    WIFI_AP="${WIFI_AP:-radio1}"
else
    # Verificar SSH antes de cualquier operación remota
    _check_ssh

    if [ -z "$WIFI_STA" ] || [ -z "$WIFI_AP" ]; then
        DETECTED=$(_detect_radios_remote)
        RADIO_STA=$(printf '%s' "$DETECTED" | cut -d' ' -f1)
        RADIO_AP=$(printf  '%s' "$DETECTED" | cut -d' ' -f2)
        WIFI_STA="${WIFI_STA:-$RADIO_STA}"
        WIFI_AP="${WIFI_AP:-$RADIO_AP}"
    fi
fi

log_info "Radio STA (cliente → casa): $WIFI_STA"
log_info "Radio AP  (para clientes):  $WIFI_AP"

[ "$WIFI_STA" != "$WIFI_AP" ] || \
    die "WIFI_STA y WIFI_AP no pueden ser el mismo radio ($WIFI_STA)"

# ── Dry-run ───────────────────────────────────────────────────────────────────

if $DRY_RUN; then
    printf '\n'
    log_info "─── DRY-RUN ─── (ningún cambio se aplica en el router) ──────────"
    log_info "  Router     : ${SSH_USER}@${HOST}"
    log_info "  HOME_SSID  : $HOME_SSID"
    log_info "  AP_SSID    : $AP_SSID"
    if [ -n "$AP_PASS" ]; then
        log_info "  AP_SEGUR   : WPA2 (con contraseña)"
    else
        log_warn "  AP_SEGUR   : ABIERTO (sin contraseña)"
    fi
    log_info "  STA radio  : $WIFI_STA  (cliente → red de casa)"
    log_info "  AP  radio  : $WIFI_AP   (AP para clientes del portal)"
    printf '\n'
    log_ok "Dry-run completado. Ejecuta sin --dry-run para aplicar."
    exit 0
fi

# ── 1. Backup en el router ────────────────────────────────────────────────────

log_info "[1] Creando backup de configuración en el router..."
TS=$(date +%s)
_r "cp /etc/config/wireless /etc/config/wireless.bak.${TS} && \
    cp /etc/config/network  /etc/config/network.bak.${TS}  && \
    cp /etc/config/firewall /etc/config/firewall.bak.${TS}"
log_ok "Backups creados: /etc/config/*.bak.${TS}"

# ── 2-6. Aplicar configuración UCI via SSH ────────────────────────────────────
#
# Se construye un script sh localmente (con las variables ya interpoladas)
# y se envía al router via SSH para ejecutarse en una sola sesión.
# _q() escapa comillas simples en los valores para que sean seguros
# al incrustarlos entre comillas simples en el shell remoto.

Q_HOME_SSID=$(_q "$HOME_SSID")
Q_HOME_PASS=$(_q "$HOME_PASS")
Q_AP_SSID=$(_q "$AP_SSID")
Q_AP_PASS=$(_q "$AP_PASS")

log_info "[2-6] Aplicando configuración UCI en ${HOST}..."

_r_pipe << UCI_SCRIPT
set -eu

# [2] Interfaz WWAN
uci set network.wwan='interface'
uci set network.wwan.proto='dhcp'
uci set network.wwan.peerdns='1'
uci set network.wwan.defaultroute='1'
uci set network.wwan.metric='20'

# [3] Desactivar interfaces wifi previas para evitar conflictos
for sec in \$(uci show wireless 2>/dev/null | sed -n "s/^wireless\.\([^=]*\)=wifi-iface\$/\1/p"); do
    case "\$sec" in
        wifinet_home|wifinet_ap) ;;
        *) uci set "wireless.\${sec}.disabled=1" ;;
    esac
done

# [4] Radio STA → cliente hacia la red de casa
uci set wireless.wifinet_home='wifi-iface'
uci set wireless.wifinet_home.device='${WIFI_STA}'
uci set wireless.wifinet_home.mode='sta'
uci set wireless.wifinet_home.network='wwan'
uci set wireless.wifinet_home.ssid='${Q_HOME_SSID}'
uci set wireless.wifinet_home.encryption='psk2'
uci set wireless.wifinet_home.key='${Q_HOME_PASS}'
uci set wireless.wifinet_home.disabled='0'

# [5] Radio AP → punto de acceso para clientes
uci set wireless.wifinet_ap='wifi-iface'
uci set wireless.wifinet_ap.device='${WIFI_AP}'
uci set wireless.wifinet_ap.mode='ap'
uci set wireless.wifinet_ap.network='lan'
uci set wireless.wifinet_ap.ssid='${Q_AP_SSID}'
$(if [ -n "$AP_PASS" ]; then
    printf "uci set wireless.wifinet_ap.encryption='psk2'\n"
    printf "uci set wireless.wifinet_ap.key='%s'\n" "$Q_AP_PASS"
else
    printf "uci set wireless.wifinet_ap.encryption='none'\n"
    printf "uci -q delete wireless.wifinet_ap.key 2>/dev/null || true\n"
fi)
uci set wireless.wifinet_ap.disabled='0'

# [6] Agregar WWAN a la zona WAN del firewall
WAN_ZONE=\$(uci show firewall 2>/dev/null \
    | sed -n "s/^\(firewall\.[^.]*\)\.name='wan'\$/\1/p" | head -1)
if [ -n "\$WAN_ZONE" ]; then
    uci -q del_list "\${WAN_ZONE}.network=wwan" 2>/dev/null || true
    uci add_list "\${WAN_ZONE}.network=wwan"
else
    uci add_list firewall.@zone[1].network='wwan'
fi
UCI_SCRIPT

log_ok "UCI configurado"

# ── 7. Commit y aplicar ───────────────────────────────────────────────────────

log_info "[7] Guardando cambios (uci commit)..."
_r "uci commit network && uci commit wireless && uci commit firewall"

log_info "[8] Aplicando configuración WiFi..."
_r "wifi down 2>/dev/null || true; wifi up 2>/dev/null || wifi 2>/dev/null || true"

log_info "[9] Reiniciando red y firewall..."
_r "/etc/init.d/network restart 2>/dev/null || true; \
    /etc/init.d/firewall restart 2>/dev/null || true; \
    ifup wwan 2>/dev/null || true"

# ── Verificación automática ───────────────────────────────────────────────────
#
# Espera a que la radio levante y verifica:
#   1. wifi status  — interfaces y modo de operación
#   2. ifstatus wwan — IP asignada por DHCP de la red de casa
#   3. ping 8.8.8.8 — conectividad a Internet
# Si el ping falla, muestra el diagnóstico de WPA y un scan de la radio STA.

VERIFY_WAIT=15   # segundos para que la radio asocie antes de verificar

printf '\n'
log_ok "Configuración aplicada en ${HOST}."
log_info "Esperando ${VERIFY_WAIT}s para que la radio levante..."
sleep "$VERIFY_WAIT"

# ── wifi status ───────────────────────────────────────────────────────────────
printf '\n'
printf '══════════════════════════════════════════\n'
printf ' wifi status\n'
printf '══════════════════════════════════════════\n'
_r "wifi status 2>/dev/null || iw dev 2>/dev/null || echo '(wifi status no disponible)'"

# ── ifstatus wwan ─────────────────────────────────────────────────────────────
printf '\n'
printf '══════════════════════════════════════════\n'
printf ' ifstatus wwan  (IP asignada por red de casa)\n'
printf '══════════════════════════════════════════\n'
WWAN_STATUS=$(_r "ifstatus wwan 2>/dev/null || echo 'wwan no disponible'")
printf '%s\n' "$WWAN_STATUS"

# ── ping a Internet ───────────────────────────────────────────────────────────
printf '\n'
printf '══════════════════════════════════════════\n'
printf ' ping -c3 8.8.8.8  (conectividad a Internet)\n'
printf '══════════════════════════════════════════\n'
if _r "ping -c3 -W2 8.8.8.8" 2>/dev/null; then
    printf '\n'
    log_ok "Conectividad a Internet: OK"
    PING_OK=true
else
    printf '\n'
    log_warn "Sin respuesta de 8.8.8.8 — mostrando diagnóstico..."
    PING_OK=false
fi

# ── Diagnóstico si el ping falló ──────────────────────────────────────────────
if ! $PING_OK; then
    printf '\n'
    printf '══════════════════════════════════════════\n'
    printf ' logread | grep wpa  (errores de autenticación)\n'
    printf '══════════════════════════════════════════\n'
    _r "logread 2>/dev/null | grep -i wpa | tail -20 || echo '(sin entradas wpa en el log)'"

    printf '\n'
    printf '══════════════════════════════════════════\n'
    printf ' iwinfo %s scan  (redes visibles desde el router)\n' "$WIFI_STA"
    printf '══════════════════════════════════════════\n'
    _r "iwinfo ${WIFI_STA} scan 2>/dev/null || iw dev ${WIFI_STA} scan 2>/dev/null || echo '(scan no disponible)'"

    printf '\n'
    log_warn "Posibles causas:"
    log_warn "  • HOME_SSID o HOME_PASS incorrectos en el .env"
    log_warn "  • La red '${HOME_SSID}' no está en rango del router"
    log_warn "  • El radio ${WIFI_STA} no soporta la banda de la red de casa"
    printf '\n'
    printf '  Para revertir los cambios en el router:\n'
    printf '    ssh %s@%s\n' "$SSH_USER" "$HOST"
    printf '    cp /etc/config/wireless.bak.%s /etc/config/wireless\n' "$TS"
    printf '    cp /etc/config/network.bak.%s  /etc/config/network\n'  "$TS"
    printf '    uci commit wireless network && wifi\n'
    printf '\n'
    exit 1
fi

printf '\n'
printf '  Backup guardado en el router:\n'
printf '    /etc/config/wireless.bak.%s\n' "$TS"
printf '    /etc/config/network.bak.%s\n'  "$TS"
printf '\n'
