#!/usr/bin/env bash
# =============================================================================
# tag-release.sh — Crea y opcionalmente empuja el tag de release
# =============================================================================
#
# Comportamiento por rama:
#   develop  →  v<VERSION>-preview   (pre-release para pruebas en Pi)
#   main     →  v<VERSION>           (release de producción)
#   otra     →  v<VERSION>-preview   (se trata como preview con advertencia)
#
# Uso:
#   ./scripts/tag-release.sh                         # crea tag, NO empuja
#   ./scripts/tag-release.sh --push                  # crea tag Y empuja a origin
#   ./scripts/tag-release.sh --dry-run               # muestra qué haría, sin cambios
#   ./scripts/tag-release.sh --version 0.5.0 --push  # override de versión
#   ./scripts/tag-release.sh --force --push          # sobreescribir tag existente
#
# Variables de entorno:
#   VERSION_FILE  ruta al archivo VERSION (default: raíz del proyecto)
#
# Al hacer push del tag, GitHub Actions dispara automáticamente:
#   develop → v0.4.0-preview  →  release-java.yml (pre-release, tag :preview)
#   main    → v0.4.0          →  release-java.yml (latest, tag :0.4.0)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
VERSION_FILE="${VERSION_FILE:-${ROOT_DIR}/VERSION}"

# ── Colores ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
log_info()  { echo -e "${CYAN}[INFO]${RESET}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${RESET}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
log_error() { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
log_dry()   { echo -e "${YELLOW}[DRY-RUN]${RESET} $*"; }

# ── Defaults ──────────────────────────────────────────────────────────────────
PUSH=false
DRY_RUN=false
FORCE=false
VERSION_OVERRIDE=""

# ── Parse args ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --push)           PUSH=true ;;
    --no-push)        PUSH=false ;;
    --dry-run)        DRY_RUN=true ;;
    --force)          FORCE=true ;;
    --version)        shift; VERSION_OVERRIDE="$1" ;;
    --version=*)      VERSION_OVERRIDE="${1#--version=}" ;;
    -h|--help)
      sed -n '/^# =/,/^# =/{ s/^# \{0,1\}//; p }' "$0" | head -30
      exit 0 ;;
    *)
      log_error "Argumento desconocido: $1"
      echo "  Uso: $0 [--push] [--dry-run] [--force] [--version X.Y.Z]"
      exit 1 ;;
  esac
  shift
done

# ── Leer versión ──────────────────────────────────────────────────────────────
if [ -n "$VERSION_OVERRIDE" ]; then
  VERSION="$VERSION_OVERRIDE"
elif [ -f "$VERSION_FILE" ]; then
  VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
else
  log_error "No se encontró el archivo VERSION en: $VERSION_FILE"
  log_error "  Créalo con:  echo '0.4.0' > VERSION"
  exit 1
fi

# Validar formato semántico X.Y.Z
if ! echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  log_error "Versión inválida: '${VERSION}' — formato esperado: X.Y.Z (ej: 0.4.0)"
  exit 1
fi

# ── Verificar que estamos en un repo git ─────────────────────────────────────
cd "$ROOT_DIR"

if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
  log_error "No estás dentro de un repositorio git."
  exit 1
fi

# ── Detectar rama y componer tag ─────────────────────────────────────────────
BRANCH="$(git rev-parse --abbrev-ref HEAD)"

case "$BRANCH" in
  develop)
    TAG="v${VERSION}-preview"
    TAG_TYPE="pre-release"
    ;;
  main|master)
    TAG="v${VERSION}"
    TAG_TYPE="production release"
    ;;
  *)
    log_warn "Rama '${BRANCH}' no es 'develop' ni 'main' — el tag se marcará como preview."
    TAG="v${VERSION}-preview"
    TAG_TYPE="pre-release (rama no estándar: ${BRANCH})"
    ;;
esac

# ── Info del commit actual ────────────────────────────────────────────────────
COMMIT_HASH="$(git rev-parse --short HEAD)"
COMMIT_MSG="$(git log -1 --pretty=format:'%s')"

# Advertir si hay cambios sin commitear
if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
  log_warn "Hay cambios sin commitear — el tag apuntará al commit: ${COMMIT_HASH}"
fi

# ── Verificar si el tag ya existe ────────────────────────────────────────────
TAG_EXISTS=false
if git tag --list | grep -q "^${TAG}$"; then
  TAG_EXISTS=true
  if $FORCE; then
    log_warn "Tag '${TAG}' ya existe y será sobreescrito (--force)"
  else
    log_error "El tag '${TAG}' ya existe en este repositorio."
    log_error "  Opciones:"
    log_error "    1. Actualiza VERSION para subir a la siguiente versión"
    log_error "    2. Usa --force para sobreescribir el tag existente"
    log_error ""
    log_error "  Tags v* existentes:"
    git tag --list "v*" | sort -V | tail -10 | sed 's/^/    /'
    exit 1
  fi
fi

# ── Resumen de lo que se va a hacer ──────────────────────────────────────────
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}  Tag Release — ai-analyzer${RESET}"
echo -e "${BOLD}═══════════════════════════════════════════════════════${RESET}"
printf "  %-12s: %s\n" "Versión"  "$VERSION"
printf "  %-12s: %s\n" "Rama"     "$BRANCH"
echo -e "  Tag         : ${BOLD}${CYAN}${TAG}${RESET}   (${TAG_TYPE})"
printf "  %-12s: %s  %s\n" "Commit"   "$COMMIT_HASH" "$COMMIT_MSG"
echo -e "  Push        : $([ "$PUSH" = "true" ] && echo "${GREEN}sí → origin${RESET}" || echo "${YELLOW}no (solo local)${RESET}")"
if $DRY_RUN; then
  echo -e "  Modo        : ${YELLOW}DRY-RUN — sin cambios${RESET}"
fi
echo ""

# ── Dry-run: mostrar comandos y salir ────────────────────────────────────────
if $DRY_RUN; then
  if $TAG_EXISTS && $FORCE; then
    log_dry "git tag -d '${TAG}'"
  fi
  log_dry "git tag -a '${TAG}' -m 'Release ${TAG}'"
  if $PUSH; then
    if $FORCE; then
      log_dry "git push origin '${TAG}' --force"
    else
      log_dry "git push origin '${TAG}'"
    fi
    echo ""
    log_dry "GitHub Actions se disparará:"
    if [[ "$TAG" == *-preview ]]; then
      log_dry "  → release-java.yml    pre-release  ghcr.io:${VERSION}-preview (no latest)"
      log_dry "  → release-python.yml  pre-release  ghcr.io:${VERSION}-preview (no latest)"
      log_dry "  → release-web.yml     pre-release  ghcr.io:${VERSION}-preview (no latest)"
    else
      log_dry "  → release-java.yml    RELEASE      ghcr.io:${VERSION} + ghcr.io:latest"
      log_dry "  → release-python.yml  RELEASE      ghcr.io:${VERSION} + ghcr.io:latest"
      log_dry "  → release-web.yml     RELEASE      ghcr.io:${VERSION} + ghcr.io:latest"
    fi
  else
    log_dry "  (sin --push: el tag quedará solo en local)"
  fi
  echo ""
  log_ok "Dry-run completado — sin cambios realizados."
  exit 0
fi

# ── Crear tag anotado ─────────────────────────────────────────────────────────
TAG_MSG="Release ${TAG}

Branch  : ${BRANCH}
Commit  : ${COMMIT_HASH}
Version : ${VERSION}
Type    : ${TAG_TYPE}"

if $TAG_EXISTS && $FORCE; then
  log_warn "Eliminando tag local existente: ${TAG}"
  git tag -d "$TAG"
fi

log_info "Creando tag anotado: ${TAG}"
git tag -a "$TAG" -m "$TAG_MSG"
log_ok "Tag creado localmente: ${TAG}"

# ── Push ──────────────────────────────────────────────────────────────────────
if $PUSH; then
  if $TAG_EXISTS && $FORCE; then
    log_info "Empujando tag (--force) a origin..."
    git push origin "$TAG" --force
  else
    log_info "Empujando tag a origin..."
    git push origin "$TAG"
  fi
  log_ok "Tag empujado: ${TAG}"
  echo ""

  # Detectar URL del repo para mostrar enlace
  REMOTE_URL="$(git remote get-url origin 2>/dev/null || echo "")"
  REPO_PATH=""
  if echo "$REMOTE_URL" | grep -q "github.com"; then
    REPO_PATH="$(echo "$REMOTE_URL" | sed 's|.*github.com[:/]||' | sed 's|\.git$||')"
  fi

  log_info "GitHub Actions disparado automáticamente."
  if [ -n "$REPO_PATH" ]; then
    log_info "  Progreso : https://github.com/${REPO_PATH}/actions"
    log_info "  Release  : https://github.com/${REPO_PATH}/releases/tag/${TAG}"
  fi
  log_info "  CLI      : gh run list --workflow=release-java.yml"
  log_info "  Watch    : gh run watch"
else
  echo ""
  log_warn "Tag creado SOLO en local (sin --push)."
  log_warn "  Para empujar: git push origin ${TAG}"
  log_warn "  O:            just tag-push"
fi

echo ""
