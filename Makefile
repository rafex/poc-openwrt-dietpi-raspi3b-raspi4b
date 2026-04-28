# =============================================================================
# Makefile — RESPONSABILIDAD ÚNICA: CONSTRUCCIÓN DE ARTEFACTOS
# =============================================================================
# Qué hace este archivo:
#   • Compilar la librería Rust (cdylib) para host y arm64
#   • Compilar el fat JAR Java (via Maven Wrapper ./mvnw)
#   • Compilar el binario GraalVM Native Image arm64
#   • Limpiar artefactos de build
#
# Qué NO hace:
#   • Desplegar en Pi (→ Justfile)
#   • Gestionar secretos (→ Justfile)
#   • Conectar a WiFi, SSH, etc. (→ Justfile)
#
# Uso:
#   make                     # equivalente a: make all
#   make rust                # solo Rust host (para desarrollo)
#   make rust-arm64          # cross-compile Rust → aarch64
#   make fat-jar             # fat JAR Java (requiere JDK 21)
#   make native-arm64        # GraalVM native image arm64 (requiere GraalVM CE 21)
#   make all                 # rust-arm64 + fat-jar (sin native, usa CI para eso)
#   make check               # cargo check + clippy (sin compilar)
#   make clean               # eliminar todos los artefactos
#   make dist                # copiar artefactos a dist/
# =============================================================================

.DEFAULT_GOAL := all
.PHONY: all rust rust-arm64 fat-jar native native-arm64 check clean dist \
        _ensure-rust _ensure-java _ensure-graalvm

# ── Rutas ────────────────────────────────────────────────────────────────────
ROOT_DIR     := $(shell pwd)
RUST_DIR     := $(ROOT_DIR)/backend/ai-analyzer/db-lib
JAVA_DIR     := $(ROOT_DIR)/backend/ai-analyzer-java
DIST_DIR     := $(ROOT_DIR)/dist

MVNW         := $(JAVA_DIR)/mvnw
CARGO        := cargo

# ── Nombres de artefactos ────────────────────────────────────────────────────
RUST_LIB_HOST   := $(RUST_DIR)/target/release/libanalyzer_db.so
RUST_LIB_ARM64  := $(RUST_DIR)/target/aarch64-unknown-linux-gnu/release/libanalyzer_db.so
RUST_STATICLIB_HOST  := $(RUST_DIR)/target/release/libanalyzer_db.a
FAT_JAR         := $(JAVA_DIR)/target/ai-analyzer-fat.jar
NATIVE_BIN      := $(JAVA_DIR)/target/ai-analyzer
NATIVE_BIN_ARM64 := $(JAVA_DIR)/target/ai-analyzer

# ── Cross-compilación Rust arm64 ──────────────────────────────────────────────
RUST_ARM64_TARGET  := aarch64-unknown-linux-gnu
RUST_ARM64_LINKER  := aarch64-linux-gnu-gcc   # apt: gcc-aarch64-linux-gnu

# =============================================================================
# Targets principales
# =============================================================================

## all: Construir Rust (arm64) + fat JAR. Objetivo por defecto.
all: rust-arm64 fat-jar
	@echo ""
	@echo "✓ Build completo:"
	@echo "  Rust .so (arm64)  : $(RUST_LIB_ARM64)"
	@echo "  Fat JAR           : $(FAT_JAR)"

## rust: Compilar libanalyzer_db.so para el host (desarrollo/test local)
rust: _ensure-rust
	@echo "── Compilando Rust (host) ──────────────────────────────────────"
	cd $(RUST_DIR) && $(CARGO) build --release
	@echo "✓ $(RUST_LIB_HOST)"

## rust-arm64: Cross-compilar libanalyzer_db.so para aarch64 (Pi4B)
rust-arm64: _ensure-rust
	@echo "── Cross-compilando Rust → aarch64-linux-gnu ───────────────────"
	@command -v $(RUST_ARM64_LINKER) >/dev/null 2>&1 || { \
	  echo "ERROR: $(RUST_ARM64_LINKER) no encontrado."; \
	  echo "  macOS: brew install FiloSottile/musl-cross/musl-cross"; \
	  echo "  Linux: sudo apt install gcc-aarch64-linux-gnu"; \
	  exit 1; }
	cd $(RUST_DIR) && \
	  CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=$(RUST_ARM64_LINKER) \
	  $(CARGO) build --release --target $(RUST_ARM64_TARGET)
	@echo "✓ $(RUST_LIB_ARM64)"

## fat-jar: Compilar el fat JAR Java con Maven Wrapper (./mvnw)
fat-jar: _ensure-java
	@echo "── Compilando fat JAR Java (Maven Wrapper) ─────────────────────"
	cd $(JAVA_DIR) && $(MVNW) package -q -DskipTests
	@echo "✓ $(FAT_JAR)"
	@ls -lh $(FAT_JAR)

## native: GraalVM Native Image para el host (prueba local — no arm64)
native: fat-jar _ensure-graalvm
	@echo "── GraalVM Native Image (host) ─────────────────────────────────"
	cd $(JAVA_DIR) && $(MVNW) -Pnative package -q -DskipTests \
	  -Danalyzer.db.lib=$(RUST_LIB_HOST)
	@echo "✓ $(NATIVE_BIN)"
	@ls -lh $(NATIVE_BIN)

## native-arm64: GraalVM Native Image arm64 (requiere GraalVM CE 21 + QEMU, usar en CI)
native-arm64: fat-jar rust-arm64 _ensure-graalvm
	@echo "── GraalVM Native Image (arm64) ────────────────────────────────"
	@echo "  NOTA: cross-compilation GraalVM requiere QEMU+binfmt en CI."
	@echo "  En desarrollo local usar el fat JAR + binario Rust arm64."
	cd $(JAVA_DIR) && $(MVNW) -Pnative package -q -DskipTests \
	  -Dnative.imageName=ai-analyzer \
	  -Dnative.platform=aarch64-linux \
	  -Dnative.compiler.path=$(RUST_ARM64_LINKER)
	@echo "✓ $(NATIVE_BIN_ARM64)-linux-arm64"

## check: Verificar código sin compilar artefactos finales
check: _ensure-rust _ensure-java
	@echo "── cargo check + clippy ────────────────────────────────────────"
	cd $(RUST_DIR) && $(CARGO) check
	cd $(RUST_DIR) && $(CARGO) clippy -- -D warnings
	@echo "── Maven compile (sin package) ─────────────────────────────────"
	cd $(JAVA_DIR) && $(MVNW) compile -q -DskipTests
	@echo "✓ Verificación OK"

## clean: Eliminar todos los artefactos de build
clean:
	@echo "── Limpiando Rust ──────────────────────────────────────────────"
	cd $(RUST_DIR) && $(CARGO) clean
	@echo "── Limpiando Java ──────────────────────────────────────────────"
	cd $(JAVA_DIR) && $(MVNW) clean -q 2>/dev/null || rm -rf $(JAVA_DIR)/target
	@echo "── Limpiando dist/ ─────────────────────────────────────────────"
	rm -rf $(DIST_DIR)
	@echo "✓ Limpieza completa"

## dist: Copiar artefactos finales a dist/ (para releases manuales)
dist: rust-arm64 fat-jar
	@echo "── Copiando artefactos a dist/ ─────────────────────────────────"
	mkdir -p $(DIST_DIR)
	cp $(RUST_LIB_ARM64) $(DIST_DIR)/libanalyzer_db-linux-arm64.so
	cp $(FAT_JAR)        $(DIST_DIR)/ai-analyzer-fat.jar
	@echo "✓ dist/:"
	@ls -lh $(DIST_DIR)

# =============================================================================
# Targets de verificación de dependencias (internos)
# =============================================================================

_ensure-rust:
	@command -v $(CARGO) >/dev/null 2>&1 || { \
	  echo "ERROR: cargo no encontrado. Instala Rust: https://rustup.rs"; \
	  exit 1; }
	@$(CARGO) target list --installed 2>/dev/null | grep -q $(RUST_ARM64_TARGET) \
	  || (cd $(RUST_DIR) && rustup target add $(RUST_ARM64_TARGET))

_ensure-java:
	@command -v java >/dev/null 2>&1 || { \
	  echo "ERROR: java no encontrado. Instala JDK 21."; \
	  exit 1; }
	@java -version 2>&1 | grep -q '21\.' || { \
	  echo "ADVERTENCIA: Se recomienda JDK 21 (actual: $$(java -version 2>&1 | head -1))"; }
	@[ -x "$(MVNW)" ] || { \
	  echo "ERROR: $(MVNW) no encontrado o no ejecutable."; \
	  exit 1; }

_ensure-graalvm:
	@java -version 2>&1 | grep -qi 'graalvm\|native' || { \
	  echo "ADVERTENCIA: GraalVM no detectado — native image puede fallar."; \
	  echo "  Instala GraalVM CE 21: https://github.com/graalvm/graalvm-ce-builds"; }

# =============================================================================
# Help
# =============================================================================

## help: Mostrar esta ayuda
help:
	@echo ""
	@echo "Makefile — BUILD ONLY (ai-analyzer)"
	@echo "Para tareas operacionales: just --list"
	@echo ""
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/## /  make /' | column -t -s ':'
	@echo ""
