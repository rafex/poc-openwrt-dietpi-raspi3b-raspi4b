# =============================================================================
# ai-analyzer Java — Imagen de runtime (GraalVM Native Image + libanalyzer_db.so)
# Arquitectura: linux/arm64  (Raspberry Pi 4B — DietPi Bookworm)
#
# Este Dockerfile NO compila el código. Espera los binarios ya compilados
# en el contexto de build (raíz del contexto):
#   ai-analyzer-linux-arm64          ← binario GraalVM Native arm64
#   libanalyzer_db-linux-arm64.so    ← cdylib Rust arm64
#
# El CI (release-java.yml) coloca los artefactos ahí automáticamente.
#
# Build manual (tras make native-arm64 y make rust-arm64):
#   mkdir -p _docker_ctx
#   cp backend/java/ai-analyzer/target/ai-analyzer          _docker_ctx/ai-analyzer-linux-arm64
#   cp backend/java/ai-analyzer/db-lib/target/aarch64-unknown-linux-gnu/release/libanalyzer_db.so \
#      _docker_ctx/libanalyzer_db-linux-arm64.so
#   cp backend/java/ai-analyzer/Dockerfile _docker_ctx/
#   podman build --platform linux/arm64 -t ai-analyzer-java:dev _docker_ctx/
# =============================================================================

FROM debian:bookworm-slim

# ── Dependencias de runtime ───────────────────────────────────────────────────
# IMPORTANTE: GraalVM Native Images usan glibc — Alpine/musl NO es compatible.
# libstdc++6  : runtime C++ requerido por libanalyzer_db.so (Rust cdylib vía Panama FFI)
# ca-certificates : TLS para Groq API y MQTT con TLS
# wget        : usado por HEALTHCHECK
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
        libstdc++6 \
        ca-certificates \
        wget \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/ai-analyzer

# ── Binarios compilados ───────────────────────────────────────────────────────
COPY ai-analyzer-linux-arm64        ./bin/ai-analyzer
COPY libanalyzer_db-linux-arm64.so  ./lib/libanalyzer_db.so

# ── Directorios de runtime ────────────────────────────────────────────────────
# /data      → base de datos SQLite  (montar como volumen: -v /opt/analyzer/data:/data:z)
# /opt/keys  → llaves SSH del portal (montar como volumen: -v /opt/keys:/opt/keys:ro,z)
RUN mkdir -p /data /opt/keys && chmod +x ./bin/ai-analyzer

# ── Variables de entorno por defecto ─────────────────────────────────────────
# La mayoría se sobreescriben en tiempo de ejecución via --env-file
ENV LD_LIBRARY_PATH=/opt/ai-analyzer/lib \
    PORT=5000 \
    LOG_LEVEL=INFO

EXPOSE 5000

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD wget -qO- "http://localhost:${PORT}/health" >/dev/null 2>&1 || exit 1

CMD ["/opt/ai-analyzer/bin/ai-analyzer"]
