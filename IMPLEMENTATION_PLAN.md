# Plan: Sistema de IA Interactivo con Acciones de Red y Dashboard en Tiempo Real

**Fecha de creación:** Mayo 12, 2026  
**Estado:** En Implementación - Fase 2  
**Realismo POC:** ✅ Fase 1 (70%) → 🔄 Fase 2 (85%) → Fase 3 (95%) → Fase 4 (99%)

---

## 📋 CONTEXTO

**Problema:** El AI Analyzer actual genera análisis y alertas, pero no las convierte en acciones de red. Las recomendaciones del LLM no se ejecutan automáticamente. El dashboard muestra datos pasivos sin visibilidad de qué acciones se están realizando.

**Objetivo:** Implementar un sistema donde:
1. La IA analiza datos de red y **toma decisiones** automáticas
2. Esas decisiones se **ejecutan en el router** (bloqueos, restricciones)
3. Un **dashboard en tiempo real** muestra cada decisión y su ejecución
4. Todo está auditado y se puede revertir manualmente

**Alcance:** Fases 1-3 implementan funcionalidad realista de POC con acciones reales de red.

---

## 🎯 OBJETIVOS POR FASE

| Fase | Funcionalidades | Realismo | Tiempo Est. | Estado |
|------|-----------------|----------|------------|--------|
| **1** | F2 (Alertas) + F5 (Bloqueo Social) | 70% | 2-3 días | ✅ Completada |
| **2** | F3 (Patrones) + F1 (Anomalías) | 85% | 3-4 días | 🟡 En progreso |
| **3** | F4 (Clasificación LLM) + Dashboard | 95% | 2-3 días | ⚪ Pendiente |
| **4** | F6 (Device Profiling) + Predicción | 99% | 4-5 días | ⚪ Pendiente |

---

## 📐 ARQUITECTURA FINAL

```
SENSOR (PCAP + JSON)
  ↓
MQTT (/rafexpi/sensor/batch, /rafexpi/sensor01/pcap/*)
  ↓
┌──────────────────────────────────────────┐
│ MqttConsumer                              │
│ • Recibe JSON + PCAP                      │
│ • Encoloca en AnalysisWorker              │
└────────────────┬─────────────────────────┘
                 │
┌────────────────▼─────────────────────────┐
│ AnalysisWorker (Virtual Thread)           │
│ • Análisis LLM del tráfico                │
│ • Extrae: dominio, protocolo, riesgo     │
│ • Evaluá REGLAS de política               │ ← F2, F5
│ • Genera ALERTAS                          │
│ • Detecta ANOMALÍAS                       │ ← F1
│ • Clasifica DOMINIOS NUEVOS               │ ← F4
│ • Guarda contexto para dashboard          │
└────────────────┬─────────────────────────┘
                 │
        ┌────────┴─────────┐
        │                  │
    SQLite            Router (SSH)
    • analyses        • nftables
    • alerts          • bloqueos
    • actions         • restrictions
    • pcap_evidence   
        │                  │
        └────────┬─────────┘
                 │
        ┌────────▼─────────────┐
        │ Action Executor       │ ← NEW
        │ (PolicyExecutor.java) │
        │ • Toma decisiones     │
        │ • Ejecuta bloqueos    │
        │ • Registra acciones   │
        │ • Broadcast SSE       │
        └────────┬─────────────┘
                 │
        ┌────────▼──────────────┐
        │ Frontend Dashboard    │
        │ • Análisis en vivo    │
        │ • Alertas + Acciones  │
        │ • Historial de IPs    │
        │ • Top dominios        │
        │ • Decisiones del LLM  │
        └───────────────────────┘
```

---

## 🔧 FASE 1: ALERTAS AUTOMÁTICAS + BLOQUEO SOCIAL (F2 + F5)

**Duración:** 2-3 días  
**Realismo:** 70%  
**Status:** 🟡 En progreso

### 1.1 Implementar PolicyExecutor.java

**Archivo:** `backend/java/ai-analyzer/src/main/java/mx/rafex/analyzer/executor/PolicyExecutor.java`

**Responsabilidades:**
```java
public class PolicyExecutor {
    // Ejecuta decisión de bloqueo/alerta
    public void executePolicy(long batchId, String risk, String analysis);
    
    // Regla: si social_media detectado Y fuera de horario → bloquear
    private boolean shouldBlockSocial(String domain, int hour);
    
    // SSH al router: agrega IP a set nftables
    private void executeBlockCommand(String targetIp, String reason);
    
    // Registra acción en policy_actions table
    private void recordAction(long batchId, String action, String details);
}
```

**Lógica:**
```
IF análisis_contiene("instagram") OR análisis_contiene("tiktok") 
   AND hora > 17 OR hora < 9
THEN
   resolveDomainsToIps([instagram, tiktok])
   ejecutar: nft add element ip captive blocked_social_ips { $IPs }
   registrar: policy_actions INSERT ("social_policy_block", "...")
   broadcast: SSE { event: "action_executed", action: "social_block", ... }
```

### 1.2 Integración con AnalysisWorker

**Modificar:** `AnalysisWorker.java` línea ~130

**Agregar después de análisis LLM:**
```java
// Después de: var analysis = callLlm(traffic);

// ★ NUEVO: Ejecutar políticas automáticas
if (Config.FEATURE_AUTO_ENFORCE) {  // Feature flag nuevo
    policyExecutor.executePolicy(batchId, risk, analysis);
}
```

### 1.3 Config variables nuevas

**Archivo:** `Config.java` línea ~115

```java
// ── Ejecución automática de políticas ──────────────────────────────────
public static final boolean FEATURE_AUTO_ENFORCE           = boolEnv("FEATURE_AUTO_ENFORCE",           true);
public static final boolean FEATURE_AUTO_ENFORCE_SSH       = boolEnv("FEATURE_AUTO_ENFORCE_SSH",       true);
public static final int     POLICY_ACTION_TIMEOUT_S        = intEnv("POLICY_ACTION_TIMEOUT_S",         10);
public static final String  POLICY_LOG_PATH                = env("POLICY_LOG_PATH",                   "/var/log/ai-analyzer");
```

### 1.4 Database: extender network_alerts

**Archivo:** `db-lib/src/init.rs` (función apply_schema)

**Agregar columna:**
```sql
ALTER TABLE network_alerts ADD COLUMN action_taken TEXT DEFAULT 'none';
-- Valores: "none", "social_block", "porn_block", "kick_client", "warning"

ALTER TABLE network_alerts ADD COLUMN action_details JSON;
-- { "target_ips": [...], "nft_set": "...", "ssh_return_code": 0, "ssh_stderr": "" }
```

### 1.5 SSE: eventos de acciones

**Archivo:** `ApiServer.java` broadcastAction()

```java
private void broadcastAction(long batchId, String action, String details) {
    broadcast("{" +
        "\"event\":\"action_executed\"," +
        "\"batch_id\":" + batchId + "," +
        "\"action\":\"" + action + "\"," +
        "\"details\":" + details + "," +
        "\"timestamp\":\"" + ISO.format(Instant.now()) + "\"" +
    "}");
}
```

### 1.6 Endpoint nuevo (leer acciones)

**Endpoint:** `GET /api/actions?limit=50`

**Implementación en ApiServer.java:**
```java
private void handleActions(HttpExchange ex) throws IOException {
    var limit = queryParam(ex, "limit", "50");
    var data = db.policyActionListRecent(Long.parseLong(limit));
    json(ex, 200, data != null ? data : "[]");
}
```

### 1.7 Testing

**Cómo validar:**
1. Enviar batch con dominio "instagram.com" a las 20:00
2. Verificar que se crea alerta con severity HIGH
3. Verificar que se ejecuta `nft add element` en el router
4. Verificar que se registra en `policy_actions` con status "success"
5. Verificar que SSE emite evento "action_executed"

### 1.8 Checklist de implementación

- [x] PolicyExecutor.java creado
- [x] AnalysisWorker integrado con PolicyExecutor
- [x] Config variables nuevas (FEATURE_AUTO_ENFORCE, etc)
- [x] network_alerts extendido con action_taken
- [x] Endpoint GET /api/actions implementado
- [x] SSE broadcast de acciones
- [x] Test: Bloqueo social automático

---

## 📊 FASE 2: DETECCIÓN DE ANOMALÍAS + PATRONES (F1 + F3)

**Duración:** 3-4 días  
**Realismo:** 85%  
**Status:** ⚪ Pendiente

### 2.1 AnomalyDetector.java

**Archivo:** `backend/java/ai-analyzer/src/main/java/mx/rafex/analyzer/analysis/AnomalyDetector.java`

**Algoritmo: Desviación estándar simple**

```java
public class AnomalyDetector {
    // Almacena histórico de últimas 24h
    private Map<String, Deque<Double>> byteHistoryByDevice = new ConcurrentHashMap<>();
    
    public boolean isAnomaly(String deviceIp, double bytesPerSecond) {
        var history = byteHistoryByDevice.computeIfAbsent(deviceIp, 
            k -> new LinkedList<>());
        
        history.addLast(bytesPerSecond);
        if (history.size() > 1440) history.removeFirst();  // 24h @ 1 min granularity
        
        if (history.size() < 10) return false;  // Necesita histórico
        
        double mean = history.stream().mapToDouble(Double::doubleValue).average().orElse(0);
        double variance = history.stream()
            .mapToDouble(d -> Math.pow(d - mean, 2))
            .average().orElse(0);
        double stdDev = Math.sqrt(variance);
        
        // Detecta si está fuera de 2σ
        return Math.abs(bytesPerSecond - mean) > 2 * stdDev;
    }
}
```

### 2.2 Checklist de implementación

- [ ] AnomalyDetector.java creado
- [ ] HourlyPatternAnalyzer.java creado
- [ ] AnalysisWorker integrado con detectores
- [ ] Tablas BD: hourly_patterns, anomalies_detected
- [ ] Test: Detección de anomalía

---

## 💬 FASE 3: CLASIFICACIÓN LLM DE DOMINIOS + DASHBOARD MEJORADO (F4 + Dashboard)

**Duración:** 2-3 días  
**Realismo:** 95%  
**Status:** ⚪ Pendiente

### 3.1 DomainClassifierLLM.java

**Archivo:** `backend/java/ai-analyzer/src/main/java/mx/rafex/analyzer/analysis/DomainClassifierLLM.java`

### 3.2 Dashboard mejorado: nueva página

**Archivo:** `frontend/src/pug/pages/actions.pug` (NEW)

### 3.3 Checklist de implementación

- [ ] DomainClassifierLLM.java creado
- [ ] Página /actions.pug creada
- [ ] Módulo actions.ts creado
- [ ] Endpoint GET /api/actions integrado con BD
- [ ] SSE conectado a página /actions
- [ ] Test: Dashboard en tiempo real

---

## 🏗️ FASE 4: DEVICE PROFILING + PREDICCIÓN (F6)

**Duración:** 4-5 días  
**Realismo:** 99%  
**Status:** ⚪ Pendiente

### 4.1 DeviceProfiler.java

**Detecta:** Celular vs Computadora, patrones de uso, categorías típicas

### 4.2 BehaviorPredictor.java

**Predice:** Comportamiento futuro basado en histórico

### 4.3 Checklist de implementación

- [ ] DeviceProfiler.java creado
- [ ] BehaviorPredictor.java creado
- [ ] Tablas BD: device_profiles, behavior_predictions
- [ ] Visualizaciones en dashboard

---

## 🔑 ARCHIVOS CRÍTICOS A MODIFICAR

1. `backend/java/ai-analyzer/src/main/java/mx/rafex/analyzer/worker/AnalysisWorker.java`
2. `backend/java/ai-analyzer/src/main/java/mx/rafex/analyzer/config/Config.java`
3. `backend/java/ai-analyzer/src/main/java/mx/rafex/analyzer/http/ApiServer.java`
4. `backend/java/ai-analyzer/db-lib/src/init.rs`
5. `frontend/src/pug/pages/actions.pug` (NEW)
6. `frontend/src/ts/actions.ts` (NEW)

---

## ⏱️ TIMELINE REALISTA

| Fecha | Hito | Status |
|-------|------|--------|
| Día 1-2 | Fase 1: PolicyExecutor + bloqueo social | ✅ Completada |
| Día 3-5 | Fase 2: Anomalías + patrones | 🟡 En progreso |
| Día 6-7 | Fase 3: Dashboard + clasificación LLM | ⚪ Pendiente |
| Día 8-12 | Fase 4: Device profiling + predicción | ⚪ Pendiente |
| Día 13 | Testing + documentación | ⚪ Pendiente |

**Total:** ~2 semanas para MVP realista al 95%

---

## 📈 VERIFICACIÓN END-TO-END

### Test Fase 1: Bloqueo Social Automático

```bash
# 1. Enviar batch a las 20:00 con tráfico a instagram.com
curl -X POST http://localhost:5000/api/ingest \
  -H "Content-Type: application/json" \
  -d '{
    "sensor_ip": "192.168.1.50",
    "domains": [{"domain": "instagram.com", "bytes": 5000000}]
  }'

# 2. Verificar alerta
curl http://localhost:5000/api/alerts?limit=5

# 3. Verificar acción ejecutada
curl http://localhost:5000/api/actions?limit=5

# 4. En router: verificar nftables
ssh root@192.168.1.1 "nft list set ip captive blocked_social_ips"
```

---

## 📝 NOTAS IMPORTANTES

- SSH al router **ya está configurado** en Config.java
- nftables scripts **ya existen** en `/scripts`
- MQTT y LLM **ya funcionales**
- SSE **ya implementado** en ApiServer
- Frontend **Vite + TypeScript** disponible

---

## 🚀 PROXIMOS PASOS

1. ✅ Plan escrito en el repositorio
2. ⏭️ **Iniciar Fase 1: PolicyExecutor + Bloqueo Social**
3. Integración con AnalysisWorker
4. Database schema updates
5. Testing y validación

