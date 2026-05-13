# Plan: Integración OSINT en backend Java (ai-analyzer)

## Contexto

El backend Java (`backend/java/ai-analyzer`) tiene análisis LLM, anomalías, políticas sociales y perfilado de dispositivos, pero **no tiene soporte OSINT**. El backend Python ya lo implementó como módulo integrado. Este plan replica esa integración en Java, adaptada a la arquitectura Panama FFI + Rust db-lib.

---

## Diferencias con el backend Python

| Aspecto | Python | Java |
|---|---|---|
| Subprocess PHOMBER | `subprocess.Popen` | `ProcessBuilder` |
| HTTP Bing | `requests` | `java.net.http.HttpClient` |
| LLM | `_call_groq()` / `_call_llama()` | `GroqClient.chat()` / `LlamaClient.complete()` |
| SQLite | `sqlite3` directo | Rust FFI via Panama (`DbLibrary` → `DatabaseClient`) |
| Concurrencia | `ThreadPoolExecutor` | `Thread.ofVirtual()` (Project Loom) |
| ANSI strip | `re.sub` | `Pattern.compile(ANSI_RE).matcher(s).replaceAll("")` |
| Sin libs externas | ✅ solo stdlib | ✅ solo stdlib (igual) |

---

## Arquitectura del módulo Java

```
AnalysisWorker.processOne()
  │
  ├── risk = "ALTO"
  │       │
  │       └──► OsintOrchestrator.enrichAsync(batchId, alertId, ip, domain, mac)
  │                       │    [Thread.ofVirtual — Project Loom, no bloquea]
  │                       │
  │            ┌──────────┴────────────────────────────────┐
  │            │                                           │
  │     PhomberRunner                               BingDorker
  │     • ProcessBuilder("phomber")                 • HttpClient → SearchAPI.io
  │     • stdin: "ip <IP>\nexit\n"                  • ip:{IP} malware OR botnet
  │     • stdout: tablas ASCII                       • site:abuse.ch "{domain}"
  │     • strip ANSI → texto limpio                 • snippets [{title,url,snippet}]
  │            │
  │            └──────────────────────────────────────────┐
  │                                                       │
  │                                        OsintLLM (temp=0.05)
  │                                        • Groq: GroqClient.chat(messages, 0.05, 512)
  │                                        • llama.cpp: LlamaClient.complete(prompt, 512, 60)
  │                                        • prompt: alerta + PHOMBER ASCII + Bing snippets
  │                                        • El LLM lee tablas ASCII directamente
  │                                        • Extrae JSON: {risk, indicators, findings, summary_es}
  │                                                       │
  │                                           OsintOrchestrator
  │                                           • DatabaseClient.osintInsert(...)
  │                                           • ApiServer.broadcast("osint_done", {...})
  │
  GET /api/osint?limit=50&target=X
  GET /api/osint/{id}
  POST /api/osint/enrich  (manual)
```

---

## Ficheros a crear / modificar

### Nuevos ficheros Java

| Fichero | Qué hace |
|---|---|
| `osint/PhomberRunner.java` | ProcessBuilder + stdin piping, strip ANSI |
| `osint/BingDorker.java` | HttpClient → SearchAPI.io, operadores Bing |
| `osint/OsintLLM.java` | Groq temp=0.05 + llama.cpp local, buildPrompt multi-formato |
| `osint/OsintOrchestrator.java` | Pipeline completo + TTL check + persist + SSE |

### Nuevo fichero Rust

| Fichero | Qué hace |
|---|---|
| `db-lib/src/osint.rs` | CRUD SQLite: osint_insert, osint_is_cached, osint_list_recent, osint_get_detail |

### Ficheros modificados

| Fichero | Cambio |
|---|---|
| `db-lib/src/init.rs` | + tabla `osint_enrichments` + 3 índices |
| `db-lib/src/lib.rs` | + `mod osint` + `pub use osint::*` |
| `config/Config.java` | + BING_API_KEY, BING_ENDPOINT, PHOMBER_TIMEOUT, OSINT_MIN_SEVERITY, OSINT_LLM_TIMEOUT |
| `db/DbLibrary.java` | + 5 MethodHandles para funciones OSINT |
| `db/DatabaseClient.java` | + 5 métodos wrapper OSINT |
| `worker/AnalysisWorker.java` | + `triggerOsintIfNeeded()` tras risk=ALTO |
| `http/ApiServer.java` | + `GET /api/osint`, `GET /api/osint/{id}`, `POST /api/osint/enrich` |

---

## Schema SQL (añadir a init.rs)

```sql
CREATE TABLE IF NOT EXISTS osint_enrichments (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    alert_id    INTEGER,
    batch_id    INTEGER,
    target      TEXT NOT NULL,
    target_type TEXT NOT NULL,    -- 'ip' | 'domain' | 'mac'
    source      TEXT NOT NULL,    -- 'phomber-ip' | 'phomber-dns' | 'phomber-whois' | 'phomber-mac' | 'bing-dork'
    phomber_raw TEXT,             -- stdout PHOMBER sin ANSI
    bing_raw    TEXT,             -- JSON [{title,url,snippet}]
    llm_result  TEXT,             -- JSON extraído por LLM
    risk        TEXT,             -- BAJO | MEDIO | ALTO | CRÍTICO
    summary_es  TEXT,             -- resumen en español
    queried_at  TEXT NOT NULL,
    expires_at  TEXT NOT NULL,
    UNIQUE(target, target_type, source)
);
CREATE INDEX IF NOT EXISTS idx_osint_target ON osint_enrichments(target, expires_at);
CREATE INDEX IF NOT EXISTS idx_osint_alert  ON osint_enrichments(alert_id);
CREATE INDEX IF NOT EXISTS idx_osint_batch  ON osint_enrichments(batch_id);
```

---

## TTL por fuente (en OsintOrchestrator)

```java
private static final Map<String, Long> TTL_SECONDS = Map.of(
    "phomber-ip",    86400L,         // 24h
    "phomber-mac",   2592000L,       // 30d
    "phomber-dns",   21600L,         // 6h
    "phomber-whois", 259200L,        // 72h
    "bing-dork",     604800L         // 7d
);
```

---

## API REST

### `GET /api/osint?limit=50&target=X`

```json
[{
  "id": 1,
  "alert_id": 42,
  "target": "185.220.101.47",
  "target_type": "ip",
  "source": "phomber-ip",
  "risk": "ALTO",
  "summary_es": "IP nodo Tor en Alemania. Alta probabilidad evasión.",
  "queried_at": "2026-05-13T21:00:00Z",
  "expires_at":  "2026-05-14T21:00:00Z"
}]
```

### `GET /api/osint/{id}`
Incluye además `phomber_raw`, `bing_raw`, `llm_result`.

### `POST /api/osint/enrich`
Body: `{"source_ip":"X","domain":"Y","mac":"Z","batch_id":1}`
Dispara enriquecimiento en hilo virtual. Retorna 202 inmediatamente.

---

## Evento SSE

```json
{
  "event":      "osint_done",
  "batch_id":   15,
  "alert_id":   42,
  "target":     "185.220.101.47",
  "risk":       "ALTO",
  "summary_es": "IP nodo Tor en Alemania...",
  "timestamp":  "2026-05-13T21:00:01Z"
}
```

---

## Nota sobre GraalVM Native Image

Las nuevas funciones OSINT usan `ProcessBuilder` (subprocess) y `HttpClient`.
Ambos están soportados en GraalVM Native Image. Sin cambios adicionales en:
- `native-image.properties`
- `reflect-config.json`

PHOMBER corre como proceso externo — Native Image no lo compila.

---

## Testing manual

```bash
# 1. Enviar batch con IP TOR conocida + dominio DGA
curl -X POST http://localhost:5000/api/ingest \
  -H "Content-Type: application/json" \
  -d '{"sensor_ip":"192.168.1.50",
       "packets":[{"src":"185.220.101.47","dst":"192.168.1.100","dport":443,"bytes":5000}],
       "dns_queries":["a4f2k.ru","b7x3q.cc"]}'

# 2. Esperar análisis + OSINT (5-60s según LLM)

# 3. Ver enriquecimientos
curl http://localhost:5000/api/osint?limit=10

# 4. Detalle con PHOMBER raw
curl http://localhost:5000/api/osint/1

# 5. Enriquecimiento manual
curl -X POST http://localhost:5000/api/osint/enrich \
  -H "Content-Type: application/json" \
  -d '{"source_ip":"185.220.101.47","domain":"malware.cc"}'
```

---

## Checklist

- [x] `docs/plans/osint-java-backend.md` — este fichero
- [ ] `db-lib/src/init.rs` — tabla osint_enrichments
- [ ] `db-lib/src/osint.rs` — CRUD Rust
- [ ] `db-lib/src/lib.rs` — mod osint + re-export
- [ ] `config/Config.java` — vars OSINT
- [ ] `db/DbLibrary.java` — MethodHandles OSINT
- [ ] `db/DatabaseClient.java` — métodos wrapper
- [ ] `osint/PhomberRunner.java`
- [ ] `osint/BingDorker.java`
- [ ] `osint/OsintLLM.java`
- [ ] `osint/OsintOrchestrator.java`
- [ ] `worker/AnalysisWorker.java` — trigger OSINT
- [ ] `http/ApiServer.java` — endpoints /api/osint
