#!/bin/bash
# llama-compile.sh — Compila llama.cpp con CMake optimizado para Cortex-A72 (Pi 4B)
#
# NOTA: llama.cpp ya no usa 'make'. Ahora usa CMake exclusivamente.
#       Si intentas usar 'make' directamente obtendrás un error.
#
# CPU target: Cortex-A72 (BCM2711 — Raspberry Pi 4B)
#   Flags: -mcpu=cortex-a72 -mtune=cortex-a72 -O3
#   Backend BLAS: OpenBLAS (acelera multiplicación de matrices)
#
# Uso:
#   bash scripts/llama-compile.sh
#   bash scripts/llama-compile.sh --llama-dir=/opt/repository/llama.cpp
#   bash scripts/llama-compile.sh --llama-dir=~/llama.cpp --build-dir=build-rpi4
#   bash scripts/llama-compile.sh --llama-dir=~/llama.cpp --clean
#   bash scripts/llama-compile.sh --llama-dir=~/llama.cpp --only-clean
#   bash scripts/llama-compile.sh --llama-dir=~/llama.cpp --jobs=2
#   bash scripts/llama-compile.sh --dry-run
#
# Variables de entorno alternativas:
#   LLAMA_DIR=~/llama.cpp bash scripts/llama-compile.sh
#   BUILD_DIR=build-custom bash scripts/llama-compile.sh

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
LLAMA_DIR="${LLAMA_DIR:-/opt/repository/llama.cpp}"
BUILD_DIR_NAME="${BUILD_DIR:-build-rpi4}"
JOBS="${BUILD_JOBS:-$(nproc 2>/dev/null || echo 4)}"
DO_CLEAN=false
ONLY_CLEAN=false
DRY_RUN=false

# ── Colores para logging ───────────────────────────────────────────────────────
_c_reset='\033[0m'
_c_ok='\033[0;32m'
_c_info='\033[0;36m'
_c_warn='\033[0;33m'
_c_err='\033[0;31m'

log_info()  { printf "${_c_info}[INFO]${_c_reset}  %s\n" "$*"; }
log_ok()    { printf "${_c_ok}[OK]${_c_reset}    %s\n" "$*"; }
log_warn()  { printf "${_c_warn}[WARN]${_c_reset}  %s\n" "$*"; }
log_error() { printf "${_c_err}[ERROR]${_c_reset} %s\n" "$*" >&2; }
die()       { log_error "$*"; exit 1; }

run_cmd() {
    if $DRY_RUN; then
        log_info "[dry-run] $*"
    else
        "$@"
    fi
}

# ── Parseo de argumentos ───────────────────────────────────────────────────────
for arg in "$@"; do
    case "$arg" in
        --llama-dir=*)   LLAMA_DIR="${arg#--llama-dir=}" ;;
        --build-dir=*)   BUILD_DIR_NAME="${arg#--build-dir=}" ;;
        --jobs=*)        JOBS="${arg#--jobs=}" ;;
        --clean)         DO_CLEAN=true ;;
        --only-clean)    ONLY_CLEAN=true; DO_CLEAN=true ;;
        --dry-run)       DRY_RUN=true ;;
        -h|--help)
            sed -n '2,20p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            log_warn "Argumento desconocido ignorado: $arg"
            ;;
    esac
done

# Resolver path completo (expandir ~ si aplica)
LLAMA_DIR="$(eval echo "$LLAMA_DIR")"
BUILD_DIR="${LLAMA_DIR}/${BUILD_DIR_NAME}"

# ── Validaciones ───────────────────────────────────────────────────────────────
log_info "─── llama-compile ────────────────────────────────────────────────────"
log_info "  llama-dir  : $LLAMA_DIR"
log_info "  build-dir  : $BUILD_DIR"
log_info "  jobs       : $JOBS"
log_info "  clean      : $DO_CLEAN"
log_info "  only-clean : $ONLY_CLEAN"
log_info "  dry-run    : $DRY_RUN"

# Verificar que el directorio de llama.cpp existe
if [[ ! -d "$LLAMA_DIR" ]]; then
    die "Directorio de llama.cpp no encontrado: $LLAMA_DIR
Usa --llama-dir=/ruta/a/llama.cpp o clona el repositorio primero:
  git clone https://github.com/ggerganov/llama.cpp.git $LLAMA_DIR"
fi

# Verificar que es un repo de llama.cpp (tiene CMakeLists.txt)
if [[ ! -f "$LLAMA_DIR/CMakeLists.txt" ]]; then
    die "No se encontró CMakeLists.txt en $LLAMA_DIR
¿Es este un repositorio de llama.cpp válido?"
fi

# Verificar dependencias de compilación
for cmd in cmake gcc g++ make; do
    command -v "$cmd" &>/dev/null || die "Comando requerido no encontrado: $cmd
Instala con: apt-get install -y cmake build-essential libopenblas-dev"
done

if ! dpkg -s libopenblas-dev &>/dev/null 2>&1; then
    log_warn "libopenblas-dev no está instalado — BLAS desactivado"
    log_warn "Instala con: apt-get install -y libopenblas-dev"
    USE_BLAS=false
else
    USE_BLAS=true
fi

# ── Limpieza ───────────────────────────────────────────────────────────────────
if $DO_CLEAN; then
    if [[ -d "$BUILD_DIR" ]]; then
        log_info "Eliminando directorio de build: $BUILD_DIR"
        log_info "(necesario para cambiar flags de compilación)"
        run_cmd rm -rf "$BUILD_DIR"
        log_ok "Limpieza completa de $BUILD_DIR"
    else
        log_info "Directorio de build no existe: $BUILD_DIR (nada que limpiar)"
    fi

    if $ONLY_CLEAN; then
        log_ok "Limpieza completada. Ejecuta sin --only-clean para compilar."
        exit 0
    fi
fi

# ── Configurar CMake ───────────────────────────────────────────────────────────
log_info "─── Configurando CMake (Cortex-A72) ──────────────────────────────────"

CPU_FLAGS="-O3 -mcpu=cortex-a72 -mtune=cortex-a72"

CMAKE_OPTS=(
    -B "$BUILD_DIR"
    -DCMAKE_BUILD_TYPE=Release
    "-DCMAKE_C_FLAGS=${CPU_FLAGS}"
    "-DCMAKE_CXX_FLAGS=${CPU_FLAGS}"
)

if $USE_BLAS; then
    CMAKE_OPTS+=(
        -DGGML_BLAS=ON
        -DGGML_BLAS_VENDOR=OpenBLAS
    )
    log_info "OpenBLAS habilitado (aceleración de multiplicación de matrices)"
else
    CMAKE_OPTS+=(-DGGML_BLAS=OFF)
    log_warn "OpenBLAS no disponible — compilando sin BLAS"
fi

log_info "Ejecutando: cmake ${CMAKE_OPTS[*]}"
run_cmd cmake -S "$LLAMA_DIR" "${CMAKE_OPTS[@]}"

# ── Compilar ───────────────────────────────────────────────────────────────────
log_info "─── Compilando con $JOBS jobs ────────────────────────────────────────"
log_info "Este proceso toma ~15-30 minutos en la Pi 4B. No interrumpir."
log_info ""

_t0=$(date +%s)
run_cmd cmake --build "$BUILD_DIR" --config Release --parallel "$JOBS"
_t1=$(date +%s)
_elapsed=$(( _t1 - _t0 ))

log_ok "Compilación completada en ${_elapsed}s (~$(( _elapsed / 60 ))min)"

# ── Verificar binarios ─────────────────────────────────────────────────────────
log_info "─── Binarios generados ───────────────────────────────────────────────"
BINARIES=(llama-server llama-cli llama-bench llama-quantize llama-embedding llama-run)
FOUND=0
for bin in "${BINARIES[@]}"; do
    bin_path="${BUILD_DIR}/bin/${bin}"
    if [[ -f "$bin_path" ]]; then
        size=$(du -h "$bin_path" | cut -f1)
        log_ok "  $bin  (${size})"
        FOUND=$(( FOUND + 1 ))
    else
        log_warn "  $bin  — no encontrado en ${BUILD_DIR}/bin/"
    fi
done

[[ $FOUND -eq 0 ]] && die "No se encontraron binarios en ${BUILD_DIR}/bin/ — la compilación puede haber fallado"

# ── Resumen ────────────────────────────────────────────────────────────────────
printf "\n"
log_ok "llama-compile completado"
printf "\n"
printf "  Binarios en: %s/bin/\n" "$BUILD_DIR"
printf "\n"
printf "  Para instalar en /usr/local/bin (opcional):\n"
printf "    sudo cp %s/bin/llama-server /usr/local/bin/\n" "$BUILD_DIR"
printf "    sudo cp %s/bin/llama-cli    /usr/local/bin/\n" "$BUILD_DIR"
printf "\n"
printf "  Para verificar:\n"
printf "    %s/bin/llama-server --version\n" "$BUILD_DIR"
printf "\n"
printf "  Para limpiar y recompilar con flags distintos:\n"
printf "    bash %s --llama-dir=%s --only-clean\n" "$0" "$LLAMA_DIR"
printf "    bash %s --llama-dir=%s\n" "$0" "$LLAMA_DIR"
printf "\n"
