#!/bin/bash
# secrets-edit.sh — Edita secretos cifrados con sops+age
#
# Descifra el archivo en memoria, abre el editor, vuelve a cifrar al guardar.
# El archivo sin cifrar NUNCA toca el disco.
#
# Uso:
#   bash scripts/secrets-edit.sh                    # edita secrets/raspi4b.yaml
#   bash scripts/secrets-edit.sh --show             # muestra valores (sin editar)
#   bash scripts/secrets-edit.sh --set KEY=valor    # asigna un valor sin abrir editor
#
# Requiere: age + sops  (instalar con: bash scripts/secrets-init.sh)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SECRETS_FILE="$REPO_DIR/secrets/raspi4b.yaml"
AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-${HOME}/.config/sops/age/keys.txt}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'; BOLD='\033[1m'

ok()   { printf "  ${GREEN}✓${NC} %s\n" "$*"; }
info() { printf "  ${BLUE}·${NC} %s\n" "$*"; }
die()  { printf "${RED}ERROR${NC}: %s\n" "$*" >&2; exit 1; }

# ─── Pre-checks ───────────────────────────────────────────────────────────────
command -v sops &>/dev/null || die "sops no instalado — ejecuta: bash scripts/secrets-init.sh"
command -v age  &>/dev/null || die "age no instalado  — ejecuta: bash scripts/secrets-init.sh"
[[ -f "$AGE_KEY_FILE" ]]   || die "Clave privada age no encontrada: $AGE_KEY_FILE
  Ejecuta: bash scripts/secrets-init.sh"
[[ -f "$SECRETS_FILE" ]]   || die "Archivo de secretos no encontrado: $SECRETS_FILE
  Ejecuta: bash scripts/secrets-init.sh"

export SOPS_AGE_KEY_FILE="$AGE_KEY_FILE"

# ─── Modo --show ──────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--show" ]]; then
    printf "\n${BOLD}Secretos actuales (descifrados):${NC}\n\n"
    sops -d "$SECRETS_FILE" | sed 's/^/  /'
    printf "\n"
    exit 0
fi

# ─── Modo --set KEY=valor ─────────────────────────────────────────────────────
if [[ "${1:-}" == "--set" ]]; then
    [[ -n "${2:-}" ]] || die "Uso: --set CLAVE=valor"
    KEY="${2%%=*}"
    VAL="${2#*=}"
    [[ -n "$KEY" ]] || die "Clave vacía en: $2"

    info "Actualizando $KEY en $SECRETS_FILE ..."
    # sops set modifica un valor sin abrir editor
    sops --set "[\"${KEY}\"] \"${VAL}\"" "$SECRETS_FILE"
    ok "$KEY actualizado"
    info "Verifica: bash scripts/secrets-edit.sh --show"
    exit 0
fi

# ─── Modo interactivo (editor) ────────────────────────────────────────────────
# sops descifra → abre EDITOR → cifra de vuelta al guardar
# El archivo descifrado nunca toca el disco gracias a sops

printf "\n${BOLD}Abriendo secretos con sops...${NC}\n"
info "Archivo: $SECRETS_FILE"
info "Editor:  ${EDITOR:-vi}  (cambia con: export EDITOR=nano)"
printf "\n"

# sops maneja internamente el ciclo descifrar→editar→cifrar
SOPS_AGE_KEY_FILE="$AGE_KEY_FILE" sops "$SECRETS_FILE"

ok "Secretos guardados y cifrados"
printf "\n"
info "Para verificar: bash scripts/secrets-edit.sh --show"
info "Para desplegar: bash scripts/setup-raspi4b-ai-analyzer.sh --no-build"
printf "\n"
