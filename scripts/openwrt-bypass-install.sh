#!/bin/sh
# openwrt-bypass-install.sh — Instala en OpenWrt el servicio de bypass permanente
#
# PROBLEMA QUE RESUELVE:
#   Los sets nftables con "flags dynamic" no permiten elementos inline en la
#   definición del archivo .nft — los "elements = { ... timeout 0s }" del
#   captive-portal.nft son ignorados o fallan silenciosamente al cargar.
#   Tras un reboot, el set queda vacío y las Raspis + admin pierden el bypass.
#
# SOLUCIÓN:
#   Instala en el router un init.d service (captive-bypass-restore) que:
#     - Arranca con START=96 (después de fw4 firewall, que es START=95)
#     - Espera a que la tabla "ip captive" esté lista
#     - Re-agrega cada IP permanente con "nft add element ... timeout 0s"
#     - Registra el resultado en /var/log/captive-bypass.log
#     - Si la tabla no está lista en 30s, deja un warning y sale
#
#   Las IPs permanentes se guardan en /etc/captive-portal-bypass.conf
#   (una IP por línea) para poder añadir o quitar sin reescribir el servicio.
#
# USO:
#   bash scripts/openwrt-bypass-install.sh          # instalar/actualizar
#   bash scripts/openwrt-bypass-install.sh --test   # instalar + probar ahora
#   bash scripts/openwrt-bypass-install.sh --status # ver estado en el router
#   bash scripts/openwrt-bypass-install.sh --remove # desinstalar
#
# EJECUTAR DESDE: máquina admin
# REQUIERE: acceso SSH al router con /opt/keys/captive-portal

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

# ─── Argumentos ───────────────────────────────────────────────────────────────
DO_TEST=0; DO_STATUS=0; DO_REMOVE=0
for arg in "$@"; do
    case "$arg" in
        --test|-t)    DO_TEST=1 ;;
        --status|-s)  DO_STATUS=1 ;;
        --remove|-r)  DO_REMOVE=1 ;;
        --help|-h)
            sed -n '2,35p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *) log_warn "Argumento desconocido: $arg" ;;
    esac
done

# ─── Pre-flight ───────────────────────────────────────────────────────────────
check_ssh_key
test_router_ssh

# ─── Modo status ──────────────────────────────────────────────────────────────
if [ "$DO_STATUS" -eq 1 ]; then
    log_info "=== Estado de captive-bypass-restore en el router ==="
    printf '\n'

    log_info "Servicio init.d:"
    router_ssh '
        if [ -f /etc/init.d/captive-bypass-restore ]; then
            echo "  Instalado: /etc/init.d/captive-bypass-restore"
            if [ -L /etc/rc.d/S96captive-bypass-restore ]; then
                echo "  Habilitado: /etc/rc.d/S96captive-bypass-restore -> OK"
            else
                echo "  WARN: no habilitado (falta /etc/rc.d/S96captive-bypass-restore)"
            fi
        else
            echo "  NO instalado"
        fi
    ' 2>/dev/null

    printf '\n'
    log_info "IPs de bypass configuradas (/etc/captive-portal-bypass.conf):"
    router_ssh '
        if [ -f /etc/captive-portal-bypass.conf ]; then
            grep -v "^#" /etc/captive-portal-bypass.conf | grep -v "^$" \
                | sed "s/^/  /"
        else
            echo "  Archivo no encontrado"
        fi
    ' 2>/dev/null

    printf '\n'
    log_info "Set allowed_clients actual en nftables:"
    router_ssh 'nft list set ip captive allowed_clients 2>/dev/null || echo "  (tabla ip captive no encontrada)"' \
        2>/dev/null

    printf '\n'
    log_info "Último log del servicio:"
    router_ssh 'tail -20 /var/log/captive-bypass.log 2>/dev/null || echo "  (sin log)"' \
        2>/dev/null
    exit 0
fi

# ─── Modo remove ──────────────────────────────────────────────────────────────
if [ "$DO_REMOVE" -eq 1 ]; then
    log_info "=== Desinstalando captive-bypass-restore del router ==="
    router_ssh '
        /etc/init.d/captive-bypass-restore disable 2>/dev/null || true
        rm -f /etc/init.d/captive-bypass-restore
        rm -f /etc/captive-portal-bypass.conf
        rm -f /var/log/captive-bypass.log
        echo "Servicio desinstalado"
    ' 2>/dev/null
    log_ok "captive-bypass-restore eliminado del router"
    exit 0
fi

# ─── Instalación ──────────────────────────────────────────────────────────────
log_info "=== Instalando captive-bypass-restore en el router ==="
log_info "Router: $ROUTER_IP"
log_info "IPs permanentes a proteger:"
log_info "  Admin:       $ADMIN_IP"
log_info "  RafexPi4B:   $RASPI4B_IP"
log_info "  RafexPi3B-A: $RASPI3B_IP"
log_info "  RafexPi3B-B: $PORTAL_NODE_IP"
log_info "  AP Extender: $AP_EXTENDER_IP"
log_info "  Portal activo: $PORTAL_IP"

# ─── PASO 1: Archivo de configuración de IPs ──────────────────────────────────
log_info "--- PASO 1: /etc/captive-portal-bypass.conf ---"

router_ssh "cat > /etc/captive-portal-bypass.conf" <<EOF
# /etc/captive-portal-bypass.conf
# IPs de infraestructura con bypass permanente al captive portal.
# Estas IPs NUNCA expiran del set allowed_clients (timeout 0s).
# Formato: una IP por línea. Líneas con # son comentarios.
# Editado por: openwrt-bypass-install.sh
# Última actualización: $(date '+%Y-%m-%d %H:%M:%S')
#
# NUNCA quitar estas IPs — son la infraestructura de la PoC.

# Router
$ROUTER_IP

# Máquina admin (laptop de desarrollo)
$ADMIN_IP

# RafexPi4B — analizador IA + k3s + llama.cpp
$RASPI4B_IP

# RafexPi3B-A — sensor de red (tshark)
$RASPI3B_IP

# RafexPi3B-B — nodo portal (podman)
$PORTAL_NODE_IP

# AP Extender
$AP_EXTENDER_IP
EOF

log_ok "Archivo de IPs creado: /etc/captive-portal-bypass.conf"

# ─── PASO 2: init.d service ────────────────────────────────────────────────────
log_info "--- PASO 2: /etc/init.d/captive-bypass-restore ---"

router_ssh "cat > /etc/init.d/captive-bypass-restore" <<'INITD_EOF'
#!/bin/sh /etc/rc.common
# /etc/init.d/captive-bypass-restore
#
# Restaura las IPs de bypass permanente en el set nftables allowed_clients
# después de cada arranque del firewall (fw4).
#
# Por qué es necesario:
#   Los sets nftables con "flags dynamic" no conservan sus elementos al
#   recargar la tabla desde un archivo .nft — los "elements = { ... }"
#   son ignorados. Este servicio los re-agrega cada vez que fw4 arranca.
#
# START=96: se ejecuta después de fw4 (firewall, START=95)

USE_PROCD=0          # compatibilidad con OpenWrt sin procd para este caso
START=96
STOP=10

CONF_FILE="/etc/captive-portal-bypass.conf"
NFT_TABLE="ip captive"
NFT_SET="allowed_clients"
LOG_FILE="/var/log/captive-bypass.log"
MAX_WAIT_S=45        # segundos máximos esperando a que fw4 levante la tabla

log_ts() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" | tee -a "$LOG_FILE"
}

wait_for_table() {
    local waited=0
    while [ "$waited" -lt "$MAX_WAIT_S" ]; do
        if nft list table $NFT_TABLE >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    return 1
}

start() {
    log_ts "=== captive-bypass-restore START ==="

    if [ ! -f "$CONF_FILE" ]; then
        log_ts "ERROR: $CONF_FILE no encontrado — no hay IPs de bypass configuradas"
        return 1
    fi

    log_ts "Esperando tabla '$NFT_TABLE' (max ${MAX_WAIT_S}s)..."
    if ! wait_for_table; then
        log_ts "ERROR: La tabla '$NFT_TABLE' no apareció en ${MAX_WAIT_S}s."
        log_ts "Verifica que /etc/captive-portal.nft y el include de fw4 estén correctos."
        return 1
    fi
    log_ts "Tabla '$NFT_TABLE' lista."

    local ok=0
    local fail=0
    local skip=0

    while IFS= read -r line; do
        # Ignorar comentarios y líneas vacías
        case "$line" in
            '#'*|'') skip=$((skip + 1)); continue ;;
        esac

        # Validar que es una IP (básico: contiene puntos y dígitos)
        case "$line" in
            *[!0-9.]*) log_ts "WARN: línea ignorada (no es IP): '$line'"; skip=$((skip+1)); continue ;;
        esac

        if nft add element $NFT_TABLE $NFT_SET \
                "{ $line timeout 0s }" >/dev/null 2>&1; then
            log_ts "OK  bypass permanente: $line (timeout 0s)"
            ok=$((ok + 1))
        else
            # Puede ya existir (no es error) — intentar con flush del elemento
            if nft get element $NFT_TABLE $NFT_SET \
                    "{ $line }" >/dev/null 2>&1; then
                log_ts "OK  ya presente: $line"
                ok=$((ok + 1))
            else
                log_ts "FAIL no se pudo agregar: $line"
                fail=$((fail + 1))
            fi
        fi
    done < "$CONF_FILE"

    log_ts "Resultado: ${ok} OK / ${fail} FAIL / ${skip} omitidas"

    if [ "$fail" -gt 0 ]; then
        log_ts "WARN: ${fail} IP(s) no se pudieron agregar — revisa el log"
        return 1
    fi

    log_ts "Set '$NFT_SET' actualizado. Estado actual:"
    nft list set $NFT_TABLE $NFT_SET 2>/dev/null | tee -a "$LOG_FILE"
    log_ts "=== captive-bypass-restore OK ==="
    return 0
}

stop() {
    log_ts "=== captive-bypass-restore STOP (no hace nada — los elementos persisten hasta reboot) ==="
    return 0
}

restart() {
    start
}
INITD_EOF

log_ok "Servicio init.d creado: /etc/init.d/captive-bypass-restore"

# ─── PASO 3: permisos + enable ────────────────────────────────────────────────
log_info "--- PASO 3: Habilitando el servicio ---"

router_ssh '
    chmod 755 /etc/init.d/captive-bypass-restore
    /etc/init.d/captive-bypass-restore enable
    # Verificar enlace simbólico creado
    if [ -L /etc/rc.d/S96captive-bypass-restore ]; then
        echo "  Enlace rc.d OK: /etc/rc.d/S96captive-bypass-restore"
    else
        echo "  WARN: enlace rc.d no encontrado — verifica con: ls /etc/rc.d/ | grep bypass"
    fi
' 2>/dev/null && log_ok "Servicio habilitado (arrancará automáticamente en el próximo reboot)" \
               || log_warn "No se pudo habilitar el servicio"

# ─── PASO 4: verificar tabla actual ───────────────────────────────────────────
log_info "--- PASO 4: Verificando tabla nftables actual ---"

TABLE_OK=$(router_ssh 'nft list table ip captive >/dev/null 2>&1 && echo yes || echo no' 2>/dev/null)
if [ "$TABLE_OK" = "yes" ]; then
    log_ok "Tabla 'ip captive' presente — el servicio puede arrancar ahora"
else
    log_warn "Tabla 'ip captive' NO presente (el captive portal no está activo)"
    log_warn "Ejecuta primero: bash scripts/setup-openwrt.sh"
    log_warn "Después el servicio arrancará automáticamente en el próximo reboot"
fi

# ─── PASO 5: test inmediato (opcional / --test) ───────────────────────────────
if [ "$DO_TEST" -eq 1 ] && [ "$TABLE_OK" = "yes" ]; then
    log_info "--- PASO 5: Ejecutando el servicio ahora (--test) ---"
    router_ssh '/etc/init.d/captive-bypass-restore start' 2>/dev/null \
        && log_ok "Servicio ejecutado — revisar log abajo" \
        || log_warn "Servicio retornó error — revisar log"

    printf '\n'
    log_info "Log del servicio:"
    router_ssh 'cat /var/log/captive-bypass.log' 2>/dev/null | sed 's/^/  /'

    printf '\n'
    log_info "Set allowed_clients después del restore:"
    router_ssh 'nft list set ip captive allowed_clients 2>/dev/null' | sed 's/^/  /'
fi

# ─── Resumen ──────────────────────────────────────────────────────────────────
printf '\n'
log_ok "=== Instalación completa ==="
printf '\n'
printf '  Servicio:  /etc/init.d/captive-bypass-restore  (START=96)\n'
printf '  IPs conf:  /etc/captive-portal-bypass.conf\n'
printf '  Log:       /var/log/captive-bypass.log\n'
printf '  Activación: automática en cada reboot (después de fw4)\n'
printf '\n'
log_info "Comandos útiles en el router (ssh root@$ROUTER_IP):"
printf '  /etc/init.d/captive-bypass-restore start    # ejecutar ahora\n'
printf '  /etc/init.d/captive-bypass-restore restart  # re-ejecutar\n'
printf '  cat /var/log/captive-bypass.log             # ver log\n'
printf '  nft list set ip captive allowed_clients     # ver set actual\n'
printf '\n'
log_info "Comandos desde admin:"
printf '  bash scripts/openwrt-bypass-install.sh --status  # ver estado\n'
printf '  bash scripts/openwrt-bypass-install.sh --test    # re-instalar + probar\n'
printf '\n'
log_info "Próximo paso recomendado: reiniciar el router y verificar"
printf '  1) reboot del router\n'
printf '  2) bash scripts/openwrt-bypass-install.sh --status\n'
printf '  3) bash scripts/openwrt-captive-doctor.sh\n'
