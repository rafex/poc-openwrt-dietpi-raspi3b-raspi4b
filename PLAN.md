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

---

---

# PLAN — Mejoras al Sensor y al Analizador IA (Python)

> Estado general: ✅ Fases 1-4 completadas — Fase 5 opcional pendiente
> Última actualización: 2026-04-24
> Implementado en sesión continua; todos los cambios en `sensor/sensor.py` y `backend/ai-analyzer/analyzer.py`

## Contexto

Tras analizar el código actual de `sensor/sensor.py` y `backend/ai-analyzer/analyzer.py` se identificaron
10 brechas concretas entre los datos que el sensor captura, lo que llega al LLM y las decisiones que
el sistema toma. Este plan las corrige por fases priorizando impacto alto y riesgo bajo.

## Brechas identificadas

| # | Archivo | Brecha | Impacto |
|---|---|---|---|
| B1 | analyzer.py | `_prompt_body()` ignora `client_domain_counts`, `dhcp_devices`, `captive_allowed`, `http_requests` | LLM no sabe qué dispositivo hace qué |
| B2 | analyzer.py | `call_llama()` usa temperatura/tokens fijos para todas las tareas | Política con temp=0.7 es no determinista; chat podría ser más creativo |
| B3 | analyzer.py | `evaluate_and_apply_social_policy()` llama LLM aunque esté fuera del horario | ~50% llamadas innecesarias |
| B4 | analyzer.py | `FEATURE_DOMAIN_CLASSIFIER_LLM=false` — dominios desconocidos siempre quedan como "otros" | Clasificación incompleta en producción |
| B5 | analyzer.py | `detect_behavior_alerts()` no correlaciona dominios DGA con `captive_allowed` | No sabe si el cliente está o no autorizado en el portal |
| B6 | analyzer.py | `infer_and_store_device_profiles()` ignora `dhcp_devices` (hostname+MAC) | Perfiles sin nombre real del dispositivo |
| B7 | sensor.py | `risky_port` se dispara para IPs internas del sistema (Raspis, router) | Falsos positivos permanentes |
| B8 | analyzer.py | `summary_worker_thread` siempre usa 6 batches (~3 min) sin importar actividad | Resúmenes automáticos muy cortos en redes activas |
| B9 | analyzer.py | `_latest_context_for_chat()` consulta 4 funciones DB en cada pregunta | Latencia en chat; sin caché |
| B10 | sensor.py + analyzer.py | `http_requests` con rutas completas se capturan pero nunca llegan al LLM | Rutas `/login`, `/admin`, `/wp-admin` ignoradas |

---

## Fase 1 — Prompt enrichment y temperatura diferenciada

> Estado: ✅ Completada

### 1.1 Enriquecer `_prompt_body()` — `analyzer.py`

- [x] Añadir top 2 entradas de `client_domain_counts` (cliente más activo + sus top 3 dominios con conteo `×N`)
- [x] Añadir conteo de `captive_allowed` (número de IPs autorizadas en el portal cautivo)
- [x] Añadir top 2 `http_requests` si existen (líneas literales `METHOD http://host/uri`)
- [x] Añadir hostname DHCP en `top_talkers` mostrando `ip(hostname)` en lugar de solo IP

**Implementado:** prompt pasa de ~120 a ~180 tokens con 3 líneas nuevas:
```
Clientes_top:192.168.1.5(laptop)→youtube.com×12,google.com×4,fbcdn.net×2; ...
Portal_autorizados:3
HTTP_req:GET http://example.com/wp-login.php; POST http://192.168.1.1/admin
```

### 1.2 Temperatura diferenciada en `call_llama()` — `analyzer.py`

- [x] `call_llama()` ya aceptaba `temperature`, `top_p`, `n_predict` — se pasaron valores específicos en cada sitio de llamada

| Tarea | `temperature` | `top_p` | Sitio |
|---|---|---|---|
| Análisis SOC (`analysis`) | 0.4 | 0.85 | `analyze_and_store()` |
| Decisión de política (`action`) | 0.1 | 0.5 | `evaluate_and_apply_social_policy()` |
| Explicación humana (`human_explain`) | 0.6 | 0.9 | `build_human_explanation()` |
| Clasificador de dominio (`domain_classifier`) | 0.05 | 0.3 | `_llm_domain_category()` (ya existía) |
| Chat interactivo (`chat`) | 0.75 | 0.95 | `_chat_answer()` |

---

## Fase 2 — Reducción de llamadas LLM innecesarias

> Estado: ✅ Completada

### 2.1 Short-circuit en `evaluate_and_apply_social_policy()` — `analyzer.py`

- [x] Si `not in_window AND not social_block_active` → retorna `noop` inmediatamente sin llamar LLM
- [x] Si `not in_window AND social_block_active` → llama `router_mcp.remove_social_block()` directamente y retorna, sin LLM
- [x] LLM solo se invoca cuando `in_window=True` (dentro de ventana 9h-17h por defecto)
- [x] Logging de debug con `"social_policy short-circuit: fuera de ventana"` para trazabilidad

**Ahorro real:** en horario 17h–9h (16 horas/día) se evitan 1–3 llamadas LLM por batch. Con batch cada 30 s → ~1920 llamadas evitadas por noche.

### 2.2 Cache en memoria de clasificación de dominios — `analyzer.py`

- [x] Añadir `_domain_cache: dict[str, tuple[dict, float]]` con TTL=300s y `_domain_cache_lock`
- [x] `classify_domain()` consulta caché en memoria → SQLite → heurística/LLM (en ese orden)
- [x] Al obtener resultado de SQLite o LLM, lo escribe en caché con `time.time() + 300`
- [x] Caché respeta el flag `refresh_cached_otros` para forzar reclasificación LLM
- **Nota:** no se invalida explícitamente al escribir; el TTL corto (5 min) es suficiente para dominios que cambian de categoría raramente

---

## Fase 3 — Mejoras al sensor

> Estado: ✅ Completada

### 3.1 Filtrar `risky_port` para IPs internas — `sensor.py`

- [ ] Definir `INTERNAL_IPS` con Sensor IP, Portal IP, Router IP
- [ ] En la detección de `risky_port`, verificar que la IP origen no esté en `INTERNAL_IPS`
- [ ] Mismo filtro para `port_scan` y `host_scan`

### 3.2 Detectar y enviar `suspicious_http_requests` — `sensor.py`

- [ ] Definir `SUSPECT_URI_PATTERNS = ["/admin", "/login", "/wp-", "/.env", "/shell", "/cmd", "/config"]`
- [ ] En `add()`, filtrar `http_uris` con estos patrones → `self.suspicious_http[]`
- [ ] En `summarize()` incluir `"suspicious_http_requests": self.suspicious_http[:10]`

### 3.3 Capturar `ip_to_mac` en el batch — `sensor.py`

- [ ] En `add()`, guardar `self.ip_to_mac[src] = eth_src` cuando `eth.src` esté presente
- [ ] En `summarize()` incluir `"ip_to_mac": dict(list(self.ip_to_mac.items())[:30])`
- [ ] Permite al analyzer correlacionar IP → MAC → hostname DHCP sin SSH adicional

---

## Fase 4 — Mejoras internas del analyzer

> Estado: ✅ Completada

### 4.1 Enriquecer device profiles con hostname DHCP — `analyzer.py`

- [ ] Añadir columna `hostname TEXT` a tabla `device_profiles` (migración segura con `ALTER TABLE IF NOT EXISTS`)
- [ ] En `infer_and_store_device_profiles()`, cruzar `client_ip` con `dhcp_devices` del batch
- [ ] Si hay hostname DHCP, añadirlo a `reasons` y guardarlo en el perfil
- [ ] Actualizar `db_upsert_device_profile()` para aceptar y guardar `hostname`

### 4.2 Cache de contexto para chat — `analyzer.py`

- [ ] Añadir `_chat_context_cache: dict` y `_chat_context_ts: float` como globales
- [ ] En `_latest_context_for_chat()`, retornar cache si `time.time() - _chat_context_ts < 30`
- [ ] Invalidar cache cuando llega un nuevo batch con alertas `severity=high`

### 4.3 Alertas correlacionadas DGA + captive status — `analyzer.py`

- [ ] En `detect_behavior_alerts()`, para cada `rare_domain`, buscar en `client_domain_counts` qué IP lo consultó
- [ ] Cruzar esa IP contra `captive_allowed` del batch
- [ ] Si la IP no está autorizada → `severity=critical`; si está autorizada → `severity=high`
- [ ] Añadir campos `source_ip` y `not_authorized` a la alerta

### 4.4 Ventana adaptativa en `summary_worker_thread` — `analyzer.py`

- [ ] Función `_adaptive_batch_limit()` que devuelve 6/12/20 según `stats["batches_received"]`
- [ ] `_generate_summary_text()` usa el límite adaptativo en lugar del hardcoded `6`

---

## Fase 5 — Nuevas capacidades (opcionales para la demo)

> Estado: ⏳ Pendiente

- [ ] **5.1** Push de alertas al portal Lentium cuando `severity=high` (HTTP interno entre pods)
- [ ] **5.2** Habilitar `FEATURE_DOMAIN_CLASSIFIER_LLM=true` con presupuesto ≤3 clasificaciones/batch y `temperature=0.05`
- [ ] **5.3** Correlacionar registros del portal Lentium (redes sociales declaradas) con perfiles de dominio del analyzer

---

## Métricas esperadas tras Fases 1–4

| Métrica | Antes | Después |
|---|---|---|
| Llamadas LLM por batch (fuera de horario) | 3 | 1 |
| Tokens al LLM en prompt de análisis | ~120 | ~180 |
| Falsos positivos `risky_port` por IPs internas | sí | no |
| Perfiles de dispositivo con hostname real | nunca | cuando DHCP disponible |
| Latencia del chat (consulta DB por pregunta) | sin caché | caché 30 s |
| Dominios DGA correlacionados con portal status | no | sí |

---

## Progreso

| Fase | Tarea | Estado |
|---|---|---|
| 1.1 | Enriquecer `_prompt_body()` | ✅ Completada |
| 1.2 | Temperatura diferenciada en `call_llama()` | ✅ Completada |
| 2.1 | Short-circuit política social | ✅ Completada |
| 2.2 | Cache clasificación dominios | ✅ Completada |
| 3.1 | Filtrar `risky_port` IPs internas | ✅ Completada |
| 3.2 | `suspicious_http_requests` en sensor | ✅ Completada |
| 3.3 | `ip_to_mac` en batch sensor | ✅ Completada |
| 4.1 | Device profiles con hostname DHCP | ✅ Completada |
| 4.2 | Cache contexto chat | ✅ Completada |
| 4.3 | Alertas DGA + captive correlacionadas | ✅ Completada |
| 4.4 | Ventana adaptativa en summary worker | ✅ Completada |
| 5.x | Capacidades opcionales demo | ⏳ Pendiente |
