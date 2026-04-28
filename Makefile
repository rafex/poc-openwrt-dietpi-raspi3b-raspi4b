# =============================================================================
# Makefile — RESPONSABILIDAD ÚNICA: CONSTRUCCIÓN DE ARTEFACTOS
# =============================================================================
# Qué hace este archivo:
#   • Compilar la librería Rust (cdylib) para host y arm64
#   • Compilar el fat JAR Java (via Maven Wrapper ./mvnw)
#   • Compilar el binario GraalVM Native Image arm64
#   • Construir el frontend (Pug + Sass + TypeScript vía Vite)
#   • Gestionar documentación Javadoc y cabeceras de licencia MIT
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
#   make frontend            # compilar frontend (Pug→HTML + Sass + TS + Vite)
#   make all                 # rust-arm64 + fat-jar + frontend
#   make check               # cargo check + clippy (sin compilar)
#   make clean               # eliminar todos los artefactos
#   make dist                # copiar artefactos a dist/
#
# Maven lifecycle → targets de este Makefile:
#   validate         → license-check    (check-file-header — falla si falta MIT)
#   generate-sources → license-update   (update-file-header + update-project-license)
#   process-sources  → license-add      (segunda pasada update-file-header)
#   package          → fat-jar          (shade fat JAR + attach-javadocs)
#   javadoc:fix      → javadoc-fix      (genera stubs — invocación MANUAL)
#   mvn -Pnative pkg → native-arm64     (GraalVM native image arm64)
# =============================================================================

.DEFAULT_GOAL := all
.PHONY: all rust rust-arm64 fat-jar native native-arm64 frontend check clean dist \
        license-check license-update license-add javadoc javadoc-fix \
        _ensure-rust _ensure-java _ensure-graalvm _ensure-node

# ── Rutas ────────────────────────────────────────────────────────────────────
ROOT_DIR     := $(shell pwd)
RUST_DIR     := $(ROOT_DIR)/backend/java/ai-analyzer/db-lib
JAVA_DIR     := $(ROOT_DIR)/backend/java/ai-analyzer
PYTHON_DIR   := $(ROOT_DIR)/backend/python/ai-analyzer
DIST_DIR     := $(ROOT_DIR)/dist

FRONTEND_DIR := $(ROOT_DIR)/frontend

MVNW         := $(JAVA_DIR)/mvnw
CARGO        := cargo
NPM          := npm

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

## all: Construir Rust (arm64) + fat JAR + frontend. Objetivo por defecto.
all: rust-arm64 fat-jar frontend
	@echo ""
	@echo "✓ Build completo:"
	@echo "  Rust .so (arm64)  : $(RUST_LIB_ARM64)"
	@echo "  Fat JAR           : $(FAT_JAR)"
	@echo "  Frontend dist/    : $(FRONTEND_DIR)/dist"

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

## frontend: Compilar frontend — Pug→HTML, Sass, TypeScript vía Vite
frontend: _ensure-node
	@echo "── Instalando dependencias npm ─────────────────────────────────"
	cd $(FRONTEND_DIR) && $(NPM) install --prefer-offline
	@echo "── Build frontend (pug + sass + ts + vite) ─────────────────────"
	cd $(FRONTEND_DIR) && $(NPM) run build
	@echo "✓ $(FRONTEND_DIR)/dist"
	@ls -lh $(FRONTEND_DIR)/dist 2>/dev/null | head -20

# =============================================================================
# Java / Maven — Documentación y Licencias MIT
# =============================================================================
# Ciclo Maven que activan estos targets:
#
#   license-check  →  mvn validate
#                       └─ check-file-header   (falla si falta cabecera MIT)
#
#   license-update →  mvn generate-sources
#                       ├─ update-file-header   (agrega/actualiza cabecera MIT)
#                       └─ update-project-license (escribe archivo LICENSE)
#
#   license-add    →  mvn process-sources
#                       └─ update-file-header   (segunda pasada add-license)
#
#   fat-jar        →  mvn package -DskipTests
#                       └─ attach-javadocs      (genera y adjunta javadoc.jar)
#
#   javadoc        →  mvn javadoc:javadoc       (solo genera HTML, sin empaquetar)
#
#   javadoc-fix    →  mvn javadoc:fix           (MANUAL — genera stubs en fuentes)
#                       ¡Modifica archivos .java! Revisar con git diff antes de commit.
#
#   native-arm64   →  mvn -Pnative package      (GraalVM native image arm64)
# =============================================================================

## license-check: [validate] Verificar que todos los .java tienen cabecera MIT
license-check: _ensure-java
	@echo "── Maven validate → check-file-header (licencia MIT) ───────────"
	cd $(JAVA_DIR) && $(MVNW) validate -q
	@echo "✓ Todas las cabeceras MIT presentes"

## license-update: [generate-sources] Agregar/actualizar cabeceras MIT + archivo LICENSE
license-update: _ensure-java
	@echo "── Maven generate-sources → update-file-header + update-project-license ──"
	cd $(JAVA_DIR) && $(MVNW) generate-sources -q
	@echo "✓ Cabeceras MIT actualizadas y LICENSE escrito"

## license-add: [process-sources] Segunda pasada — agrega cabecera MIT donde falte
license-add: _ensure-java
	@echo "── Maven process-sources → update-file-header (add-license) ───"
	cd $(JAVA_DIR) && $(MVNW) process-sources -q
	@echo "✓ Cabeceras MIT añadidas (process-sources)"

## javadoc: Generar Javadoc HTML sin empaquetar (mvn javadoc:javadoc)
javadoc: _ensure-java
	@echo "── Maven javadoc:javadoc → generando HTML en target/site/apidocs ─"
	cd $(JAVA_DIR) && $(MVNW) javadoc:javadoc -q
	@echo "✓ Javadoc HTML:"
	@ls -lh $(JAVA_DIR)/target/site/apidocs/index.html 2>/dev/null || \
	  echo "  (ver $(JAVA_DIR)/target/site/apidocs/)"

## javadoc-fix: [MANUAL] Generar stubs Javadoc en el código fuente (mvn javadoc:fix)
## ATENCION: modifica archivos .java — revisar con 'git diff' antes de hacer commit
javadoc-fix: _ensure-java
	@echo "── Maven javadoc:fix → generando stubs en src/main/java ────────"
	@echo "  ⚠  Este target modifica archivos fuente. Revisa con: git diff"
	@printf "  ¿Continuar? [s/N] "; read ans; [ "$$ans" = "s" ] || { echo "Cancelado."; exit 0; }
	cd $(JAVA_DIR) && $(MVNW) javadoc:fix
	@echo "✓ Stubs Javadoc generados — revisa los cambios antes de commit"

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
	@echo "── Limpiando Frontend ──────────────────────────────────────────"
	rm -rf $(FRONTEND_DIR)/dist
	@echo "── Limpiando dist/ ─────────────────────────────────────────────"
	rm -rf $(DIST_DIR)
	@echo "✓ Limpieza completa"

## dist: Copiar artefactos finales a dist/ (para releases manuales)
dist: rust-arm64 fat-jar frontend
	@echo "── Copiando artefactos a dist/ ─────────────────────────────────"
	mkdir -p $(DIST_DIR)/frontend
	cp $(RUST_LIB_ARM64)      $(DIST_DIR)/libanalyzer_db-linux-arm64.so
	cp $(FAT_JAR)             $(DIST_DIR)/ai-analyzer-fat.jar
	cp -r $(FRONTEND_DIR)/dist $(DIST_DIR)/frontend/
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

_ensure-node:
	@command -v node >/dev/null 2>&1 || { \
	  echo "ERROR: node no encontrado. Instala Node.js >= 20: https://nodejs.org"; \
	  exit 1; }
	@command -v $(NPM) >/dev/null 2>&1 || { \
	  echo "ERROR: npm no encontrado."; \
	  exit 1; }
	@node --version | grep -qE '^v(2[0-9]|[3-9][0-9])' || { \
	  echo "ADVERTENCIA: Se recomienda Node.js >= 20 (actual: $$(node --version))"; }

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
