#!/bin/bash
# secrets-init.sh — Inicializa el sistema de secretos age+sops para el proyecto
#
# Qué hace:
#   1. Verifica / instala age y sops en la máquina admin (macOS o Debian)
#   2. Genera un keypair age en ~/.config/sops/age/keys.txt  (si no existe)
#   3. Actualiza .sops.yaml con la clave pública generada
#   4. Cifra secrets/raspi4b.yaml con sops (listo para commitear)
#
# Ejecutar UNA SOLA VEZ en la máquina admin.
# La clave privada queda en ~/.config/sops/age/keys.txt — NO va al repo.
#
# Uso:
#   bash scripts/secrets-init.sh
#   bash scripts/secrets-init.sh --force    # sobreescribe keypair existente
#
# Después de inicializar:
#   bash scripts/secrets-edit.sh            # poner GROQ_API_KEY y otros secretos
#   bash scripts/secrets-push-key.sh        # copiar privkey a la Pi4B
#   git add .sops.yaml secrets/raspi4b.yaml && git commit -m "feat: init secrets"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

hdr()  { printf "\n${BOLD}${CYAN}━━━ %s ━━━${NC}\n" "$*"; }
ok()   { printf "  ${GREEN}✓${NC} %s\n" "$*"; }
warn() { printf "  ${YELLOW}!${NC} %s\n" "$*"; }
info() { printf "  ${BLUE}·${NC} %s\n" "$*"; }
die()  { printf "${RED}ERROR${NC}: %s\n" "$*" >&2; exit 1; }

FORCE=false
[[ "${1:-}" == "--force" ]] && FORCE=true

AGE_KEY_DIR="${SOPS_AGE_KEY_FILE:-${HOME}/.config/sops/age}"
AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-${HOME}/.config/sops/age/keys.txt}"
SOPS_YAML="$REPO_DIR/.sops.yaml"
SECRETS_FILE="$REPO_DIR/secrets/raspi4b.yaml"

# ─── Cabecera ─────────────────────────────────────────────────────────────────
printf "\n${BOLD}╔══════════════════════════════════════════════════╗${NC}\n"
printf   "${BOLD}║  secrets-init  (age + sops)          %-11s║${NC}\n" "$(date '+%H:%M:%S')"
printf   "${BOLD}╚══════════════════════════════════════════════════╝${NC}\n"
printf "  Repo     : %s\n" "$REPO_DIR"
printf "  Keypair  : %s\n" "$AGE_KEY_FILE"
printf "  Secretos : %s\n" "$SECRETS_FILE"

# ─── PASO 1: Verificar / instalar herramientas ────────────────────────────────
hdr "1. Herramientas (age + sops)"

install_brew_pkg() {
    local pkg="$1"
    if ! command -v "$pkg" &>/dev/null; then
        info "Instalando $pkg via brew..."
        brew install "$pkg" || die "brew install $pkg falló — instálalo manualmente"
        ok "$pkg instalado"
    else
        ok "$pkg: $(command -v "$pkg")"
    fi
}

install_apt_pkg() {
    local pkg="$1" cmd="${2:-$1}"
    if ! command -v "$cmd" &>/dev/null; then
        info "Instalando $pkg via apt..."
        sudo apt-get update -qq
        sudo apt-get install -y -q "$pkg" || die "apt install $pkg falló"
        ok "$cmd instalado"
    else
        ok "$cmd: $(command -v "$cmd")"
    fi
}

install_sops_binary() {
    # sops no siempre está en apt (Debian Bullseye) — descarga el binario oficial
    local version="3.9.1"
    local arch
    arch="$(uname -m)"
    case "$arch" in
        aarch64|arm64) arch="arm64" ;;
        x86_64)        arch="amd64" ;;
        *) die "Arquitectura no soportada: $arch" ;;
    esac
    local os
    os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    local url="https://github.com/getsops/sops/releases/download/v${version}/sops-v${version}.${os}.${arch}"
    local dest="/usr/local/bin/sops"
    info "Descargando sops v${version} (${os}/${arch})..."
    curl -fsSL "$url" -o "$dest" || die "No se pudo descargar sops de $url"
    chmod +x "$dest"
    ok "sops instalado en $dest"
}

if [[ "$(uname -s)" == "Darwin" ]]; then
    install_brew_pkg age
    install_brew_pkg sops
else
    install_apt_pkg age age
    # sops: intentar apt primero, luego binario
    if ! command -v sops &>/dev/null; then
        if apt-cache show sops &>/dev/null 2>&1; then
            install_apt_pkg sops sops
        else
            install_sops_binary
        fi
    else
        ok "sops: $(command -v sops)"
    fi
fi

# ─── PASO 2: Generar keypair age ──────────────────────────────────────────────
hdr "2. Keypair age"

if [[ -f "$AGE_KEY_FILE" ]] && ! $FORCE; then
    ok "Keypair ya existe: $AGE_KEY_FILE"
    info "Usa --force para sobreescribir"
    PUBKEY="$(grep '^# public key:' "$AGE_KEY_FILE" | head -1 | awk '{print $NF}')"
    if [[ -z "$PUBKEY" ]]; then
        # Extraer con age-keygen si el comentario no está
        PUBKEY="$(age-keygen -y "$AGE_KEY_FILE" 2>/dev/null || grep '^public key:' "$AGE_KEY_FILE" | awk '{print $NF}')"
    fi
    ok "Clave pública: $PUBKEY"
else
    mkdir -p "$AGE_KEY_DIR"
    chmod 700 "$AGE_KEY_DIR"

    if $FORCE && [[ -f "$AGE_KEY_FILE" ]]; then
        warn "Sobreescribiendo keypair existente (--force)"
        cp "$AGE_KEY_FILE" "${AGE_KEY_FILE}.bak.$(date +%Y%m%d%H%M%S)"
        info "Backup guardado"
    fi

    age-keygen -o "$AGE_KEY_FILE" 2>/dev/null
    chmod 600 "$AGE_KEY_FILE"

    PUBKEY="$(grep '^# public key:' "$AGE_KEY_FILE" | head -1 | awk '{print $NF}')"
    ok "Keypair generado: $AGE_KEY_FILE"
    ok "Clave pública: $PUBKEY"
fi

[[ -n "$PUBKEY" ]] || die "No se pudo extraer la clave pública del keypair"

# ─── PASO 3: Actualizar .sops.yaml con la pubkey ─────────────────────────────
hdr "3. Configurando .sops.yaml"

if grep -q "REEMPLAZAR_CON_PUBKEY_AGE" "$SOPS_YAML" 2>/dev/null; then
    sed -i.bak "s|REEMPLAZAR_CON_PUBKEY_AGE|${PUBKEY}|g" "$SOPS_YAML"
    rm -f "${SOPS_YAML}.bak"
    ok ".sops.yaml actualizado con pubkey: $PUBKEY"
elif grep -q "$PUBKEY" "$SOPS_YAML" 2>/dev/null; then
    ok ".sops.yaml ya tiene la clave correcta"
else
    warn ".sops.yaml tiene una clave diferente — actualizando..."
    # Reemplazar la línea age: con la nueva pubkey
    sed -i.bak "s|age: >-.*|age: >-|; /age: >-/{n; s|.*|      ${PUBKEY}|}" "$SOPS_YAML"
    rm -f "${SOPS_YAML}.bak"
    ok ".sops.yaml actualizado"
fi

cat "$SOPS_YAML"

# ─── PASO 4: Cifrar secrets/raspi4b.yaml ─────────────────────────────────────
hdr "4. Cifrando secrets/raspi4b.yaml"

mkdir -p "$REPO_DIR/secrets"

# Verificar si el archivo ya está cifrado (tiene metadatos sops)
if grep -q "^sops:" "$SECRETS_FILE" 2>/dev/null; then
    ok "secrets/raspi4b.yaml ya está cifrado con sops"
    info "Para editarlo: bash scripts/secrets-edit.sh"
else
    info "Cifrando con sops+age..."
    # sops lee .sops.yaml automáticamente desde el directorio del archivo
    sops --encrypt --age "$PUBKEY" "$SECRETS_FILE" > "${SECRETS_FILE}.tmp"
    mv "${SECRETS_FILE}.tmp" "$SECRETS_FILE"
    ok "secrets/raspi4b.yaml cifrado correctamente"
fi

# Verificar que se puede descifrar
info "Verificando descifrado..."
sops -d "$SECRETS_FILE" > /dev/null && ok "Descifrado OK" || die "El descifrado falló — verifica que la clave privada está en $AGE_KEY_FILE"

# ─── Resumen ──────────────────────────────────────────────────────────────────
printf "\n${BOLD}${GREEN}✓ Sistema de secretos inicializado.${NC}\n\n"
printf "  Clave pública  : %s\n" "$PUBKEY"
printf "  Clave privada  : %s  ${YELLOW}(NO al repo)${NC}\n" "$AGE_KEY_FILE"
printf "  Secretos       : secrets/raspi4b.yaml  ${GREEN}(cifrado, seguro para git)${NC}\n"
printf "\n"
printf "  Próximos pasos:\n"
printf "    1. Editar secretos:     bash scripts/secrets-edit.sh\n"
printf "    2. Copiar key a Pi4B:   bash scripts/secrets-push-key.sh\n"
printf "    3. Commitear:           git add .sops.yaml secrets/raspi4b.yaml\n"
printf "    4. Desplegar:           bash scripts/setup-raspi4b-ai-analyzer.sh\n"
printf "\n"
