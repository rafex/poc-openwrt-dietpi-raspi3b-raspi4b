#!/bin/sh
# llm-control.sh — Control de energía del LLM local (llama-server)
#
# Uso:
#   sh scripts/llm-control.sh off      # apaga LLM y desactiva watchdog
#   sh scripts/llm-control.sh on       # enciende LLM y reactiva watchdog
#   sh scripts/llm-control.sh restart  # reinicia LLM (mantiene watchdog actual)
#   sh scripts/llm-control.sh status   # estado de LLM + watchdog
#
# Notas:
#   - Diseñado para DietPi/OpenWrt style init.d.
#   - Requiere /etc/init.d/llama-server (instalado por setup-ai-raspi4b.sh).

set -e

LLAMA_SERVICE="/etc/init.d/llama-server"
LLAMA_PIDFILE="/var/run/llama-server.pid"
LLAMA_PORT="${LLAMA_PORT:-8081}"

WATCHDOG_CRON="/etc/cron.d/llama-watchdog"
WATCHDOG_CRON_DISABLED="/etc/cron.d/llama-watchdog.disabled"

log_info()  { printf '[INFO]  %s\n' "$*"; }
log_ok()    { printf '[OK]    %s\n' "$*"; }
log_warn()  { printf '[WARN]  %s\n' "$*"; }
log_error() { printf '[ERROR] %s\n' "$*" >&2; }
die()       { log_error "$*"; exit 1; }

reload_cron() {
    if [ -x /etc/init.d/cron ]; then
        /etc/init.d/cron reload >/dev/null 2>&1 || \
        /etc/init.d/cron restart >/dev/null 2>&1 || true
    elif command -v service >/dev/null 2>&1; then
        service cron reload >/dev/null 2>&1 || \
        service cron restart >/dev/null 2>&1 || true
    fi
}

llama_running() {
    [ -f "$LLAMA_PIDFILE" ] && kill -0 "$(cat "$LLAMA_PIDFILE" 2>/dev/null)" 2>/dev/null
}

watchdog_enabled() {
    [ -f "$WATCHDOG_CRON" ]
}

watchdog_disable() {
    if [ -f "$WATCHDOG_CRON" ]; then
        mv -f "$WATCHDOG_CRON" "$WATCHDOG_CRON_DISABLED"
        reload_cron
        log_ok "Watchdog desactivado ($WATCHDOG_CRON -> $WATCHDOG_CRON_DISABLED)"
    else
        log_info "Watchdog ya estaba desactivado"
    fi
}

watchdog_enable() {
    if [ -f "$WATCHDOG_CRON_DISABLED" ]; then
        mv -f "$WATCHDOG_CRON_DISABLED" "$WATCHDOG_CRON"
        chmod 644 "$WATCHDOG_CRON"
        reload_cron
        log_ok "Watchdog activado ($WATCHDOG_CRON)"
    elif [ -f "$WATCHDOG_CRON" ]; then
        log_info "Watchdog ya estaba activado"
    else
        log_warn "No existe archivo de watchdog en /etc/cron.d (continuando sin watchdog)"
    fi
}

cmd_status() {
    printf '\n'
    log_info "Estado LLM (llama-server)"
    if llama_running; then
        log_ok "Proceso corriendo (PID $(cat "$LLAMA_PIDFILE"))"
    else
        log_warn "Proceso detenido"
    fi

    if curl -sf "http://127.0.0.1:$LLAMA_PORT/health" >/dev/null 2>&1; then
        log_ok "HTTP /health responde en :$LLAMA_PORT"
    else
        log_warn "HTTP /health no responde en :$LLAMA_PORT"
    fi

    if watchdog_enabled; then
        log_ok "Watchdog: ACTIVO ($WATCHDOG_CRON)"
    elif [ -f "$WATCHDOG_CRON_DISABLED" ]; then
        log_warn "Watchdog: DESACTIVADO ($WATCHDOG_CRON_DISABLED)"
    else
        log_warn "Watchdog: NO CONFIGURADO"
    fi
}

cmd_off() {
    watchdog_disable
    if [ -x "$LLAMA_SERVICE" ]; then
        "$LLAMA_SERVICE" stop >/dev/null 2>&1 || true
    else
        die "No existe $LLAMA_SERVICE. Ejecuta setup-ai-raspi4b.sh primero."
    fi

    sleep 1
    if llama_running; then
        die "No se pudo detener llama-server"
    fi
    log_ok "LLM apagado. CPU liberada."
}

cmd_on() {
    watchdog_enable
    [ -x "$LLAMA_SERVICE" ] || die "No existe $LLAMA_SERVICE. Ejecuta setup-ai-raspi4b.sh primero."

    "$LLAMA_SERVICE" start >/dev/null 2>&1 || true
    sleep 2

    if llama_running; then
        log_ok "LLM encendido (PID $(cat "$LLAMA_PIDFILE"))"
    else
        log_warn "LLM no levantó aún. Revisa: tail -40 /var/log/llama-server.log"
    fi
}

cmd_restart() {
    [ -x "$LLAMA_SERVICE" ] || die "No existe $LLAMA_SERVICE. Ejecuta setup-ai-raspi4b.sh primero."
    "$LLAMA_SERVICE" restart >/dev/null 2>&1 || true
    sleep 2
    if llama_running; then
        log_ok "LLM reiniciado (PID $(cat "$LLAMA_PIDFILE"))"
    else
        log_warn "LLM no quedó corriendo. Revisa: tail -40 /var/log/llama-server.log"
    fi
}

ACTION="${1:-status}"
case "$ACTION" in
    off)     cmd_off ;;
    on)      cmd_on ;;
    restart) cmd_restart ;;
    status)  cmd_status ;;
    --help|-h|help)
        sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
        ;;
    *)
        die "Acción inválida: $ACTION (usa: on|off|restart|status)"
        ;;
esac
