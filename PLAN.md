# PLAN — Migración a Rust de los programas IA

## Contexto

Los dos programas candidatos a migrar son:

| Programa | Lenguaje actual | Plataforma | Función |
|---|---|---|---|
| `backend/ai-analyzer/analyzer.py` | Python 3.11 | RafexPi4B (arm64) | MQTT subscriber + SQLite + HTTP API + SSE + worker LLM |
| `sensor/sensor.py` | Python 3.11 | RafexPi3B (armv7) | tshark capture + TrafficAggregator + MQTT publish |

---

## Por qué Rust tiene sentido aquí

| Problema actual (Python) | Ganancia con Rust |
|---|---|
| Imagen Docker `python:3.11-alpine` = ~60MB + deps = ~120MB total | Binario estático ~8–15MB, imagen `scratch` o `distroless` |
| Tiempo de arranque del pod ~3–5s (importar módulos) | Arranque <100ms |
| GIL limita el worker thread real | Concurrencia sin GIL — `tokio` tasks reales |
| ~80MB RAM en reposo (Python runtime) | ~5–10MB RAM en reposo |
| tshark subprocess parsing en Python con split | Parsing zero-copy con `nom` o manejo de bytes |
| `paho-mqtt` wrapper C — dependencia nativa en Alpine | `rumqttc` puro Rust, sin C |

---

## Programas a migrar

### 1. `sensor` — RafexPi3B (armv7)

**Función:** captura tshark → agrega tráfico → publica batch MQTT cada 30s

#### Dependencias actuales → crates equivalentes

| Python | Rust crate | Notas |
|---|---|---|
| `subprocess` (tshark) | `std::process::Command` | igual de simple |
| `threading.Thread` | `std::thread` o `tokio::spawn` | más ligero |
| `dict` + `Lock` (TrafficAggregator) | `std::collections::HashMap` + `std::sync::Mutex` | |
| `paho-mqtt` | `rumqttc` | puro Rust, async o sync |
| `requests` (fallback HTTP) | `reqwest` (blocking) o `ureq` | `ureq` es más ligero |
| `json` | `serde_json` | |
| `socket` (SSH al router) | `ssh2` crate | wrapper libssh2 |

#### Estructura del binario

```
sensor/
└── rust/
    ├── Cargo.toml
    └── src/
        ├── main.rs
        ├── capture.rs      # lanza tshark, parsea líneas tab-separated
        ├── aggregator.rs   # TrafficAggregator: stats por IP, escaneos
        ├── publisher.rs    # MQTT publish + HTTP fallback
        └── router.rs       # SSH opcional al router (conntrack + leases)
```

#### `Cargo.toml` (dependencias mínimas)

```toml
[package]
name = "sensor"
version = "0.1.0"
edition = "2021"

[dependencies]
rumqttc   = { version = "0.24", default-features = false, features = ["use-rustls"] }
ureq      = { version = "2.9", features = ["json"] }
serde     = { version = "1", features = ["derive"] }
serde_json = "1"
ssh2      = { version = "0.9", optional = true }

[features]
router-ssh = ["ssh2"]

[profile.release]
opt-level = "z"     # minimizar tamaño
lto = true
strip = true
```

#### Cross-compilación para armv7 (RafexPi3B)

```bash
# En la máquina de desarrollo (x86_64 Linux o macOS)
rustup target add armv7-unknown-linux-gnueabihf

# Con cross (herramienta recomendada — usa Docker internamente)
cargo install cross
cross build --release --target armv7-unknown-linux-gnueabihf

# Resultado
ls -lh target/armv7-unknown-linux-gnueabihf/release/sensor
# → ~3–5 MB estático

# Copiar a la Pi
scp target/armv7-unknown-linux-gnueabihf/release/sensor root@192.168.1.181:/opt/sensor/sensor
```

---

### 2. `ai-analyzer` — RafexPi4B (arm64)

**Función:** MQTT subscriber → SQLite queue → worker thread → llama.cpp HTTP → HTTP API + SSE

#### Dependencias actuales → crates equivalentes

| Python | Rust crate | Notas |
|---|---|---|
| `http.server.BaseHTTPRequestHandler` | `axum` | async, ergonómico |
| `threading.Thread` + `queue.Queue` | `tokio::sync::mpsc` | |
| `sqlite3` | `rusqlite` + `r2d2` (pool) | |
| `paho-mqtt` | `rumqttc` | async con tokio |
| `requests` (llama.cpp client) | `reqwest` | async |
| `json` | `serde_json` | |
| SSE (`/api/stream`) | `axum::response::Sse` | built-in en axum |
| `open().read()` (HTML estático) | `include_str!()` macro | embed en el binario |

#### Estructura del binario

```
backend/ai-analyzer/
└── rust/
    ├── Cargo.toml
    └── src/
        ├── main.rs         # inicialización, tokio runtime, arranque servicios
        ├── config.rs       # variables de entorno (envy o dotenvy)
        ├── db.rs           # rusqlite: init schema, CRUD batches/analyses
        ├── mqtt.rs         # rumqttc subscriber, on_message → enqueue
        ├── worker.rs       # tokio task: consume cola, llama llama.cpp
        ├── llama.rs        # reqwest POST /completion, build_prompt
        ├── api/
        │   ├── mod.rs
        │   ├── ingest.rs   # POST /api/ingest
        │   ├── history.rs  # GET /api/history
        │   ├── stats.rs    # GET /api/stats
        │   ├── queue.rs    # GET /api/queue
        │   ├── stream.rs   # GET /api/stream (SSE)
        │   └── health.rs   # GET /health
        └── static/
            ├── dashboard.html   # embebido con include_str!()
            └── terminal.html
```

#### `Cargo.toml`

```toml
[package]
name = "ai-analyzer"
version = "0.1.0"
edition = "2021"

[dependencies]
tokio      = { version = "1", features = ["full"] }
axum       = "0.7"
rumqttc    = "0.24"
rusqlite   = { version = "0.31", features = ["bundled"] }  # bundled = sin sqlite3 del SO
reqwest    = { version = "0.12", features = ["json"] }
serde      = { version = "1", features = ["derive"] }
serde_json = "1"
tracing    = "0.1"
tracing-subscriber = "0.3"
tokio-stream = "0.1"   # para SSE

[profile.release]
opt-level = "z"
lto = true
strip = true
```

#### Cross-compilación para arm64 (RafexPi4B)

```bash
rustup target add aarch64-unknown-linux-gnu

cross build --release --target aarch64-unknown-linux-gnu

ls -lh target/aarch64-unknown-linux-gnu/release/ai-analyzer
# → ~8–12 MB estático (incluye SQLite y TLS)

scp target/aarch64-unknown-linux-gnu/release/ai-analyzer root@192.168.1.167:/opt/analyzer/
```

---

## Imagen Docker con Rust

### Dockerfile multi-stage (ai-analyzer)

```dockerfile
# ── Etapa 1: compilar ─────────────────────────────────────────────────────────
FROM --platform=linux/amd64 rust:1.78-alpine AS builder

RUN apk add --no-cache musl-dev

WORKDIR /app
COPY backend/ai-analyzer/rust/ .

# Target arm64 estático
RUN rustup target add aarch64-unknown-linux-musl
RUN cargo build --release --target aarch64-unknown-linux-musl

# ── Etapa 2: imagen mínima ────────────────────────────────────────────────────
FROM scratch
COPY --from=builder /app/target/aarch64-unknown-linux-musl/release/ai-analyzer /analyzer
ENTRYPOINT ["/analyzer"]
```

**Resultado:** imagen final ~12MB vs ~120MB actual.

---

## Comparativa de recursos (estimada)

| Métrica | Python actual | Rust migrado |
|---|---|---|
| Imagen Docker (ai-analyzer) | ~120 MB | ~12 MB |
| RAM en reposo | ~80 MB | ~8 MB |
| Tiempo de arranque del pod | ~4s | <150ms |
| Latencia `/health` | ~5ms | <1ms |
| CPU captura tshark (sensor) | ~8% | ~3% |
| Binario sensor en Pi3B | N/A (Python) | ~4 MB |

---

## Plan de ejecución por fases

### Fase 1 — Sensor (2–3 días)

Más simple: un solo proceso, sin HTTP server, sin async complejo.

- [ ] `capture.rs` — lanzar tshark, parsear 18 campos tab-separated
- [ ] `aggregator.rs` — TrafficAggregator: HashMap por IP, detección de escaneos
- [ ] `publisher.rs` — MQTT publish con `rumqttc` + fallback HTTP con `ureq`
- [ ] `main.rs` — loop principal, señal SIGTERM para shutdown limpio
- [ ] Cross-compilar para `armv7-unknown-linux-gnueabihf`
- [ ] Reemplazar `sensor.py` en la Pi3B, ajustar el servicio init.d

### Fase 2 — AI Analyzer sin SSE (3–4 días)

- [ ] `db.rs` — rusqlite, mismo schema SQL, WAL mode
- [ ] `mqtt.rs` — subscriber async con rumqttc + tokio
- [ ] `worker.rs` — tokio task, mpsc channel, procesa un batch a la vez
- [ ] `llama.rs` — reqwest POST /completion, build_prompt (tinyllama + qwen)
- [ ] `api/` — axum router: `/health`, `/api/ingest`, `/api/history`, `/api/stats`, `/api/queue`
- [ ] Prueba de regresión: batch completo sensor → MQTT → SQLite → llama.cpp → response

### Fase 3 — SSE + HTML estático (1–2 días)

- [ ] `api/stream.rs` — `axum::response::Sse` + `tokio_stream::wrappers::BroadcastStream`
- [ ] Embed `dashboard.html` y `terminal.html` con `include_str!()`
- [ ] Verificar que el terminal en vivo funciona igual que con Python

### Fase 4 — Docker + k8s (1 día)

- [ ] Dockerfile multi-stage con `scratch` como imagen final
- [ ] `podman build --cgroup-manager=cgroupfs --platform linux/arm64`
- [ ] `podman save | k3s ctr images import -`
- [ ] `kubectl apply` — sin cambios en los manifiestos YAML existentes

---

## Riesgos y consideraciones

| Riesgo | Mitigación |
|---|---|
| `rusqlite` con `features = ["bundled"]` aumenta tiempo de compilación | Aceptable en CI; en la Pi compilar con cross desde el laptop |
| `rumqttc` async requiere runtime tokio — más complejo que paho-mqtt sync | Usar `rumqttc` en modo sync (`MqttOptions` + `Client` sin async) para simplificar |
| SSE con axum requiere entender `Stream` trait | Usar `BroadcastSender<String>` en el worker y `BroadcastStream` en el handler |
| Cross-compilación musl para arm — algunos crates con C nativo fallan | `rusqlite --features bundled` y `reqwest --features rustls-tls` evitan deps C |
| RafexPi3B es armv7 (32-bit) — algunos crates asumen 64-bit | Verificar con `cross check` antes de invertir tiempo en la implementación |
| Tiempo de migración vs valor añadido para la demo | Migrar primero el sensor (más simple, mayor ganancia en Pi3B limitada) |

---

## Decisión: ¿migrar todo o por partes?

**Recomendación: migrar sensor primero.**

El sensor corre en la Pi3B (1GB RAM, ARMv7) donde Python tiene más impacto. La migración es simple (sin async, sin HTTP server). Si funciona bien, continuar con el analyzer.

El analyzer tiene más valor en producción (SSE, SQLite, MQTT async) pero también más superficie de riesgo. Mantener Python mientras el sensor está probado en Rust.

---

## Comandos de referencia rápida

```bash
# Instalar toolchain y herramientas
rustup target add armv7-unknown-linux-gnueabihf aarch64-unknown-linux-gnu
cargo install cross

# Compilar sensor para Pi3B
cd sensor/rust
cross build --release --target armv7-unknown-linux-gnueabihf

# Compilar analyzer para Pi4B
cd backend/ai-analyzer/rust
cross build --release --target aarch64-unknown-linux-gnu

# Verificar tamaño
du -sh target/*/release/sensor target/*/release/ai-analyzer

# Desplegar sensor
scp target/armv7-unknown-linux-gnueabihf/release/sensor root@192.168.1.181:/opt/sensor/sensor
ssh root@192.168.1.181 "/etc/init.d/network-sensor restart"

# Desplegar analyzer (vía Docker)
cross build --release --target aarch64-unknown-linux-musl
podman build --cgroup-manager=cgroupfs --platform linux/arm64 \
  -f backend/ai-analyzer/rust/Dockerfile -t localhost/ai-analyzer:latest .
podman save localhost/ai-analyzer:latest | k3s ctr images import -
kubectl rollout restart deployment/ai-analyzer
```
