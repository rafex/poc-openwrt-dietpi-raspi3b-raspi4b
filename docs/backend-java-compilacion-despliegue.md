# Backend Java — Compilación y despliegue en Raspberry Pi 4B

## Visión general

El backend Java de `ai-analyzer` se compila como un **binario nativo autónomo** usando
GraalVM Native Image. No requiere JVM, Python ni contenedor para ejecutarse — es un único
proceso Linux `arm64` que arranca en menos de 100 ms y consume ~80 MB de RAM en reposo.

```
┌─────────────────────────────────────────────────────────────────┐
│  Máquina de desarrollo (x86_64 / macOS)                         │
│                                                                  │
│  backend/java/ai-analyzer/   ←── código fuente Java 21          │
│  backend/java/ai-analyzer/db-lib/  ←── código fuente Rust       │
│                                                                  │
│  GraalVM 25 + cross-compiler aarch64-linux-gnu-gcc              │
│           │                                                      │
│           ▼                                                      │
│  ai-analyzer-linux-arm64          (binario ELF arm64, ~60 MB)   │
│  libanalyzer_db-linux-arm64.so    (cdylib Rust arm64, ~3 MB)    │
└─────────────────────────┬───────────────────────────────────────┘
                          │  GitHub Releases / ghcr.io
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│  RafexPi4B (arm64, DietPi Bookworm)                             │
│                                                                  │
│  Modo A — binario directo (systemd)                             │
│    /opt/ai-analyzer/bin/ai-analyzer   ←── proceso nativo        │
│    /opt/ai-analyzer/lib/*.so          ←── Rust cdylib           │
│                                                                  │
│  Modo B — contenedor podman                                     │
│    podman run ai-analyzer-java:v1.2.3                            │
│      └── mismo binario dentro de debian:bookworm-slim           │
└─────────────────────────────────────────────────────────────────┘
```

---

## 1. Arquitectura del código fuente

### Java — `backend/java/ai-analyzer/`

```
src/main/java/mx/rafex/analyzer/
├── Main.java          entrypoint, inicialización del servidor HTTP
├── config/            lectura de variables de entorno
├── db/                DbLibrary.java — bridge Java↔Rust via Panama FFI
├── http/              ApiServer.java — servidor HTTP con jdk.httpserver
├── llm/               cliente Groq + cliente llama.cpp local
├── mqtt/              suscriptor MQTT (sensor de red)
├── util/              helpers
└── worker/            análisis asíncrono de lotes de red
```

**Dependencia única externa:** `org.eclipse.paho:org.eclipse.paho.client.mqttv3:1.2.5`  
Todo lo demás es API estándar de Java 21.

### Rust — `backend/java/ai-analyzer/db-lib/`

```
src/
├── lib.rs         exports C ABI — funciones llamadas desde Java via Panama FFI
├── handle.rs      manejo de conexiones SQLite con pool (parking_lot)
├── batches.rs     persistencia de lotes MQTT
├── analyses.rs    resultados de análisis LLM
├── alerts.rs      alertas y severidades
├── domains.rs     clasificación de dominios
├── rules.rs       reglas de bloqueo
└── util.rs        serialización JSON
```

**SQLite se incluye en el `.so` en tiempo de compilación** (`rusqlite` con feature `bundled`).
No hay dependencia del sistema para SQLite en la Pi.

---

## 2. Herramientas de compilación

| Herramienta | Versión | Rol |
|---|---|---|
| **GraalVM CE 25** | 25.x | Compila código Java 21 → binario nativo arm64 |
| **native-maven-plugin** | 0.10.3 | Integración Maven para GraalVM Native Image |
| **Rust stable** | ≥1.78 | Compila `analyzer_db` → cdylib arm64 |
| **aarch64-linux-gnu-gcc** | sistema | Cross-linker para generar ELF arm64 en x86 |
| **QEMU user-static** | sistema | Permite ejecutar binarios arm64 en CI x86 |
| **Maven Wrapper** | (incluido) | `./mvnw` — no requiere Maven instalado |

> **Por qué GraalVM 25 para código Java 21:**  
> GraalVM 25 mejora el análisis estático de `native image`, produce binarios más pequeños,
> mejor PGO (Profile-Guided Optimization) y manejo nativo de Panama FFI sin flags extra.
> El código fuente se mantiene en Java 21 (`source`/`target` en pom.xml) para garantizar
> compatibilidad futura.

---

## 3. Proceso de compilación

### 3.1 Diagrama de fases

```
┌──────────────────────────────────────────────────────────────┐
│  FASE 1 — Rust (cross-compile aarch64)                       │
│                                                              │
│  cargo build --release --target aarch64-unknown-linux-gnu   │
│       │                                                      │
│       └─► libanalyzer_db-linux-arm64.so    (cdylib arm64)   │
└──────────────────────────────┬───────────────────────────────┘
                               │
┌──────────────────────────────▼───────────────────────────────┐
│  FASE 2 — Java fat JAR (bytecode Java 21)                    │
│                                                              │
│  ./mvnw package -DskipTests                                  │
│       │                                                      │
│       └─► target/ai-analyzer-fat.jar                        │
└──────────────────────────────┬───────────────────────────────┘
                               │
┌──────────────────────────────▼───────────────────────────────┐
│  FASE 3 — GraalVM Native Image arm64                         │
│                                                              │
│  ./mvnw -Pnative package -DskipTests                        │
│    -Dnative.compiler.path=aarch64-linux-gnu-gcc             │
│    -Dnative.imageName=ai-analyzer                           │
│    -Dnative.platform=aarch64-linux                          │
│       │                                                      │
│       GraalVM 25 analiza bytecode + traza Panama FFI calls   │
│       cross-compila a ELF arm64 via aarch64-linux-gnu-gcc   │
│       │                                                      │
│       └─► target/ai-analyzer    (binario ELF arm64)         │
└──────────────────────────────────────────────────────────────┘
```

### 3.2 Flags de Native Image (pom.xml — perfil `native`)

```xml
<buildArgs>
  <!-- DbLibrary usa MethodHandles.lookup() en runtime para Panama FFI -->
  <buildArg>--initialize-at-run-time=mx.rafex.analyzer.db.DbLibrary</buildArg>

  <!-- Sin fallback JVM: si no compila como nativo, falla el build -->
  <buildArg>--no-fallback</buildArg>

  <!-- Stack traces completos en excepciones no capturadas -->
  <buildArg>-H:+ReportExceptionStackTraces</buildArg>
</buildArgs>
```

> **Nota:** `-H:+ForeignAPISupport` fue eliminado. Panama FFI (Foreign Function & Memory API)
> es estable desde JDK 22 y está habilitado por defecto en GraalVM 22+. En GraalVM 25 ese
> flag genera un warning de opción obsoleta.

### 3.3 Panama FFI — cómo Java llama al código Rust

```java
// DbLibrary.java — cargado en runtime (initialize-at-run-time)
public class DbLibrary {
    static {
        // Carga la librería Rust desde LD_LIBRARY_PATH
        System.loadLibrary("analyzer_db");
    }

    // Métodos nativos declarados con Panama MethodHandle
    // → llaman directamente a funciones en libanalyzer_db.so
}
```

```rust
// lib.rs — funciones exportadas con C ABI
#[no_mangle]
pub extern "C" fn analyzer_db_open(path: *const c_char) -> *mut DbHandle { ... }

#[no_mangle]
pub extern "C" fn analyzer_db_save_batch(handle: *mut DbHandle, json: *const c_char) -> i32 { ... }
```

La librería Rust **incluye SQLite** en el propio `.so` gracias a `rusqlite = { features = ["bundled"] }`. No se requiere `libsqlite3-dev` en la Pi.

---

## 4. Compilar localmente (máquina de desarrollo)

### Prerequisitos

```bash
# Rust con target arm64
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
rustup target add aarch64-unknown-linux-gnu

# Cross-compiler arm64 (Ubuntu/Debian)
sudo apt install gcc-aarch64-linux-gnu

# macOS
brew install FiloSottile/musl-cross/musl-cross

# GraalVM 25 via SDKMAN (recomendado)
curl -s "https://get.sdkman.io" | bash
sdk install java 25-graalce
sdk use java 25-graalce

# Verificar
java -version   # debe mostrar: GraalVM CE 25...
native-image --version
```

### Compilar todo (Makefile)

```bash
# Compilar Rust arm64 + fat JAR + frontend Vite
make all

# Solo el binario nativo arm64 (requiere GraalVM 25 activo)
make native-arm64

# Solo la librería Rust arm64
make rust-arm64

# Solo el fat JAR (verificación rápida, no requiere GraalVM)
make fat-jar

# Compilar para el host (desarrollo local, no arm64)
make native      # binario x86_64 para pruebas locales
make rust        # librería x86_64

# Verificar sin compilar artefactos finales
make check       # cargo check + clippy + mvn compile
```

### Resultado en `dist/`

```bash
make dist   # copia artefactos a dist/
```

```
dist/
├── ai-analyzer-fat.jar              ← fat JAR JVM (fallback)
├── libanalyzer_db-linux-arm64.so    ← cdylib Rust arm64
└── frontend/dist/                   ← assets web compilados
```

---

## 5. Pipeline CI/CD — GitHub Actions

El repositorio tiene dos workflows relacionados con el backend Java:

### 5.1 `build-ai-analyzer.yml` — CI (verificación en cada push/PR)

Se dispara en cada push a `main` o PR con cambios en `backend/java/**`.

```
push/PR a main
      │
      ├── verify-rust        cargo check + clippy (host x86)
      ├── verify-java        mvn compile en Temurin 21 (host x86, sin GraalVM)
      ├── build-rust-arm64   cargo build --target aarch64-unknown-linux-gnu
      └── build-java-native-arm64   GraalVM 25 + QEMU → binario arm64
                │
                └── release   GitHub Release con binarios (solo en push a main)
```

### 5.2 `release-java.yml` — Release semántico (recomendado)

Se dispara al hacer `git push tag v*.*.*`.

```
git tag v1.2.3 && git push origin v1.2.3
      │
      ├── build-rust-arm64
      │         │
      ├── build-java-native-arm64
      │         │
      ├── github-release ──► GitHub Release v1.2.3
      │     ai-analyzer-linux-arm64
      │     libanalyzer_db-linux-arm64.so
      │     ai-analyzer-fat.jar
      │
      └── publish-java-image ──► ghcr.io/rafex/poc-ai-analyzer-java:v1.2.3
                                 ghcr.io/rafex/poc-ai-analyzer-java:latest
```

### 5.3 Publicar un release

```bash
# En la máquina de desarrollo
git tag v1.2.3 -m "Release v1.2.3"
git push origin v1.2.3
# → el workflow release-java.yml se ejecuta automáticamente en GitHub Actions
```

---

## 6. Despliegue en Raspberry Pi 4B

Hay **dos modos de despliegue** equivalentes en funcionalidad. Usa el que mejor se adapte a tu flujo.

### Modo A — Binario directo (systemd, sin podman)

El binario se ejecuta directamente como servicio systemd. Mínimo overhead, sin contenedor.

```
/opt/ai-analyzer/
├── bin/
│   └── ai-analyzer              ← binario ELF arm64
└── lib/
    └── libanalyzer_db.so        ← cdylib Rust arm64

/etc/ai-analyzer.env             ← variables de entorno (chmod 600)
/etc/systemd/system/ai-analyzer.service
```

**Desde la máquina admin (via Justfile):**

```bash
# Despliegue estándar (descarga el último release de GitHub)
just setup-java

# Release específico
just setup-java v1.2.3

# Solo verificar endpoints (sin redesplegar)
just verify-ai
```

**Directamente en la Pi (como root):**

```bash
# Clonar/actualizar el repo en la Pi
ssh root@192.168.1.167
cd /opt/repository/poc-openwrt-dietpi-raspi3b-raspi4b

# Instalar con el último release disponible
bash scripts/setup-raspi4b-ai-analyzer-java.sh

# Release específico
bash scripts/setup-raspi4b-ai-analyzer-java.sh --release=v1.2.3

# Solo verificar que los endpoints respondan
bash scripts/setup-raspi4b-ai-analyzer-java.sh --only-verify

# Ver qué haría sin ejecutar nada
bash scripts/setup-raspi4b-ai-analyzer-java.sh --dry-run
```

**¿Qué hace el script internamente?**

```
1. Instala age + sops (si no están presentes)
2. Descifra secrets/raspi4b.yaml → extrae GROQ_API_KEY en memoria
   (via sops+age, nunca escribe la clave al disco)
3. Descarga de GitHub Releases:
   https://github.com/rafex/.../releases/download/TAG/ai-analyzer-linux-arm64
   https://github.com/rafex/.../releases/download/TAG/libanalyzer_db-linux-arm64.so
4. Instala:
   /opt/ai-analyzer/bin/ai-analyzer    (chmod +x)
   /opt/ai-analyzer/lib/libanalyzer_db.so
5. Escribe /etc/ai-analyzer.env        (chmod 600)
6. Crea /etc/systemd/system/ai-analyzer.service
   Type=simple  MemoryMax=300M  Restart=on-failure
7. systemctl daemon-reload
   systemctl enable --now ai-analyzer
8. Verifica: curl http://127.0.0.1:5000/health
```

---

### Modo B — Contenedor podman (desde ghcr.io)

El mismo binario corre dentro de un contenedor `debian:bookworm-slim`. Útil para aislar
dependencias o mantener consistencia entre entornos.

```
podman container: ai-analyzer
  imagen: ghcr.io/rafex/poc-ai-analyzer-java:v1.2.3
  base:   debian:bookworm-slim
  red:    --network host  (el contenedor comparte la IP de la Pi)
  datos:  -v /opt/analyzer/data:/data:z    (SQLite persistente)
  llaves: -v /opt/keys:/opt/keys:ro,z      (SSH keys del portal)
  env:    --env-file /etc/ai-analyzer.env
```

**Desde la máquina admin (via Justfile):**

```bash
# Stack completo: backend Java + nginx web (recomendado)
just setup-containers

# Release específico
just setup-containers v1.2.3

# Solo backend Java (sin nginx)
just setup-java-container v1.2.3

# Sin acceso a ghcr.io: build local en la Pi desde GitHub Releases
just setup-java-build-local v1.2.3
```

**Directamente en la Pi (como root):**

```bash
ssh root@192.168.1.167
cd /opt/repository/poc-openwrt-dietpi-raspi3b-raspi4b

# Pull y arranque del stack completo (backend Java + nginx)
bash scripts/setup-raspi4b-containers.sh

# Release específico
bash scripts/setup-raspi4b-containers.sh --release=v1.2.3

# Solo backend (sin nginx web)
bash scripts/setup-raspi4b-containers.sh --release=v1.2.3 --skip-web

# Backend Python en lugar de Java
bash scripts/setup-raspi4b-containers.sh --backend=python

# Sin acceso a ghcr.io: construye la imagen localmente
# descargando los binarios de GitHub Releases
bash scripts/setup-raspi4b-containers.sh --build-local --release=v1.2.3

# Usar imágenes ya descargadas (sin pull)
bash scripts/setup-raspi4b-containers.sh --no-pull

# Solo verificar que los contenedores responden
bash scripts/setup-raspi4b-containers.sh --only-verify

# Previsualizar sin ejecutar nada
bash scripts/setup-raspi4b-containers.sh --dry-run
```

**¿Qué hace el script internamente?**

```
1. Instala age + sops (si no están)
2. Descifra secrets/raspi4b.yaml → GROQ_API_KEY en memoria
3. Login en ghcr.io (si GHCR_TOKEN está definido)
4. Escribe /etc/ai-analyzer.env              (chmod 600)
5. Crea /opt/analyzer/data/ y /opt/keys/
6. podman pull ghcr.io/rafex/poc-ai-analyzer-java:TAG
7. podman stop + rm del contenedor anterior (si existe)
8. podman create --name ai-analyzer
     --restart unless-stopped
     --network host
     --env-file /etc/ai-analyzer.env
     -v /opt/analyzer/data:/data:z
     -v /opt/keys:/opt/keys:ro,z
9. podman start ai-analyzer
10. Escribe /etc/systemd/system/ai-analyzer.service
    (Type=oneshot, ExecStart=podman start ai-analyzer)
11. systemctl enable ai-analyzer.service
12. Verifica /health, /api/stats, /api/whitelist
```

---

## 7. Variables de entorno en `/etc/ai-analyzer.env`

El archivo lo genera el script de despliegue automáticamente. Las variables más importantes:

```bash
# ── LLM ───────────────────────────────────────────────────────────────────────
GROQ_API_KEY=gsk_...          # descifrado de secrets/raspi4b.yaml via sops+age
GROQ_MODEL=qwen/qwen3-32b
GROQ_MAX_TOKENS=1024
LLAMA_URL=http://192.168.1.167:8081  # llama.cpp local (fallback sin Groq)

# ── MQTT ──────────────────────────────────────────────────────────────────────
MQTT_HOST=192.168.1.167       # broker Mosquitto en la propia Pi4B
MQTT_PORT=1883
MQTT_TOPIC=rafexpi/sensor/batch

# ── Base de datos ─────────────────────────────────────────────────────────────
DB_PATH=/data/sensor.db       # SQLite vía Rust (.so bundled)

# ── Red ───────────────────────────────────────────────────────────────────────
PORT=5000
ROUTER_IP=192.168.1.1
RASPI4B_IP=192.168.1.167
RASPI3B_IP=192.168.1.181
```

Editar manualmente después del despliegue:

```bash
ssh root@192.168.1.167
nano /etc/ai-analyzer.env     # editar
systemctl restart ai-analyzer # aplicar cambios
```

---

## 8. Gestión del servicio en la Pi

### Modo A (systemd directo)

```bash
# Estado
systemctl status ai-analyzer

# Logs en tiempo real
journalctl -u ai-analyzer -f

# Reiniciar
systemctl restart ai-analyzer

# Detener / arrancar
systemctl stop ai-analyzer
systemctl start ai-analyzer

# Ver variables de entorno activas
systemctl show-environment
cat /etc/ai-analyzer.env

# Verificar endpoints
curl -s http://127.0.0.1:5000/health | python3 -m json.tool
curl -s http://127.0.0.1:5000/api/stats | python3 -m json.tool
```

### Modo B (podman)

```bash
# Estado del contenedor
podman ps -a --filter name=ai-analyzer

# Logs en tiempo real
podman logs -f ai-analyzer

# Reiniciar
podman restart ai-analyzer

# Inspeccionar variables de entorno
podman inspect ai-analyzer | python3 -m json.tool | grep -A5 Env

# Entrar al contenedor (debug)
podman exec -it ai-analyzer /bin/bash

# Ver imagen usada
podman images | grep poc-ai-analyzer

# Actualizar a nueva versión sin el script completo
podman pull ghcr.io/rafex/poc-ai-analyzer-java:v1.3.0
podman stop ai-analyzer && podman rm ai-analyzer
podman create --name ai-analyzer --restart unless-stopped \
  --network host --env-file /etc/ai-analyzer.env \
  -v /opt/analyzer/data:/data:z \
  -v /opt/keys:/opt/keys:ro,z \
  ghcr.io/rafex/poc-ai-analyzer-java:v1.3.0
podman start ai-analyzer
```

### Desde la máquina admin (Justfile)

```bash
# Logs en tiempo real
just logs

# Estado systemd
just status

# Reiniciar
just restart

# Health check completo (Pi4B + endpoints)
just health-pi4b

# Verificar todos los nodos del sistema
just verify
```

---

## 9. Requisitos del sistema en la Pi

| Recurso | Mínimo | Recomendado |
|---|---|---|
| CPU | ARM Cortex-A72 (Pi4B) | — |
| RAM | ~80 MB (binario nativo) | 300 MB asignados vía systemd |
| Almacenamiento | 100 MB para binarios | 1 GB para datos SQLite |
| SO | DietPi Bookworm arm64 | — |
| Dependencias del SO | `libstdc++6` (para `.so` Rust) | ya incluido en Bookworm |
| Red | Acceso a Internet | Para GitHub Releases / Groq API |
| Secretos | `age` + `sops` | instalados automáticamente |

**Sin JVM, sin Python, sin runtime adicional.** El binario GraalVM Native Image
incluye todo lo necesario excepto `glibc` y `libstdc++6`, que son parte del sistema base.

---

## 10. Troubleshooting

### El servicio no arranca

```bash
journalctl -u ai-analyzer --no-pager -n 50
# Buscar: "cannot open shared object file: libanalyzer_db.so"
# → LD_LIBRARY_PATH no apunta al .so, o el .so falta

# Verificar que el .so está en su lugar
ls -lh /opt/ai-analyzer/lib/libanalyzer_db.so
# Verificar que LD_LIBRARY_PATH está en el .env o en el unit de systemd
grep LD_LIBRARY /etc/systemd/system/ai-analyzer.service
```

### `GROQ_API_KEY` no funciona

```bash
# Verificar que sops puede descifrar
SOPS_AGE_KEY_FILE=/root/.config/sops/age/keys.txt \
  sops -d secrets/raspi4b.yaml

# Si falla: la clave age no está en la Pi
# Desde la máquina admin:
just secrets-push   # o: bash scripts/secrets-push-key.sh
```

### La imagen podman no existe en ghcr.io

```bash
# Ver qué imágenes hay disponibles
podman search ghcr.io/rafex/poc-ai-analyzer

# Usar --build-local para construir desde GitHub Releases
bash scripts/setup-raspi4b-containers.sh --build-local --release=v1.2.3
```

### Puerto 5000 ya en uso

```bash
ss -tlnp | grep 5000
# Si hay otro proceso en :5000:
systemctl stop ai-analyzer-python 2>/dev/null || true
podman stop ai-analyzer-python 2>/dev/null || true
systemctl start ai-analyzer
```

### Binario rechazado por arquitectura incorrecta

```bash
file /opt/ai-analyzer/bin/ai-analyzer
# Debe mostrar: ELF 64-bit LSB executable, ARM aarch64
# Si muestra x86-64: el CI compiló mal, abrir issue en el repo
```

---

## 11. Flujo completo de punta a punta

### Primera vez (setup desde cero)

```bash
# ── En la máquina admin ────────────────────────────────────────────────────────

# 1. Inicializar secretos (una sola vez)
just secrets-init
just secrets-set GROQ_API_KEY=gsk_xxxxxxxxxxxx

# 2. Copiar clave age a la Pi (para que pueda descifrar en cada deploy)
just secrets-push

# 3. Publicar un release (dispara el CI de GitHub Actions)
git tag v1.0.0 -m "Primera versión"
git push origin v1.0.0
# → esperar ~15 min a que el CI compile y publique en ghcr.io

# 4a. Despliegue Modo A — binario directo
just setup-java v1.0.0

# 4b. Despliegue Modo B — contenedor podman
just setup-containers v1.0.0
```

### Actualizar a una nueva versión

```bash
# Publicar nueva versión
git tag v1.1.0 -m "Nueva versión"
git push origin v1.1.0
# → esperar a que el CI termine

# Actualizar la Pi
just setup-java v1.1.0           # Modo A
just setup-containers v1.1.0     # Modo B
```

### Sin tags (deploy del último commit de main)

```bash
# El CI crea un release automático en cada push a main con tag:
# v20260430-abc1234

# Ver el release disponible en GitHub:
# https://github.com/rafex/presentaciones-cursos-talleres/releases/latest

# Desplegar el último release
just setup-java         # usa RELEASE_TAG=latest por defecto
just setup-containers   # ídem
```
