#!/bin/sh
# setup-openwrt-wifi-repeater.sh
#
# Convierte el OpenWrt en repetidor WiFi:
#   radio STA  → cliente hacia la red de casa    (WWAN / WAN)
#   radio AP   → AP para los clientes del portal (LAN)
#
# Las credenciales se cargan desde un archivo .env, NO están en el script.
#
# Uso:
#   sh setup-openwrt-wifi-repeater.sh
#   sh setup-openwrt-wifi-repeater.sh --env-file /ruta/al/archivo.env
#   sh setup-openwrt-wifi-repeater.sh --dry-run
#   sh setup-openwrt-wifi-repeater.sh --help
#
# Archivo .env (ver secrets/openwrt.env.example en el repo):
#   HOME_SSID="NombreWiFiCasa"
#   HOME_PASS="PasswordCasa"
#   AP_SSID="OpenWrt-Portal"
#   AP_PASS="PasswordAP"
#
# Preparar en la máquina de desarrollo:
#   cp secrets/openwrt.env.example secrets/openwrt.env
#   # editar con valores reales, luego:
#   scp secrets/openwrt.env root@192.168.1.1:/etc/wifi-repeater.env
#   ssh root@192.168.1.1 "chmod 600 /etc/wifi-repeater.env"
#   ssh root@192.168.1.1 "sh /tmp/setup-openwrt-wifi-repeater.sh"

set -eu

# ── Logging ───────────────────────────────────────────────────────────────────

log_info()  { printf '[INFO]  %s\n' "$*"; }
log_ok()    { printf '[OK]    %s\n' "$*"; }
log_warn()  { printf '[WARN]  %s\n' "$*"; }
log_error() { printf '[ERROR] %s\n' "$*" >&2; }
die()       { log_error "$*"; exit 1; }

# ── Flags ─────────────────────────────────────────────────────────────────────

ENV_FILE=""
DRY_RUN=false

while [ $# -gt 0 ]; do
    case "$1" in
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
            sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            die "Argumento desconocido: $1  (usa --help)"
            ;;
    esac
done

# ── Cargar .env ───────────────────────────────────────────────────────────────
#
# Orden de búsqueda (el primero que exista):
#   1. --env-file <ruta>  (argumento explícito)
#   2. /etc/wifi-repeater.env  (ubicación estándar en el router)
#   3. $(dirname $0)/openwrt.env  (junto al script, para desarrollo)

_load_env() {
    local f="$1"
    # Validaciones de seguridad antes de sourcing
    [ -f "$f" ]           || { log_warn "Archivo no encontrado: $f"; return 1; }
    [ -r "$f" ]           || die "Sin permiso de lectura: $f"

    # Verificar permisos (en BusyBox, stat -c no siempre existe; usar ls)
    local perms
    perms=$(ls -la "$f" 2>/dev/null | awk '{print $1}')
    case "$perms" in
        # Aceptar -rw------- (600) o -r-------- (400)
        -rw-------|-r--------)
            ;;
        # Advertir si otros usuarios pueden leer
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

if [ -n "$ENV_FILE" ]; then
    # Ruta explícita — si falla, abortar
    _load_env "$ENV_FILE" || die "No se pudo cargar el archivo .env: $ENV_FILE"
    ENV_LOADED=true
else
    # Búsqueda automática
    for candidate in \
        "/etc/wifi-repeater.env" \
        "$(dirname "$0")/openwrt.env" \
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
    log_error "  1. Crear /etc/wifi-repeater.env con el contenido:"
    log_error "       HOME_SSID=\"NombreWiFiCasa\""
    log_error "       HOME_PASS=\"PasswordCasa\""
    log_error "       AP_SSID=\"OpenWrt-Portal\""
    log_error "       AP_PASS=\"PasswordAP\""
    log_error "     chmod 600 /etc/wifi-repeater.env"
    log_error ""
    log_error "  2. Pasar la ruta explícita:"
    log_error "     sh $0 --env-file /ruta/archivo.env"
    log_error ""
    log_error "  Ver plantilla en: secrets/openwrt.env.example (repositorio)"
    exit 1
fi

# ── Validar variables obligatorias ────────────────────────────────────────────

_require_var() {
    local name="$1"
    eval "val=\${$name:-}"
    [ -n "$val" ] || die "Variable obligatoria no definida en el .env: $name"
}

_require_var HOME_SSID
_require_var HOME_PASS
_require_var AP_SSID
_require_var AP_PASS

# Validación básica de longitud (WPA2: 8-63 caracteres)
[ ${#HOME_PASS} -ge 8 ] || die "HOME_PASS demasiado corta (mínimo 8 caracteres para WPA2)"
[ ${#AP_PASS}   -ge 8 ] || die "AP_PASS demasiado corta (mínimo 8 caracteres para WPA2)"

log_ok "Credenciales cargadas — HOME_SSID='${HOME_SSID}' AP_SSID='${AP_SSID}'"
log_info "(Las contraseñas no se muestran en logs)"

# ── Autodetectar radios ───────────────────────────────────────────────────────
#
# Usa los valores del .env si están definidos; si no, detecta por banda.
# Confirmado con: wifi status → radio0=2g, radio1=5g

_detect_radios() {
    local r2g="" r5g=""
    for dev in $(uci show wireless | sed -n "s/^wireless\.\([^=]*\)=wifi-device$/\1/p"); do
        band=$(uci -q get "wireless.$dev.band" 2>/dev/null || true)
        case "$band" in
            2g) [ -z "$r2g" ] && r2g="$dev" ;;
            5g) [ -z "$r5g" ] && r5g="$dev" ;;
        esac
        # Fallback: detectar por canal si la propiedad band no existe
        if [ -z "$r2g" ] || [ -z "$r5g" ]; then
            ch=$(uci -q get "wireless.$dev.channel" 2>/dev/null || true)
            case "$ch" in
                [1-9]|1[0-4])
                    [ -z "$r2g" ] && r2g="$dev" ;;
                3[6-9]|4[0-9]|5[0-9]|6[0-4]|1[0-4][0-9]|16[0-5])
                    [ -z "$r5g" ] && r5g="$dev" ;;
            esac
        fi
    done
    # Último recurso: defaults conocidos del hardware
    r2g="${r2g:-radio0}"
    r5g="${r5g:-radio1}"
    echo "$r2g $r5g"
}

# Permitir override desde el .env
if [ -z "${WIFI_STA:-}" ] || [ -z "${WIFI_AP:-}" ]; then
    log_info "Autodetectando radios..."
    DETECTED=$(_detect_radios)
    RADIO_STA=$(echo "$DETECTED" | cut -d' ' -f1)
    RADIO_AP=$(echo "$DETECTED"  | cut -d' ' -f2)
    WIFI_STA="${WIFI_STA:-$RADIO_STA}"
    WIFI_AP="${WIFI_AP:-$RADIO_AP}"
fi

log_info "Radio STA (cliente → casa): $WIFI_STA"
log_info "Radio AP  (para clientes):  $WIFI_AP"

[ "$WIFI_STA" != "$WIFI_AP" ] || \
    die "WIFI_STA y WIFI_AP no pueden ser el mismo radio ($WIFI_STA)"

# ── Dry-run info ──────────────────────────────────────────────────────────────

if $DRY_RUN; then
    log_info "--- DRY-RUN (sin cambios) ---"
    log_info "  HOME_SSID : $HOME_SSID"
    log_info "  AP_SSID   : $AP_SSID"
    log_info "  STA radio : $WIFI_STA"
    log_info "  AP  radio : $WIFI_AP"
    log_ok "Dry-run completado"
    exit 0
fi

# ── 1. Backup ─────────────────────────────────────────────────────────────────

log_info "[1] Backup de configuración..."
TS=$(date +%s)
cp /etc/config/wireless /etc/config/wireless.bak."$TS"
cp /etc/config/network  /etc/config/network.bak."$TS"
cp /etc/config/firewall /etc/config/firewall.bak."$TS"
log_ok "Backups en /etc/config/*.bak.$TS"

# ── 2. Interfaz WWAN ──────────────────────────────────────────────────────────

log_info "[2] Configurando interfaz WWAN (cliente WiFi → DHCP)..."
uci set network.wwan='interface'
uci set network.wwan.proto='dhcp'
uci set network.wwan.peerdns='1'
uci set network.wwan.defaultroute='1'
uci set network.wwan.metric='20'

# ── 3. Desactivar interfaces previas para evitar conflictos ───────────────────

log_info "[3] Desactivando interfaces wifi previas..."
for sec in $(uci show wireless 2>/dev/null | sed -n "s/^wireless\.\([^=]*\)=wifi-iface$/\1/p"); do
    case "$sec" in
        wifinet_home|wifinet_ap) ;;   # las nuestras — se sobreescriben abajo
        *) uci set "wireless.$sec.disabled=1" ;;
    esac
done

# ── 4. radio STA → cliente hacia la red de casa ───────────────────────────────

log_info "[4] Configurando $WIFI_STA como STA → '$HOME_SSID'..."
uci set wireless.wifinet_home='wifi-iface'
uci set wireless.wifinet_home.device="$WIFI_STA"
uci set wireless.wifinet_home.mode='sta'
uci set wireless.wifinet_home.network='wwan'
uci set wireless.wifinet_home.ssid="$HOME_SSID"
uci set wireless.wifinet_home.encryption='psk2'
uci set wireless.wifinet_home.key="$HOME_PASS"
uci set wireless.wifinet_home.disabled='0'

# ── 5. radio AP → punto de acceso para clientes ───────────────────────────────

log_info "[5] Configurando $WIFI_AP como AP → '$AP_SSID'..."
uci set wireless.wifinet_ap='wifi-iface'
uci set wireless.wifinet_ap.device="$WIFI_AP"
uci set wireless.wifinet_ap.mode='ap'
uci set wireless.wifinet_ap.network='lan'
uci set wireless.wifinet_ap.ssid="$AP_SSID"
uci set wireless.wifinet_ap.encryption='psk2'
uci set wireless.wifinet_ap.key="$AP_PASS"
uci set wireless.wifinet_ap.disabled='0'

# ── 6. Agregar WWAN a la zona WAN del firewall ────────────────────────────────

log_info "[6] Agregando wwan a zona WAN del firewall..."
WAN_ZONE=$(uci show firewall 2>/dev/null \
    | sed -n "s/^\(firewall\.[^.]*\)\.name='wan'$/\1/p" | head -1)
if [ -n "$WAN_ZONE" ]; then
    uci -q del_list "$WAN_ZONE.network=wwan" 2>/dev/null || true
    uci add_list "$WAN_ZONE.network=wwan"
    log_ok "Zona WAN: $WAN_ZONE"
else
    # Fallback: índice fijo (config default OpenWrt: zone[0]=LAN, zone[1]=WAN)
    log_warn "Zona WAN no encontrada por nombre — usando @zone[1]"
    uci add_list firewall.@zone[1].network='wwan'
fi

# ── 7. Guardar y aplicar ──────────────────────────────────────────────────────

log_info "[7] Guardando cambios (uci commit)..."
uci commit network
uci commit wireless
uci commit firewall

log_info "[8] Aplicando configuración WiFi..."
wifi down  2>/dev/null || true
wifi up    2>/dev/null || wifi 2>/dev/null || true

log_info "[9] Reiniciando red y firewall..."
/etc/init.d/network  restart 2>/dev/null || true
/etc/init.d/firewall restart 2>/dev/null || true

# Intentar levantar la interfaz WWAN explícitamente
ifup wwan 2>/dev/null || true

# ── Verificación ──────────────────────────────────────────────────────────────

printf '\n'
log_ok "Configuración aplicada."
printf '\n'
printf '  Verifica el estado con:\n'
printf '    wifi status\n'
printf '    ifstatus wwan\n'
printf '    ping -c3 8.8.8.8\n'
printf '\n'
printf '  Si no hay conectividad en 30s:\n'
printf '    logread | grep wpa\n'
printf '    iwinfo %s scan\n' "$WIFI_STA"
printf '\n'
printf '  Para revertir los cambios:\n'
printf '    cp /etc/config/wireless.bak.%s /etc/config/wireless\n' "$TS"
printf '    cp /etc/config/network.bak.%s  /etc/config/network\n'  "$TS"
printf '    uci commit wireless network && wifi\n'
printf '\n'
