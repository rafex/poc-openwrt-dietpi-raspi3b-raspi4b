#!/bin/bash
# portal-switch.sh — Intercambia el portal cautivo activo entre lentium y clasico.
#
# Uso:
#   ./scripts/portal-switch.sh lentium    # activar portal Lentium (por defecto)
#   ./scripts/portal-switch.sh clasico    # activar portal clásico (respaldo)
#   ./scripts/portal-switch.sh            # sin argumento: muestra el activo y alterna
#
# Qué hace:
#   1. Detecta cuál portal está activo leyendo el selector del Service.
#   2. Escala a 1 el deployment del portal destino.
#   3. Espera a que el pod esté Ready.
#   4. Redirige el Service al nuevo portal (patch del selector portal-variant).
#   5. Escala a 0 el deployment del portal anterior.

set -euo pipefail

# ── Constantes ────────────────────────────────────────────────────────────────
SVC="captive-portal"
NS="default"
DEPLOY_LENTIUM="captive-portal-lentium"
DEPLOY_CLASICO="captive-portal"
TIMEOUT_READY=90   # segundos esperando que el pod esté Ready

# ── Colores ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[portal-switch]${NC} $*"; }
ok()      { echo -e "${GREEN}[portal-switch] ✔${NC} $*"; }
warn()    { echo -e "${YELLOW}[portal-switch] ⚠${NC} $*"; }
die()     { echo -e "${RED}[portal-switch] ✘${NC} $*" >&2; exit 1; }

# ── Dependencias ──────────────────────────────────────────────────────────────
command -v kubectl >/dev/null 2>&1 || die "kubectl no encontrado en PATH"

# ── Estado actual ─────────────────────────────────────────────────────────────
current_variant() {
    kubectl get svc "$SVC" -n "$NS" \
        -o jsonpath='{.spec.selector.portal-variant}' 2>/dev/null || echo "desconocido"
}

CURRENT=$(current_variant)

# ── Argumento o autodetección ─────────────────────────────────────────────────
if [[ $# -eq 0 ]]; then
    # Sin argumento: alternar
    if [[ "$CURRENT" == "lentium" ]]; then
        TARGET="clasico"
    else
        TARGET="lentium"
    fi
elif [[ "$1" == "lentium" || "$1" == "clasico" ]]; then
    TARGET="$1"
elif [[ "$1" == "--status" || "$1" == "status" ]]; then
    echo ""
    info "Portal activo: ${GREEN}${CURRENT}${NC}"
    echo ""
    kubectl get pods -n "$NS" -l "app=captive-portal" \
        -o custom-columns="NOMBRE:.metadata.name,VARIANTE:.metadata.labels.portal-variant,ESTADO:.status.phase,READY:.status.containerStatuses[*].ready" 2>/dev/null || true
    echo ""
    exit 0
else
    die "Uso: $0 [lentium|clasico|status]"
fi

# ── Mapear variante a deployment ──────────────────────────────────────────────
if [[ "$TARGET" == "lentium" ]]; then
    DEPLOY_TARGET="$DEPLOY_LENTIUM"
    DEPLOY_OLD="$DEPLOY_CLASICO"
else
    DEPLOY_TARGET="$DEPLOY_CLASICO"
    DEPLOY_OLD="$DEPLOY_LENTIUM"
fi

# ── Validar que el target no sea ya el activo ─────────────────────────────────
if [[ "$CURRENT" == "$TARGET" ]]; then
    warn "El portal '$TARGET' ya es el activo. No hay nada que cambiar."
    exit 0
fi

echo ""
info "Portal activo:  ${RED}${CURRENT}${NC}"
info "Portal destino: ${GREEN}${TARGET}${NC}"
echo ""

# ── Paso 1: escalar destino a 1 ───────────────────────────────────────────────
info "Escalando '${DEPLOY_TARGET}' a 1 réplica..."
kubectl scale deployment "$DEPLOY_TARGET" -n "$NS" --replicas=1

# ── Paso 2: esperar a que esté Ready ─────────────────────────────────────────
info "Esperando que el pod esté Ready (timeout ${TIMEOUT_READY}s)..."
if ! kubectl rollout status deployment/"$DEPLOY_TARGET" -n "$NS" --timeout="${TIMEOUT_READY}s"; then
    die "El deployment '${DEPLOY_TARGET}' no alcanzó Ready en ${TIMEOUT_READY}s. Abortando sin tocar el portal activo."
fi
ok "Pod de '$TARGET' listo."

# ── Paso 3: redirigir el Service ──────────────────────────────────────────────
info "Redirigiendo Service '${SVC}' al portal '${TARGET}'..."
kubectl patch svc "$SVC" -n "$NS" \
    --type='merge' \
    -p "{\"spec\":{\"selector\":{\"app\":\"captive-portal\",\"portal-variant\":\"${TARGET}\"}},\"metadata\":{\"annotations\":{\"active-portal\":\"${TARGET}\"}}}"
ok "Service apuntando a '$TARGET'."

# ── Paso 4: escalar el portal anterior a 0 ────────────────────────────────────
info "Escalando '${DEPLOY_OLD}' a 0 réplicas (modo reposo)..."
kubectl scale deployment "$DEPLOY_OLD" -n "$NS" --replicas=0
ok "Portal anterior '${CURRENT}' en reposo."

# ── Resumen final ─────────────────────────────────────────────────────────────
echo ""
ok "Intercambio completado."
info "Portal activo ahora: ${GREEN}${TARGET}${NC}"
echo ""
kubectl get pods -n "$NS" -l "app=captive-portal" \
    -o custom-columns="NOMBRE:.metadata.name,VARIANTE:.metadata.labels.portal-variant,ESTADO:.status.phase" 2>/dev/null || true
echo ""
