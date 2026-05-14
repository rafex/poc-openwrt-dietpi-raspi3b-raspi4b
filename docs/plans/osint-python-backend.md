# Plan: Integración OSINT en backend Python (ai-analyzer-v2)

## Contexto

El backend Python (`backend/python/ai-analyzer-v2`) tiene análisis de tráfico vía LLM pero
no consume datos OSINT. Existe un sidecar (`backend/osint/osint_enricher.py`) que hace el
trabajo, pero como proceso externo que escribe en la misma SQLite.

**Objetivo:** integrar OSINT directamente en el backend Python para que:
1. El worker llame OSINT automáticamente tras detectar riesgo HIGH/CRITICAL
2. Los datos de PHOMBER + Bing pasen al LLM (llama.cpp o Groq) para extracción JSON
3. La BD exponga los resultados vía `GET /api/osint`
4. El módulo sea testeable en aislamiento (`python3 -m app.osint`)

---

## Por qué integrar (no dejar como sidecar)

| Criterio          | Sidecar separado            | Integrado en backend              |
|-------------------|-----------------------------|-----------------------------------|
| Despliegue        | 2 servicios systemd         | 1 servicio                        |
| Latencia          | poll 30s + escritura SQLite | trigger inmediato tras análisis   |
| Visibilidad SSE   | Sin SSE propio              | Broadcast `osint_done` al frontend|
| Configuración     | Env vars duplicadas         | Reutiliza `app/config.py`         |
| Testeo            | Script externo              | `pytest` unitario                 |

---

## Arquitectura del módulo

```
AnalysisWorker
  │
  ├── risk = ALTO/CRÍTICO
  │       │
  │       └──► OsintOrchestrator.enrich_async(alert_id, ip, domain, mac)
  │                   │
  │            ┌──────┴──────────────────────────┐
  │            │                                  │
  │     PhomberRunner                        BingDorker
  │     • ip <IP>      → tablas ASCII        • ip:{IP} malware OR botnet
  │     • dns <dominio>                      • "{dominio}" threat report
  │     • whois <dominio>                    • site:abuse.ch "{dominio}"
  │     • mac <MAC>                          ↓ snippets {title, url, snippet}
  │            │
  │            └──────────────────────────────────┐
  │                                               │
  │                              OsintLLM (llama.cpp | Groq, temp=0.05)
  │                              Prompt: alerta + tablas PHOMBER + snippets Bing
  │                              Output: JSON estructurado
  │                              {risk, indicators, key_findings,
  │                               recommended_action, confidence, summary_es}
  │                                               │
  │                                      OsintStore (SQLite)
  │                                      • osint_enrichments con TTL
  │                                      • broadcast SSE "osint_done"
  │
  GET /api/osint → últimos enriquecimientos
  GET /api/osint/{id} → detalle con phomber_raw + bing_raw + llm_result
```

---

## Decisiones de diseño

### LLM como parser (no regex)

PHOMBER retorna tablas ASCII con colores ANSI. Tras strip ANSI el texto queda legible:

```
┌─────────────────────────────────────────────────┐
│  IP Information                                 │
├──────────────┬──────────────────────────────────┤
│  IP Address  │  185.220.101.47                  │
│  Country     │  Germany                         │
│  ISP         │  Tor Project                     │
│  Org         │  AS60729                         │
└──────────────┴──────────────────────────────────┘
```

El LLM (incluso TinyLlama 1.1B) lee esto perfectamente. No hace falta parser:

- **Ventaja:** si PHOMBER cambia su formato, el LLM se adapta
- **Temperatura 0.05** → extracción determinista de hechos, no creatividad

### Bing via SearchAPI.io

La Bing Web Search API fue **retirada en agosto 2025**.
SearchAPI.io actúa como proxy, acepta todos los operadores Bing en el parámetro `q`:

```
ip:185.220.101.47 malware OR botnet OR "tor exit"
"malware-domain.cc" malware OR phishing
site:abuse.ch "malware-domain.cc"
```

Configuración: `BING_API_KEY` = tu key de SearchAPI.io (100 búsquedas/mes gratis).
Sin clave → sólo PHOMBER (modo degradado, completamente funcional).

### TTL de caché por fuente

| Fuente        | TTL    | Razón                          |
|---------------|--------|-------------------------------|
| phomber-ip    | 24 h   | Geoloc/ASN cambia poco         |
| phomber-mac   | 30 d   | Vendor MAC es permanente       |
| phomber-dns   | 6 h    | DNS puede cambiar              |
| phomber-whois | 72 h   | WHOIS cambia muy poco          |
| bing-dork     | 7 d    | Reputación web cambia despacio |

### Ejecución en hilo separado

OSINT puede tomar 30-60 s (múltiples scans PHOMBER + LLM local).
Se ejecuta en un `ThreadPoolExecutor(max_workers=2)` para no bloquear el worker principal.

---

## Ficheros a crear/modificar

### Nuevos

| Fichero                                   | Qué hace                                      |
|-------------------------------------------|-----------------------------------------------|
| `app/osint.py`                            | PhomberRunner, BingDorker, OsintLLM, OsintOrchestrator |
| `app/routes/osint.py`                     | GET /api/osint, GET /api/osint/{id}           |
| `docs/plans/osint-python-backend.md`      | Este fichero                                  |

### Modificados

| Fichero                | Cambio                                              |
|------------------------|-----------------------------------------------------|
| `app/config.py`        | + `BING_API_KEY`, `BING_ENDPOINT`, `PHOMBER_TIMEOUT`, `OSINT_MIN_SEVERITY` |
| `app/database.py`      | + tabla `osint_enrichments` en schema + CRUD        |
| `app/worker.py`        | + llamada a `OsintOrchestrator` tras HIGH risk      |
| `app/main.py`          | + `include_router(osint_router)`                    |

---

## Schema de base de datos

```sql
CREATE TABLE IF NOT EXISTS osint_enrichments (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    alert_id    INTEGER,                    -- FK a network_alerts (puede ser NULL si manual)
    batch_id    INTEGER,                    -- FK a batches
    target      TEXT NOT NULL,             -- IP o dominio consultado
    target_type TEXT NOT NULL,             -- 'ip' | 'domain' | 'mac'
    source      TEXT NOT NULL,             -- 'phomber-ip' | 'bing-dork' | ...
    phomber_raw TEXT,                       -- stdout de PHOMBER (ya limpio de ANSI)
    bing_raw    TEXT,                       -- JSON de snippets Bing
    llm_result  TEXT,                       -- JSON extraído por el LLM
    risk        TEXT,                       -- BAJO | MEDIO | ALTO | CRÍTICO
    summary_es  TEXT,                       -- resumen en español del LLM
    queried_at  TEXT NOT NULL,
    expires_at  TEXT NOT NULL,
    UNIQUE(target, target_type, source)     -- upsert por target+source
);
CREATE INDEX IF NOT EXISTS idx_osint_target ON osint_enrichments(target, expires_at);
CREATE INDEX IF NOT EXISTS idx_osint_alert  ON osint_enrichments(alert_id);
CREATE INDEX IF NOT EXISTS idx_osint_batch  ON osint_enrichments(batch_id);
```

---

## API REST

### `GET /api/osint?limit=50&target=X`

```json
[
  {
    "id": 1,
    "alert_id": 42,
    "target": "185.220.101.47",
    "target_type": "ip",
    "source": "phomber-ip",
    "risk": "ALTO",
    "summary_es": "IP pertenece a nodo Tor en Alemania. Alta probabilidad de evasión.",
    "queried_at": "2026-05-13T20:00:00Z",
    "expires_at": "2026-05-14T20:00:00Z"
  }
]
```

### `GET /api/osint/{id}`

Incluye además `phomber_raw`, `bing_raw` y `llm_result` completo.

---

## Evento SSE

```json
{
  "event":      "osint_done",
  "batch_id":   15,
  "alert_id":   42,
  "target":     "185.220.101.47",
  "risk":       "ALTO",
  "summary_es": "IP pertenece a nodo Tor en Alemania...",
  "timestamp":  "2026-05-13T20:00:01Z"
}
```

---

## Pipeline de enriquecimiento (detalle)

```
1. Worker detecta risk=ALTO o risk=CRÍTICO en análisis LLM
2. Extrae indicadores del payload: IPs externas, dominios, MACs
3. Filtra LAN IPs (192.168.x.x, 10.x.x.x, etc.) → no se consultan
4. Para cada IP externa:
     a. phomber ip <IP>       → tablas ASCII → texto limpio
     b. phomber dns <IP>      → resolución inversa
     c. BingDorker.dork_ip()  → snippets reputación (si BING_API_KEY)
5. Para cada dominio sospechoso:
     a. phomber whois <domain> → registrador, fechas, país
     b. phomber dns <domain>   → registros A/MX/TXT/NS
     c. BingDorker.dork_domain() → snippets malware/phishing
6. OsintLLM.analyze(alerta, phomber_outputs, bing_snippets)
     → prompt con todo el contexto → JSON estructurado
7. OsintStore.save() → SQLite con TTL
8. broadcast_sync("osint_done", {...})
```

---

## Configuración nueva (variables de entorno)

| Variable             | Default                              | Descripción                          |
|----------------------|--------------------------------------|--------------------------------------|
| `BING_API_KEY`       | `""`                                 | Key SearchAPI.io (sin clave = sin Bing)|
| `BING_ENDPOINT`      | `https://www.searchapi.io/api/v1/search` | Endpoint SearchAPI.io            |
| `PHOMBER_TIMEOUT`    | `25`                                 | Timeout segundos por scan PHOMBER    |
| `OSINT_MIN_SEVERITY` | `HIGH`                               | Severidad mínima para enriquecer     |
| `OSINT_MAX_WORKERS`  | `2`                                  | Hilos paralelos OSINT                |

---

## Dependencias

No requiere dependencias adicionales en `requirements.txt`:
- `phomber` instalado vía `pip install phomber` en el sistema host o en el Dockerfile
- `requests` ya está en requirements

Para Dockerfile, agregar:
```dockerfile
RUN pip install phomber
```

---

## Testing manual

```bash
# 1. Enviar batch con IP TOR conocida
curl -X POST http://localhost:5000/api/ingest \
  -H "Content-Type: application/json" \
  -d '{
    "sensor_ip": "192.168.1.50",
    "packets": [{"src": "185.220.101.47", "dst": "192.168.1.100",
                 "dport": 443, "bytes": 5000}],
    "domains": [{"domain": "a4f2k.ru", "bytes": 1024}]
  }'

# 2. Esperar análisis (5-15s con Groq, 30-60s con llama.cpp)

# 3. Ver enriquecimientos OSINT generados
curl http://localhost:5000/api/osint?limit=10

# 4. Ver detalle con raw PHOMBER
curl http://localhost:5000/api/osint/1
```

---

## Checklist de implementación

- [x] `docs/plans/osint-python-backend.md` — este fichero
- [ ] `app/config.py` — agregar BING_API_KEY, PHOMBER_TIMEOUT, OSINT_MIN_SEVERITY
- [ ] `app/database.py` — agregar tabla osint_enrichments + CRUD
- [ ] `app/osint.py` — PhomberRunner, BingDorker, OsintLLM, OsintOrchestrator
- [ ] `app/routes/osint.py` — GET /api/osint, GET /api/osint/{id}
- [ ] `app/worker.py` — trigger OSINT tras HIGH risk
- [ ] `app/main.py` — registrar router OSINT
- [ ] `Dockerfile` — agregar `pip install phomber`

---

## Consideraciones de recursos (Raspberry Pi 4B)

- PHOMBER hace llamadas HTTP a APIs externas → no consume CPU de la Pi
- llama.cpp local: ~30-45 s para prompt OSINT (512 tokens entrada, 512 salida)
- Con Groq: ~2-3 s
- `OSINT_MAX_WORKERS=1` recomendado en Pi4B con llama.cpp local
- SQLite WAL: sin contención con el worker principal
- MemoryMax: PHOMBER subprocess ~30 MB, LLM llama.cpp ya corre en proceso aparte
