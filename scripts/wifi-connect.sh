#!/bin/bash
# wifi-connect.sh — Conecta un dispositivo a una red WiFi en modo cliente
#
# Compatible con:
#   • OpenWrt (router) — usa UCI + wifi reload
#   • DietPi / Debian (Raspberry Pi) — usa nmcli (NetworkManager) con
#     fallback a wpa_supplicant si NM no está disponible
#
# El script detecta automáticamente el OS del destino vía SSH.
#
# Uso:
#   bash scripts/wifi-connect.sh [opciones]
#
# Opciones obligatorias:
#   --ssid   <SSID>          Nombre de la red WiFi
#   --pass   <contraseña>    Contraseña (omitir o dejar vacío para red abierta)
#
# Opciones de destino (default: router):
#   --host   <IP>            IP del dispositivo destino  (default: $ROUTER_IP)
#   --user   <usuario>       Usuario SSH                 (default: root)
#   --key    <ruta>          Llave SSH privada           (default: auto según host)
#
# Opciones WiFi:
#   --enc    <tipo>          Tipo de cifrado             (default: wpa2)
#                              none | open               — red abierta
#                              wep                       — WEP (legacy, no recomendado)
#                              wpa  | wpa-psk            — WPA personal
#                              wpa2 | wpa2-psk | psk2    — WPA2 personal (más común)
#                              wpa3 | sae                — WPA3 personal
#                              wpa2+wpa3                 — transición WPA2/WPA3
#   --iface  <interfaz>      Interfaz WiFi               (default: auto-detect)
#   --name   <nombre>        Nombre de conexión NM       (default: igual que SSID)
#
# Opciones de comportamiento:
#   --no-verify              No verificar conectividad tras aplicar
#   --timeout  <s>           Segundos a esperar por IP DHCP (default: 30)
#   --dry-run                Mostrar comandos sin ejecutarlos
#   --verbose                Mostrar output SSH completo
#
# Ejemplos:
#   # Router (OpenWrt) a WPA2:
#   bash scripts/wifi-connect.sh --ssid MiRed --pass S3cr3to
#
#   # Router a WPA3:
#   bash scripts/wifi-connect.sh --ssid MiRed --pass S3cr3to --enc wpa3
#
#   # Raspberry Pi 4B a WPA2:
#   bash scripts/wifi-connect.sh --host 192.168.1.167 --ssid MiRed --pass S3cr3to
#
#   # Red abierta sin contraseña:
#   bash scripts/wifi-connect.sh --host 192.168.1.181 --ssid HotspotPublico --enc none
#
#   # Ver qué haría sin ejecutar:
#   bash scripts/wifi-connect.sh --ssid MiRed --pass S3cr3to --dry-run

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

# ─── Colores ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

hdr()  { printf "\n${BOLD}${CYAN}━━━ %s ━━━${NC}\n" "$*"; }
ok()   { printf "  ${GREEN}✓${NC} %s\n" "$*"; }
fail() { printf "  ${RED}✗${NC} %s\n" "$*" >&2; }
warn() { printf "  ${YELLOW}!${NC} %s\n" "$*"; }
info() { printf "  ${BLUE}·${NC} %s\n" "$*"; }
die()  { printf "${RED}ERROR${NC}: %s\n" "$*" >&2; exit 1; }

# ─── Valores por defecto ──────────────────────────────────────────────────────
TARGET_HOST=""          # se asigna después de parsear args (default = ROUTER_IP)
TARGET_USER="root"
TARGET_KEY=""           # auto según host
WIFI_SSID=""
WIFI_PASS=""
WIFI_ENC="wpa2"
WIFI_IFACE=""           # auto-detect en el destino
CONN_NAME=""            # nombre de conexión NM (default = SSID)
NO_VERIFY=false
DHCP_TIMEOUT=30
DRY_RUN=false
VERBOSE=false

# ─── Parseo de argumentos ─────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --ssid)      WIFI_SSID="$2";    shift 2 ;;
        --pass)      WIFI_PASS="$2";    shift 2 ;;
        --enc)       WIFI_ENC="$2";     shift 2 ;;
        --iface)     WIFI_IFACE="$2";   shift 2 ;;
        --name)      CONN_NAME="$2";    shift 2 ;;
        --host)      TARGET_HOST="$2";  shift 2 ;;
        --user)      TARGET_USER="$2";  shift 2 ;;
        --key)       TARGET_KEY="$2";   shift 2 ;;
        --timeout)   DHCP_TIMEOUT="$2"; shift 2 ;;
        --no-verify) NO_VERIFY=true;    shift ;;
        --dry-run)   DRY_RUN=true;      shift ;;
        --verbose)   VERBOSE=true;      shift ;;
        --help|-h)
            sed -n '2,55p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *) die "Argumento desconocido: $1 (usa --help)" ;;
    esac
done

# ─── Validaciones básicas ─────────────────────────────────────────────────────
[ -n "$WIFI_SSID" ] || die "--ssid es obligatorio"

# Normalizar tipo de cifrado a canonical interno
case "${WIFI_ENC,,}" in
    none|open|"")          WIFI_ENC="none" ;;
    wep)                   WIFI_ENC="wep" ;;
    wpa|wpa-psk)           WIFI_ENC="wpa" ;;
    wpa2|wpa2-psk|psk2)    WIFI_ENC="wpa2" ;;
    wpa3|sae)              WIFI_ENC="wpa3" ;;
    wpa2+wpa3|psk2+sae)    WIFI_ENC="wpa2+wpa3" ;;
    *) die "Tipo de cifrado no reconocido: $WIFI_ENC
  Valores válidos: none, wep, wpa, wpa2, wpa3, wpa2+wpa3" ;;
esac

# Contraseña requerida para cifrados que la usan
if [[ "$WIFI_ENC" != "none" && -z "$WIFI_PASS" ]]; then
    die "Se requiere --pass para cifrado '$WIFI_ENC'"
fi

# WEP ya no debería usarse pero lo soportamos con advertencia
[[ "$WIFI_ENC" == "wep" ]] && warn "WEP es inseguro — úsalo solo si es estrictamente necesario"

# SSID como nombre de conexión por defecto
CONN_NAME="${CONN_NAME:-$WIFI_SSID}"

# Host destino: si no se especificó → router
TARGET_HOST="${TARGET_HOST:-$ROUTER_IP}"

# ─── SSH helpers ──────────────────────────────────────────────────────────────
# Seleccionar llave SSH según destino
_resolve_ssh_key() {
    if [[ -n "$TARGET_KEY" ]]; then
        echo "$TARGET_KEY"
    elif [[ "$TARGET_HOST" == "$ROUTER_IP" ]]; then
        echo "$SSH_KEY"
    else
        # Raspberry Pi u otro host: usar agente o id_rsa estándar
        echo ""
    fi
}

_build_ssh_opts() {
    local key
    key="$(_resolve_ssh_key)"
    local opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                -o BatchMode=yes -o ConnectTimeout=10 -o LogLevel=ERROR"
    [[ -n "$key" ]] && opts="-i $key $opts"
    echo "$opts"
}

target_ssh() {
    local ssh_opts
    ssh_opts="$(_build_ssh_opts)"
    if $VERBOSE; then
        # shellcheck disable=SC2086
        ssh $ssh_opts "${TARGET_USER}@${TARGET_HOST}" "$@"
    else
        # shellcheck disable=SC2086
        ssh $ssh_opts "${TARGET_USER}@${TARGET_HOST}" "$@" 2>/dev/null
    fi
}

target_ssh_verbose() {
    local ssh_opts
    ssh_opts="$(_build_ssh_opts)"
    # shellcheck disable=SC2086
    ssh $ssh_opts "${TARGET_USER}@${TARGET_HOST}" "$@"
}

run() {
    # Ejecuta localmente o imprime en dry-run
    if $DRY_RUN; then
        printf "  [dry-run] %s\n" "$*"
    else
        "$@"
    fi
}

# ─── Cabecera ─────────────────────────────────────────────────────────────────
printf "\n${BOLD}╔══════════════════════════════════════════════════╗${NC}\n"
printf   "${BOLD}║  WiFi Connect                        %-11s║${NC}\n" "$(date '+%H:%M:%S')"
printf   "${BOLD}╚══════════════════════════════════════════════════╝${NC}\n"
printf "  Destino  : %s@%s\n" "$TARGET_USER" "$TARGET_HOST"
printf "  SSID     : %s\n"    "$WIFI_SSID"
printf "  Cifrado  : %s\n"    "$WIFI_ENC"
printf "  Interfaz : %s\n"    "${WIFI_IFACE:-auto-detect}"
[[ "$WIFI_ENC" != "none" ]] && printf "  Pass     : %s\n" "$(printf '%*s' ${#WIFI_PASS} | tr ' ' '*')"
$DRY_RUN && printf "  ${YELLOW}Modo dry-run — no se ejecutan cambios${NC}\n"

# ─── PASO 1: Verificar conectividad SSH ───────────────────────────────────────
hdr "1. Verificando acceso SSH"

if ! ping -c1 -W3 "$TARGET_HOST" &>/dev/null; then
    die "Host $TARGET_HOST no responde a ping"
fi
ok "Ping a $TARGET_HOST OK"

if ! target_ssh "echo pong" 2>/dev/null | grep -q pong; then
    die "SSH a ${TARGET_USER}@${TARGET_HOST} falló
  Verifica la llave SSH o usa --key para especificar una distinta"
fi
ok "SSH a ${TARGET_USER}@${TARGET_HOST} OK"

# ─── PASO 2: Detectar OS del destino ─────────────────────────────────────────
hdr "2. Detectando OS del destino"

OS_TYPE=""
if target_ssh "command -v uci" 2>/dev/null | grep -q uci; then
    OS_TYPE="openwrt"
    ok "Detectado: OpenWrt (UCI disponible)"
elif target_ssh "command -v nmcli" 2>/dev/null | grep -q nmcli; then
    OS_TYPE="debian_nm"
    ok "Detectado: Debian/DietPi con NetworkManager"
elif target_ssh "command -v wpa_supplicant" 2>/dev/null | grep -q wpa_supplicant; then
    OS_TYPE="debian_wpa"
    ok "Detectado: Debian/DietPi con wpa_supplicant"
else
    die "No se pudo detectar el método de configuración WiFi en $TARGET_HOST
  Se requiere: uci (OpenWrt), nmcli (NetworkManager) o wpa_supplicant (Debian)"
fi

# ─── PASO 3: Detectar interfaz WiFi si no se especificó ──────────────────────
hdr "3. Detectando interfaz WiFi"

if [[ -z "$WIFI_IFACE" ]]; then
    if [[ "$OS_TYPE" == "openwrt" ]]; then
        # En OpenWrt la interfaz lógica UCI no es wlan0 — detectar radio disponible
        WIFI_IFACE="$(target_ssh "
            for sec in \$(uci show wireless | sed -n 's/^wireless\\.\\([^=]*\\)=wifi-device\$/\\1/p'); do
                echo \"\$sec\"
                break
            done
        " 2>/dev/null || echo "radio0")"
        info "Radio UCI seleccionada: $WIFI_IFACE"
    else
        # Debian: buscar primer wlan* o wlp* disponible
        WIFI_IFACE="$(target_ssh "
            iface=''
            for dev in /sys/class/net/wlan* /sys/class/net/wlp*; do
                [ -e \"\$dev\" ] || continue
                iface=\"\$(basename \$dev)\"
                break
            done
            # Fallback: ip link
            if [ -z \"\$iface\" ]; then
                iface=\"\$(ip -o link show | awk -F': ' '\$2~/^wl/{print \$2; exit}' 2>/dev/null || echo '')\"
            fi
            echo \"\${iface:-wlan0}\"
        " 2>/dev/null || echo "wlan0")"
        info "Interfaz detectada: $WIFI_IFACE"
    fi
fi
ok "Interfaz WiFi: $WIFI_IFACE"

# ─── PASO 4: Aplicar configuración según OS ───────────────────────────────────
hdr "4. Configurando WiFi cliente"

# ── 4a: OpenWrt (UCI) ─────────────────────────────────────────────────────────
if [[ "$OS_TYPE" == "openwrt" ]]; then
    # Mapear cifrado canónico → valor UCI
    case "$WIFI_ENC" in
        none)       UCI_ENC="none" ;;
        wep)        UCI_ENC="wep" ;;
        wpa)        UCI_ENC="psk" ;;
        wpa2)       UCI_ENC="psk2" ;;
        wpa3)       UCI_ENC="sae" ;;
        wpa2+wpa3)  UCI_ENC="psk2+sae" ;;
    esac
    info "Cifrado UCI: $UCI_ENC"

    if $DRY_RUN; then
        info "[dry-run] Se aplicarían los siguientes comandos UCI en $TARGET_HOST:"
        cat <<EOF
  uci set wireless.sta_client=wifi-iface
  uci set wireless.sta_client.device=$WIFI_IFACE
  uci set wireless.sta_client.mode=sta
  uci set wireless.sta_client.ssid=$WIFI_SSID
  uci set wireless.sta_client.encryption=$UCI_ENC
  [uci set wireless.sta_client.key=****]
  uci commit wireless
  wifi reload
EOF
    else
        target_ssh_verbose "
            set -eu
            SSID='$WIFI_SSID'
            ENC='$UCI_ENC'
            PASS='$WIFI_PASS'
            RADIO='$WIFI_IFACE'

            # Crear/sobrescribir interfaz STA cliente
            uci set wireless.sta_client='wifi-iface'
            uci set wireless.sta_client.device=\"\$RADIO\"
            uci set wireless.sta_client.mode='sta'
            uci set wireless.sta_client.network='wwan'
            uci set wireless.sta_client.ssid=\"\$SSID\"
            uci set wireless.sta_client.encryption=\"\$ENC\"
            uci set wireless.sta_client.disabled='0'

            # Clave solo si se necesita
            if [ \"\$ENC\" = 'none' ]; then
                uci -q delete wireless.sta_client.key || true
            else
                uci set wireless.sta_client.key=\"\$PASS\"
            fi

            # Asegurar interfaz de red wwan para DHCP
            uci set network.wwan='interface'
            uci set network.wwan.proto='dhcp'
            uci set network.wwan.metric='20'

            uci commit wireless
            uci commit network

            echo '[OK] UCI commiteado'
            wifi reload >/dev/null 2>&1 || wifi >/dev/null 2>&1 || true
            echo '[OK] wifi reload ejecutado'
        "
    fi
fi

# ── 4b: Debian/DietPi con NetworkManager ──────────────────────────────────────
if [[ "$OS_TYPE" == "debian_nm" ]]; then
    # Mapear cifrado canónico → key-mgmt de nmcli
    case "$WIFI_ENC" in
        none)       NM_SECURITY="" ;;
        wep)        NM_SECURITY="wep" ;;
        wpa)        NM_SECURITY="wpa-psk" ;;
        wpa2)       NM_SECURITY="wpa-psk" ;;
        wpa3)       NM_SECURITY="sae" ;;
        wpa2+wpa3)  NM_SECURITY="wpa-psk" ;;   # NM negocia automáticamente
    esac
    info "Cifrado NM key-mgmt: ${NM_SECURITY:-ninguno (open)}"

    if $DRY_RUN; then
        info "[dry-run] Se aplicarían los siguientes comandos nmcli en $TARGET_HOST:"
        if [[ "$WIFI_ENC" == "none" ]]; then
            echo "  nmcli device wifi connect '$WIFI_SSID' ifname $WIFI_IFACE name '$CONN_NAME'"
        else
            echo "  nmcli device wifi connect '$WIFI_SSID' password '****' ifname $WIFI_IFACE name '$CONN_NAME'"
            [[ "$WIFI_ENC" == "wpa3" ]] && echo "  nmcli connection modify '$CONN_NAME' wifi-sec.key-mgmt sae"
        fi
    else
        target_ssh_verbose "
            set -eu
            SSID='$WIFI_SSID'
            PASS='$WIFI_PASS'
            IFACE='$WIFI_IFACE'
            CONN='$CONN_NAME'
            ENC='$WIFI_ENC'
            NM_SEC='$NM_SECURITY'
            TIMEOUT='$DHCP_TIMEOUT'

            # Eliminar conexión previa con el mismo nombre si existe
            nmcli connection delete \"\$CONN\" 2>/dev/null || true

            echo '[NM] Conectando a SSID: '\$SSID' en '\$IFACE
            if [ \"\$ENC\" = 'none' ]; then
                nmcli device wifi connect \"\$SSID\" ifname \"\$IFACE\" name \"\$CONN\"
            else
                nmcli device wifi connect \"\$SSID\" password \"\$PASS\" \
                    ifname \"\$IFACE\" name \"\$CONN\"
            fi

            # WPA3: forzar SAE explícitamente
            if [ \"\$ENC\" = 'wpa3' ]; then
                nmcli connection modify \"\$CONN\" wifi-sec.key-mgmt sae
                nmcli connection up \"\$CONN\" ifname \"\$IFACE\"
            fi

            echo '[NM] Esperando dirección IP (máx '\${TIMEOUT}s)...'
            waited=0
            while [ \"\$waited\" -lt \"\$TIMEOUT\" ]; do
                ip=\$(ip -4 addr show \"\$IFACE\" 2>/dev/null | awk '/inet /{print \$2; exit}')
                if [ -n \"\$ip\" ]; then
                    echo \"[NM] IP obtenida: \$ip\"
                    break
                fi
                sleep 2; waited=\$((waited + 2))
            done
            [ -z \"\$ip\" ] && echo '[NM] WARN: No se obtuvo IP en '\$TIMEOUT's'
            nmcli device status
        "
    fi
fi

# ── 4c: Debian/DietPi con wpa_supplicant (sin NetworkManager) ─────────────────
if [[ "$OS_TYPE" == "debian_wpa" ]]; then
    # Mapear cifrado canónico → key_mgmt de wpa_supplicant
    case "$WIFI_ENC" in
        none)       WPA_KEY_MGMT="NONE" ;;
        wep)        WPA_KEY_MGMT="NONE" ;;   # WEP usa key_mgmt NONE + wep_key
        wpa)        WPA_KEY_MGMT="WPA-PSK" ;;
        wpa2)       WPA_KEY_MGMT="WPA-PSK" ;;
        wpa3)       WPA_KEY_MGMT="SAE" ;;
        wpa2+wpa3)  WPA_KEY_MGMT="WPA-PSK SAE" ;;
    esac
    info "Cifrado wpa_supplicant key_mgmt: $WPA_KEY_MGMT"

    if $DRY_RUN; then
        info "[dry-run] Se modificaría /etc/wpa_supplicant/wpa_supplicant.conf en $TARGET_HOST"
        info "[dry-run] Se ejecutaría: wpa_cli reconfigure && dhclient $WIFI_IFACE"
    else
        target_ssh_verbose "
            set -eu
            SSID='$WIFI_SSID'
            PASS='$WIFI_PASS'
            IFACE='$WIFI_IFACE'
            ENC='$WIFI_ENC'
            KEY_MGMT='$WPA_KEY_MGMT'
            CONF='/etc/wpa_supplicant/wpa_supplicant.conf'

            # Encabezado si el fichero no existe
            if [ ! -f \"\$CONF\" ]; then
                cat > \"\$CONF\" <<CONFHDR
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=MX
CONFHDR
            fi

            # Construir bloque de red
            if [ \"\$ENC\" = 'none' ]; then
                NETBLOCK=\"network={\\n  ssid=\\\"\$SSID\\\"\\n  key_mgmt=NONE\\n}\"
            elif [ \"\$ENC\" = 'wep' ]; then
                NETBLOCK=\"network={\\n  ssid=\\\"\$SSID\\\"\\n  key_mgmt=NONE\\n  wep_key0=\\\"\$PASS\\\"\\n  wep_tx_keyidx=0\\n}\"
            else
                # Generar bloque con wpa_passphrase (oscurece la clave en claro)
                NETBLOCK=\"\$(wpa_passphrase \"\$SSID\" \"\$PASS\" | grep -v '\\s*#')\"
                # Añadir key_mgmt si no es el default
                if [ \"\$KEY_MGMT\" != 'WPA-PSK' ]; then
                    NETBLOCK=\"\$(echo \"\$NETBLOCK\" | sed \"s/}/  key_mgmt=\$KEY_MGMT\\n}/\")\"
                fi
            fi

            # Eliminar bloques previos con el mismo SSID
            python3 -c \"
import re, sys
conf = open('\$CONF').read()
# Eliminar bloques network{} que contengan ssid=\\\"SSID\\\"
escaped_ssid = '$WIFI_SSID'.replace('\\\"', '\\\\\\\"')
pattern = r'network\s*=\s*\{[^}]*ssid\s*=\s*\\\"' + re.escape(escaped_ssid) + r'\\\"[^}]*\}'
conf = re.sub(pattern, '', conf, flags=re.DOTALL)
open('\$CONF', 'w').write(conf.strip() + '\n')
\" 2>/dev/null || sed -i \"/network={/,/}/d\" \"\$CONF\" || true

            # Añadir nuevo bloque
            printf '\n%b\n' \"\$NETBLOCK\" >> \"\$CONF\"
            echo '[WPA] Bloque de red escrito en '\$CONF

            # Recargar wpa_supplicant
            if wpa_cli -i \"\$IFACE\" reconfigure 2>/dev/null | grep -q OK; then
                echo '[WPA] wpa_cli reconfigure OK'
            else
                # Reiniciar servicio como fallback
                systemctl restart \"wpa_supplicant@\${IFACE}.service\" 2>/dev/null || \
                systemctl restart wpa_supplicant 2>/dev/null || \
                killall -HUP wpa_supplicant 2>/dev/null || true
                echo '[WPA] servicio wpa_supplicant reiniciado'
            fi

            # Obtener IP por DHCP
            echo '[WPA] Solicitando IP DHCP en '\$IFACE
            dhclient -v \"\$IFACE\" 2>&1 | tail -5 || \
            dhcpcd \"\$IFACE\" 2>/dev/null || true

            # Verificar
            sleep 3
            ip=\$(ip -4 addr show \"\$IFACE\" 2>/dev/null | awk '/inet /{print \$2; exit}')
            if [ -n \"\$ip\" ]; then
                echo \"[WPA] IP obtenida: \$ip\"
            else
                echo '[WPA] WARN: No se obtuvo IP — verifica wpa_supplicant y dhclient'
            fi
        "
    fi
fi

# ─── PASO 5: Verificación de conectividad ─────────────────────────────────────
if $NO_VERIFY || $DRY_RUN; then
    $DRY_RUN && info "[dry-run] Se omitiría la verificación de conectividad"
    $NO_VERIFY && info "Verificación omitida (--no-verify)"
else
    hdr "5. Verificando conectividad"

    # Esperar un momento para que la conexión estabilice
    sleep 3

    # Para OpenWrt esperamos que la interfaz wwan obtenga IP
    if [[ "$OS_TYPE" == "openwrt" ]]; then
        info "Esperando dirección DHCP en wwan (máx ${DHCP_TIMEOUT}s)..."
        waited=0
        IP_OBTAINED=""
        while [[ $waited -lt $DHCP_TIMEOUT ]]; do
            IP_OBTAINED="$(target_ssh "
                ifstatus wwan 2>/dev/null | grep -o '\"address\":\"[^\"]*\"' | head -1 | cut -d'\"' -f4 || \
                ip -4 addr show 2>/dev/null | grep -A2 wlan | awk '/inet /{print \$2; exit}' || echo ''
            " 2>/dev/null || echo "")"
            [[ -n "$IP_OBTAINED" ]] && break
            sleep 5; waited=$((waited + 5))
        done

        if [[ -n "$IP_OBTAINED" ]]; then
            ok "IP obtenida en wwan: $IP_OBTAINED"
        else
            warn "No se obtuvo IP en ${DHCP_TIMEOUT}s — verifica:"
            info "  router: ifstatus wwan"
            info "  router: logread | grep wpa"
        fi

        # Prueba DNS/internet desde el router
        info "Prueba de resolución DNS desde el router..."
        if target_ssh "nslookup google.com 2>/dev/null | grep -q Address"; then
            ok "DNS funciona desde el router"
        else
            warn "DNS no responde — puede ser normal si DHCP aún no asignó IP"
        fi

    else
        # Debian: verificar IP en la interfaz
        info "Verificando dirección IP en $WIFI_IFACE..."
        IFACE_IP="$(target_ssh "
            ip -4 addr show '$WIFI_IFACE' 2>/dev/null | awk '/inet /{print \$2; exit}' || echo ''
        " 2>/dev/null || echo "")"

        if [[ -n "$IFACE_IP" ]]; then
            ok "IP asignada: $IFACE_IP en $WIFI_IFACE"
        else
            warn "Sin IP en $WIFI_IFACE — puede necesitar más tiempo"
        fi

        # Prueba de conectividad hacia internet
        info "Prueba de acceso a internet (ping 8.8.8.8)..."
        if target_ssh "ping -c2 -W3 8.8.8.8 >/dev/null 2>&1"; then
            ok "Acceso a internet OK"
        else
            warn "Sin acceso a internet (ping 8.8.8.8 falló)"
        fi
    fi
fi

# ─── Resumen ──────────────────────────────────────────────────────────────────
hdr "Resumen"
info "Destino    : ${TARGET_USER}@${TARGET_HOST}"
info "OS         : ${OS_TYPE}"
info "SSID       : ${WIFI_SSID}"
info "Cifrado    : ${WIFI_ENC}"
info "Interfaz   : ${WIFI_IFACE}"

printf "\n${BOLD}${GREEN}✓ WiFi cliente configurado correctamente.${NC}\n\n"
printf "  Comandos útiles para verificar en el destino:\n"

if [[ "$OS_TYPE" == "openwrt" ]]; then
    printf "    ssh root@%s 'ifstatus wwan'\n" "$TARGET_HOST"
    printf "    ssh root@%s 'iwinfo'\n" "$TARGET_HOST"
    printf "    ssh root@%s 'logread | grep -i wpa'\n" "$TARGET_HOST"
else
    printf "    ssh %s@%s 'nmcli device status'\n" "$TARGET_USER" "$TARGET_HOST"
    printf "    ssh %s@%s 'ip addr show %s'\n" "$TARGET_USER" "$TARGET_HOST" "$WIFI_IFACE"
    printf "    ssh %s@%s 'ping -c3 8.8.8.8'\n" "$TARGET_USER" "$TARGET_HOST"
fi
printf "\n"
