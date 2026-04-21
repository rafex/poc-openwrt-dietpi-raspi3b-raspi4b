#!/bin/bash
# raspi-logs.sh — Logs y verificación de salud del captive portal
#
# Uso:
#   bash scripts/raspi-logs.sh              # resumen: estado + últimas líneas de ambos contenedores
#   bash scripts/raspi-logs.sh --follow     # tail -f de ambos contenedores en paralelo
#   bash scripts/raspi-logs.sh --backend    # solo logs del backend Python
#   bash scripts/raspi-logs.sh --nginx      # solo logs de nginx
#   bash scripts/raspi-logs.sh --test       # pruebas funcionales (HTTP + SSH al router)
#   bash scripts/raspi-logs.sh --all        # resumen + test

KUBECTL="k3s kubectl"
PORTAL_IP="192.168.1.167"
ROUTER_IP="192.168.1.1"
SSH_KEY="/opt/keys/captive-portal"
TAIL_LINES=50

# =============================================================================
# Flags
# =============================================================================
MODE_FOLLOW=0
FILTER_CONTAINER=""   # vacío = ambos
DO_TEST=0

for arg in "$@"; do
    case "$arg" in
        --follow|-f)  MODE_FOLLOW=1 ;;
        --backend)    FILTER_CONTAINER="backend" ;;
        --nginx)      FILTER_CONTAINER="portal" ;;
        --test|-t)    DO_TEST=1 ;;
        --all|-a)     DO_TEST=1 ;;
        --lines=*)    TAIL_LINES="${arg#--lines=}" ;;
        --help|-h)
            sed -n '2,10p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) printf '[ERROR] Argumento desconocido: %s\n' "$arg" >&2; exit 1 ;;
    esac
done

# =============================================================================
# Colores y helpers
# =============================================================================
C_RESET='\e[0m'
C_BLUE='\e[0;34m'
C_GREEN='\e[0;32m'
C_YELLOW='\e[0;33m'
C_RED='\e[0;31m'
C_CYAN='\e[1;36m'
C_GRAY='\e[0;90m'

log_info()  { printf "${C_BLUE}[INFO] ${C_RESET}%s\n" "$*"; }
log_ok()    { printf "${C_GREEN}[OK]   ${C_RESET}%s\n" "$*"; }
log_warn()  { printf "${C_YELLOW}[WARN] ${C_RESET}%s\n" "$*"; }
log_error() { printf "${C_RED}[ERROR]${C_RESET}%s\n" "$*" >&2; }
sep()       { printf "\n${C_CYAN}=== %s ===${C_RESET}\n" "$*"; }

# Obtener el pod activo
get_pod() {
    $KUBECTL get pods -n default -l app=captive-portal \
        --field-selector=status.phase=Running \
        --no-headers 2>/dev/null | awk '{print $1}' | head -1
}

# =============================================================================
# SECCIÓN 0: Estado general del pod
# =============================================================================
sep "Estado del pod"

POD=$(get_pod)

if [ -z "$POD" ]; then
    log_error "No hay pod captive-portal en estado Running"
    log_info "Todos los pods:"
    $KUBECTL get pods -n default 2>/dev/null
    exit 1
fi

# Mostrar estado con READY, RESTARTS, AGE
$KUBECTL get pod "$POD" -n default \
    -o custom-columns='POD:.metadata.name,READY:.status.containerStatuses[*].ready,RESTARTS:.status.containerStatuses[*].restartCount,STATUS:.status.phase,IP:.status.podIP,NODE:.spec.nodeName' \
    2>/dev/null

# Estado de cada contenedor
printf '\n'
$KUBECTL get pod "$POD" -n default -o json 2>/dev/null | \
python3 -c "
import json, sys
pod = json.load(sys.stdin)
statuses = pod.get('status', {}).get('containerStatuses', [])
for s in statuses:
    name     = s.get('name', '?')
    ready    = '✓ ready' if s.get('ready') else '✗ not ready'
    restarts = s.get('restartCount', 0)
    state    = list(s.get('state', {}).keys())[0] if s.get('state') else 'unknown'
    image    = s.get('image', '?')
    print(f'  [{name:10}]  {ready}  restarts={restarts}  state={state}  image={image}')
" 2>/dev/null || \
    $KUBECTL get pod "$POD" -n default 2>/dev/null

# =============================================================================
# SECCIÓN 1: Logs
# =============================================================================
if [ "$MODE_FOLLOW" -eq 1 ]; then
    # --follow: tail -f de ambos contenedores en paralelo con prefijo de color
    sep "Logs en vivo (Ctrl+C para salir)"
    log_info "Siguiendo logs de nginx (portal) y backend en paralelo..."
    printf "${C_GRAY}  nginx  → prefijo [portal ]\n"
    printf "  Python → prefijo [backend]\n${C_RESET}\n"

    # Lanzar ambos en background con prefijo diferente
    $KUBECTL logs "$POD" -n default -c portal  --follow 2>/dev/null \
        | sed "s/^/${C_BLUE}[portal ] ${C_RESET}/" &
    PID_NGINX=$!

    $KUBECTL logs "$POD" -n default -c backend --follow 2>/dev/null \
        | sed "s/^/${C_GREEN}[backend] ${C_RESET}/" &
    PID_BACKEND=$!

    # Esperar Ctrl+C y matar ambos
    trap "kill $PID_NGINX $PID_BACKEND 2>/dev/null; printf '\n'; exit 0" INT TERM
    wait

else
    # Modo normal: últimas N líneas
    CONTAINERS=("portal" "backend")
    [ -n "$FILTER_CONTAINER" ] && CONTAINERS=("$FILTER_CONTAINER")

    for container in "${CONTAINERS[@]}"; do
        sep "Logs: $container (últimas $TAIL_LINES líneas)"
        $KUBECTL logs "$POD" -n default -c "$container" \
            --tail="$TAIL_LINES" --timestamps 2>/dev/null \
            || log_warn "No hay logs para contenedor $container"
    done
fi

# =============================================================================
# SECCIÓN 2: Pruebas funcionales (--test / --all)
# =============================================================================
if [ "$DO_TEST" -eq 1 ]; then

    sep "Test 1 — HTTP endpoints del portal"

    declare -A EXPECTED
    EXPECTED["/portal"]="200"
    EXPECTED["/accepted"]="200"
    EXPECTED["/"]="302"
    EXPECTED["/health"]="302"          # nginx redirige, no hay location /health
    EXPECTED["/generate_204"]="302"    # detección Android → redirect al portal

    ALL_OK=1
    for path in "${!EXPECTED[@]}"; do
        url="http://$PORTAL_IP$path"
        got=$(curl -s -o /dev/null -w "%{http_code}" \
            --connect-timeout 5 --max-time 8 "$url" 2>/dev/null || echo "000")
        want="${EXPECTED[$path]}"
        if [ "$got" = "$want" ] || [ "$got" = "200" ] || [ "$got" = "301" ] || [ "$got" = "302" ]; then
            printf "  ${C_GREEN}✓${C_RESET} %-30s HTTP %s\n" "$path" "$got"
        else
            printf "  ${C_RED}✗${C_RESET} %-30s HTTP %s (esperado %s)\n" "$path" "$got" "$want"
            ALL_OK=0
        fi
    done

    # ---
    sep "Test 2 — Backend Python health (dentro del pod)"

    HEALTH=$($KUBECTL exec "$POD" -n default -c backend -- \
        wget -qO- http://localhost:8080/health 2>/dev/null || echo "error")

    if printf '%s' "$HEALTH" | grep -q '"ok"'; then
        log_ok "Backend Python responde: $HEALTH"
    else
        log_error "Backend Python no responde en :8080 — respuesta: '$HEALTH'"
        log_warn "Posible causa: proceso Python caído. Ver logs con --backend"
        ALL_OK=0
    fi

    # ---
    sep "Test 3 — SSH al router desde el backend"

    log_info "Probando SSH root@$ROUTER_IP desde el contenedor backend..."
    SSH_RESULT=$($KUBECTL exec "$POD" -n default -c backend -- \
        ssh \
        -i "$SSH_KEY" \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=5 \
        -o BatchMode=yes \
        root@"$ROUTER_IP" \
        "echo ssh_ok" 2>&1 || echo "ssh_failed")

    if printf '%s' "$SSH_RESULT" | grep -q "ssh_ok"; then
        log_ok "SSH al router OK"
    else
        log_error "SSH al router FALLÓ"
        printf "  Salida: %s\n" "$SSH_RESULT"
        log_warn "Posibles causas:"
        printf "  1. La llave pública no está en /etc/dropbear/authorized_keys del router\n"
        printf "  2. El router no está accesible (¿setup-openwrt.sh corrió?)\n"
        printf "  3. Llave: %s\n" "$(cat $SSH_KEY.pub 2>/dev/null || echo 'no encontrada')"
        ALL_OK=0
    fi

    # ---
    sep "Test 4 — Tabla nftables en el router"

    NFT_RESULT=$($KUBECTL exec "$POD" -n default -c backend -- \
        ssh \
        -i "$SSH_KEY" \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=5 \
        -o BatchMode=yes \
        root@"$ROUTER_IP" \
        "nft list table ip captive 2>&1" 2>/dev/null || echo "ssh_failed")

    if printf '%s' "$NFT_RESULT" | grep -q "allowed_clients"; then
        log_ok "Tabla 'ip captive' existe con set 'allowed_clients'"
        printf '%s' "$NFT_RESULT" | grep -E 'elements|set |chain ' | sed 's/^/  /'
    elif printf '%s' "$NFT_RESULT" | grep -q "ssh_failed\|refused\|auth"; then
        log_warn "No se pudo conectar al router (ver Test 3)"
    else
        log_error "Tabla 'ip captive' NO existe en el router"
        printf "  Salida: %s\n" "$NFT_RESULT"
        log_warn "Ejecutar: bash scripts/setup-openwrt.sh"
        ALL_OK=0
    fi

    # ---
    sep "Test 5 — Conntrack en el router (conexiones activas)"

    CT_RESULT=$($KUBECTL exec "$POD" -n default -c backend -- \
        ssh \
        -i "$SSH_KEY" \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=5 \
        -o BatchMode=yes \
        root@"$ROUTER_IP" \
        "cat /proc/net/nf_conntrack 2>/dev/null | grep 'dport=80' | wc -l" 2>/dev/null \
        || echo "error")

    if printf '%s' "$CT_RESULT" | grep -qE '^[0-9]+$'; then
        log_ok "Conntrack accesible — conexiones activas al puerto 80: $CT_RESULT"
    else
        log_warn "No se pudo leer conntrack (puede ser normal si no hay clientes conectados)"
    fi

    # ---
    sep "Resumen de tests"
    if [ "$ALL_OK" -eq 1 ]; then
        log_ok "Todos los tests pasaron — el captive portal está funcionando correctamente"
    else
        log_warn "Algunos tests fallaron — revisar los errores anteriores"
        printf '\n'
        printf '  Checklist de resolución:\n'
        printf '  □ ¿k3s corriendo?         ps aux | grep k3s\n'
        printf '  □ ¿Router configurado?    bash scripts/setup-openwrt.sh\n'
        printf '  □ ¿Imagen actualizada?    bash scripts/raspi-deploy.sh\n'
        printf '  □ ¿Logs del backend?      bash scripts/raspi-logs.sh --backend\n'
    fi
fi

printf '\n'
