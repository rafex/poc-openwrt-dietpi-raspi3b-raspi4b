#!/bin/bash
# setup-raspi4b-llama-build.sh
# Compila llama.cpp optimizado para Cortex-A72 (Raspberry Pi 4B) e instala
# los binarios en /usr/local/bin/.
#
# CPU target: Cortex-A72 (ARMv8-A)
#   Features: fp asimd evtstrm crc32 cpuid
#   → -march=armv8-a+crc+simd  -mtune=cortex-a72  -mfpu=neon-fp-armv8
#
# Uso:
#   sudo bash scripts/setup-raspi4b-llama-build.sh
#   sudo bash scripts/setup-raspi4b-llama-build.sh --dry-run
#   sudo bash scripts/setup-raspi4b-llama-build.sh --force          # recompila aunque exista
#   sudo bash scripts/setup-raspi4b-llama-build.sh --no-build       # solo verifica
#   sudo bash scripts/setup-raspi4b-llama-build.sh --branch b4946   # rama/tag específico
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib/raspi4b-common.sh
. "$SCRIPT_DIR/lib/raspi4b-common.sh"

# ──────────────────────────── configuración ────────────────────────────────
LLAMA_REPO="https://github.com/ggerganov/llama.cpp.git"
LLAMA_DIR="/opt/repository/llama.cpp"
INSTALL_DIR="/usr/local/bin"
BUILD_DIR="${LLAMA_DIR}/build-raspi4b"
BUILD_JOBS="$(nproc 2>/dev/null || echo 4)"

# Binarios que se instalan (llama.cpp los produce en build/bin/)
BINARIES=(
  llama-server
  llama-cli
  llama-run
  llama-bench
  llama-quantize
  llama-embedding
)

# Flags de compilación Cortex-A72
#   -march=armv8-a+crc+simd  → ARMv8-A base + CRC32 hw + SIMD/NEON
#   -mtune=cortex-a72         → pipeline scheduling específico
#   -O3 -pipe -fno-plt        → optimizaciones generales
CFLAGS_NATIVE="-march=armv8-a+crc+simd -mtune=cortex-a72 -O3 -pipe -fno-plt"
CXXFLAGS_NATIVE="${CFLAGS_NATIVE}"

# Rama/tag de llama.cpp a usar (vacío = rama principal por defecto)
LLAMA_BRANCH=""

# ──────────────────────────── flags CLI ────────────────────────────────────
parse_common_flags "$@"
ARGS=("${REM_ARGS[@]}")
REM_ARGS=()
for a in "${ARGS[@]}"; do
  case "$a" in
    --branch=*) LLAMA_BRANCH="${a#--branch=}" ;;
    --branch)   die "Usa --branch=<nombre-de-rama-o-tag>" ;;
    *)          REM_ARGS+=("$a") ;;
  esac
done
[ "${#REM_ARGS[@]}" -eq 0 ] || die "Argumentos no soportados: ${REM_ARGS[*]}"

init_log_dir "llm"
need_root

# ──────────────────────────── dependencias ─────────────────────────────────
log_info "=== setup-raspi4b-llama-build ==="
log_info "Directorio fuente : ${LLAMA_DIR}"
log_info "Directorio build  : ${BUILD_DIR}"
log_info "Destino binarios  : ${INSTALL_DIR}"
log_info "Jobs de compilación: ${BUILD_JOBS}"
log_info "CFLAGS            : ${CFLAGS_NATIVE}"

ensure_cmd git cmake make gcc g++ curl

log_info "Instalando dependencias de compilación..."
run_cmd apt-get install -y --no-install-recommends \
  build-essential \
  cmake \
  git \
  libopenblas-dev \
  pkg-config \
  curl \
  ca-certificates

# ──────────────────────────── clonar / actualizar ──────────────────────────
if [ -d "${LLAMA_DIR}/.git" ]; then
  if $FORCE; then
    log_info "Directorio existente + --force: actualizando repo..."
    run_cmd git -C "${LLAMA_DIR}" fetch --prune
    if [ -n "${LLAMA_BRANCH}" ]; then
      run_cmd git -C "${LLAMA_DIR}" checkout "${LLAMA_BRANCH}"
      run_cmd git -C "${LLAMA_DIR}" reset --hard "origin/${LLAMA_BRANCH}" || \
        run_cmd git -C "${LLAMA_DIR}" reset --hard "${LLAMA_BRANCH}"
    else
      run_cmd git -C "${LLAMA_DIR}" reset --hard origin/HEAD
    fi
  else
    log_info "Repositorio ya existe en ${LLAMA_DIR}. Usando estado actual."
    log_info "Pasa --force para actualizar y recompilar."
  fi
else
  log_info "Clonando llama.cpp en ${LLAMA_DIR}..."
  run_cmd mkdir -p "$(dirname "${LLAMA_DIR}")"
  CLONE_ARGS=(--depth 1)
  [ -n "${LLAMA_BRANCH}" ] && CLONE_ARGS+=(--branch "${LLAMA_BRANCH}")
  run_cmd git clone "${CLONE_ARGS[@]}" "${LLAMA_REPO}" "${LLAMA_DIR}"
fi

# Mostrar commit actual
if ! $DRY_RUN; then
  COMMIT="$(git -C "${LLAMA_DIR}" log --oneline -1 2>/dev/null || echo "desconocido")"
  log_ok "Commit: ${COMMIT}"
fi

# ──────────────────────────── comprobar binarios ya instalados ─────────────
if ! $FORCE && ! $DRY_RUN; then
  ALL_INSTALLED=true
  for bin in "${BINARIES[@]}"; do
    [ -x "${INSTALL_DIR}/${bin}" ] || { ALL_INSTALLED=false; break; }
  done
  if $ALL_INSTALLED; then
    log_ok "Todos los binarios ya están en ${INSTALL_DIR}. Pasa --force para recompilar."
    if $NO_BUILD; then
      exit 0
    fi
  fi
fi

$NO_BUILD && { log_ok "Modo --no-build: saltando compilación."; exit 0; }

# ──────────────────────────── configurar cmake ─────────────────────────────
log_info "Configurando CMake para Cortex-A72..."

CMAKE_OPTS=(
  -S "${LLAMA_DIR}"
  -B "${BUILD_DIR}"
  -DCMAKE_BUILD_TYPE=Release

  # Flags específicos Cortex-A72
  "-DCMAKE_C_FLAGS=${CFLAGS_NATIVE}"
  "-DCMAKE_CXX_FLAGS=${CXXFLAGS_NATIVE}"

  # Activar NEON/ASIMD (asimd = Advanced SIMD = ARMv8 NEON)
  -DGGML_NATIVE=OFF           # OFF para que nuestros CFLAGS controlen -march
  -DGGML_NEON=ON              # Activa rutas de código NEON explícitamente
  -DGGML_FP16_VA=ON           # Operaciones FP16 via NEON (fp feature)
  -DGGML_OPENMP=ON            # Paralelismo con OpenMP (4 núcleos A72)

  # OpenBLAS para operaciones de matrices grandes
  -DGGML_BLAS=ON
  -DGGML_BLAS_VENDOR=OpenBLAS

  # Sin GPU (Raspi4B no tiene GPU Vulkan/CUDA)
  -DGGML_VULKAN=OFF
  -DGGML_METAL=OFF
  -DGGML_CUDA=OFF
  -DGGML_OPENCL=OFF

  # Construir herramientas
  -DLLAMA_BUILD_SERVER=ON
  -DLLAMA_BUILD_TESTS=OFF
  -DLLAMA_BUILD_EXAMPLES=ON
)

run_cmd cmake "${CMAKE_OPTS[@]}"

# ──────────────────────────── compilar ─────────────────────────────────────
log_info "Compilando con ${BUILD_JOBS} job(s)... (esto toma ~20-40 min en Raspi4B)"
run_cmd cmake --build "${BUILD_DIR}" --config Release --parallel "${BUILD_JOBS}"

# ──────────────────────────── instalar binarios ────────────────────────────
log_info "Instalando binarios en ${INSTALL_DIR}..."

INSTALLED=()
for bin in "${BINARIES[@]}"; do
  # llama.cpp puede producir los binarios en bin/ o en la raíz del build
  BIN_PATH=""
  for candidate in \
      "${BUILD_DIR}/bin/${bin}" \
      "${BUILD_DIR}/${bin}" \
      "${BUILD_DIR}/examples/${bin}/${bin}"; do
    [ -x "$candidate" ] && { BIN_PATH="$candidate"; break; }
  done

  if [ -n "${BIN_PATH}" ]; then
    run_cmd install -m 755 "${BIN_PATH}" "${INSTALL_DIR}/${bin}"
    INSTALLED+=("${bin}")
    log_ok "  ✓ ${INSTALL_DIR}/${bin}"
  else
    log_info "  - ${bin} no compilado (omitido)"
  fi
done

# ──────────────────────────── verificar ────────────────────────────────────
log_info "Verificando instalación..."
MISSING=()
for bin in "${INSTALLED[@]}"; do
  if ! "${INSTALL_DIR}/${bin}" --version >/dev/null 2>&1 && \
     ! "${INSTALL_DIR}/${bin}" --help    >/dev/null 2>&1; then
    MISSING+=("${bin}")
  else
    VER="$("${INSTALL_DIR}/${bin}" --version 2>/dev/null || echo "ok")"
    log_ok "  ${bin}: ${VER}"
  fi
done

[ "${#MISSING[@]}" -gt 0 ] && log_info "  No respondieron: ${MISSING[*]}" || true

log_ok ""
log_ok "╔══════════════════════════════════════════════════════╗"
log_ok "║  llama.cpp compilado e instalado para Cortex-A72    ║"
log_ok "╚══════════════════════════════════════════════════════╝"
log_ok ""
log_ok "Optimizaciones activas:"
log_ok "  -march=armv8-a+crc+simd   → ARMv8-A + CRC32 hw + NEON/SIMD"
log_ok "  -mtune=cortex-a72         → scheduling pipeline A72"
log_ok "  GGML_NEON=ON              → rutas NEON para inferencia"
log_ok "  GGML_BLAS=OpenBLAS        → BLAS para multiplicación de matrices"
log_ok "  GGML_OPENMP=ON            → paralelismo en 4 cores"
log_ok ""
log_ok "Binarios instalados en ${INSTALL_DIR}:"
for bin in "${INSTALLED[@]}"; do
  log_ok "  ${INSTALL_DIR}/${bin}"
done
log_ok ""
log_ok "Próximo paso: sudo bash scripts/setup-raspi4b-llm.sh"
log_ok "  (configura el servicio llama-server con un modelo .gguf)"
