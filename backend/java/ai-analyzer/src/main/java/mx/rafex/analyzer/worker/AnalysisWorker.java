package mx.rafex.analyzer.worker;

/*-
 * #%L
 * AI Analyzer — Java 21 stdlib
 * %%
 * Copyright (C) 2025 - 2026 Raúl Eduardo González Argote
 * %%
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 * 
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 * 
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 * #L%
 */

import mx.rafex.analyzer.analysis.AnomalyDetector;
import mx.rafex.analyzer.osint.OsintOrchestrator;
import mx.rafex.analyzer.osint.PhomberRunner;
import mx.rafex.analyzer.analysis.DeviceProfiler;
import mx.rafex.analyzer.analysis.DomainClassifierLLM;
import mx.rafex.analyzer.analysis.HourlyPatternAnalyzer;
import mx.rafex.analyzer.config.Config;
import mx.rafex.analyzer.db.DatabaseClient;
import mx.rafex.analyzer.executor.PolicyExecutor;
import mx.rafex.analyzer.http.ApiServer;
import mx.rafex.analyzer.llm.GroqClient;
import mx.rafex.analyzer.llm.LlamaClient;
import mx.rafex.analyzer.util.Json;

import java.time.Instant;
import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.atomic.AtomicLong;
import java.util.logging.Logger;

/**
 * Worker de análisis — consume IDs de batch de la cola, llama al LLM y
 * guarda el resultado en SQLite via Rust.
 *
 * <p>Corre en un hilo virtual (Project Loom) para no bloquear el hilo del
 * servidor HTTP mientras espera al LLM.
 *
 * <p>La cola es thread-safe ({@link LinkedBlockingQueue}) — MQTT la llena,
 * el worker la vacía.
 */
public final class AnalysisWorker implements Runnable {

    private static final Logger LOG = Logger.getLogger(AnalysisWorker.class.getName());
    private static final DateTimeFormatter ISO = DateTimeFormatter.ISO_INSTANT.withZone(ZoneOffset.UTC);

    /** Máximo de IDs esperando análisis (evita que la Pi se quede sin RAM). */
    private static final int QUEUE_CAPACITY = 50;

    private final BlockingQueue<Long> queue = new LinkedBlockingQueue<>(QUEUE_CAPACITY);
    private final DatabaseClient db;
    private final PolicyExecutor policyExecutor;
    private final AnomalyDetector anomalyDetector;
    private final HourlyPatternAnalyzer hourlyAnalyzer;
    private final DomainClassifierLLM domainClassifierLLM;
    private final DeviceProfiler deviceProfiler;
    private final OsintOrchestrator osintOrchestrator;
    private volatile ApiServer apiServer;

    // Estadísticas públicas
    public final AtomicLong analysesOk    = new AtomicLong();
    public final AtomicLong analysesError = new AtomicLong();
    public final AtomicLong llamaCalls    = new AtomicLong();
    public final AtomicLong llamaErrors   = new AtomicLong();

    private volatile boolean running = true;

    public AnalysisWorker(DatabaseClient db) {
        this.db = db;
        this.policyExecutor = new PolicyExecutor(db);
        this.anomalyDetector = new AnomalyDetector();
        this.hourlyAnalyzer = new HourlyPatternAnalyzer();
        this.domainClassifierLLM = new DomainClassifierLLM(db);
        this.deviceProfiler = new DeviceProfiler(db);
        this.osintOrchestrator = new OsintOrchestrator(db);
    }

    /** Encola un batch_id para análisis asíncrono.  No bloquea. */
    public boolean enqueue(long batchId) {
        return queue.offer(batchId);
    }

    /** Establece la referencia a ApiServer para broadcast SSE. */
    public void setApiServer(ApiServer apiServer) {
        this.apiServer = apiServer;
    }

    /** Detiene el worker limpiamente. */
    public void stop() {
        running = false;
        queue.offer(-1L);  // desbloquear el take()
    }

    @Override
    public void run() {
        LOG.info("AnalysisWorker iniciado (LLM: %s)".formatted(
            Config.GROQ_CHAT_ENABLED ? "Groq/" + Config.GROQ_MODEL : "llama.cpp"));

        while (running) {
            try {
                long batchId = queue.take();
                if (batchId < 0) break;  // señal de parada

                processOne(batchId);

            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                break;
            } catch (Exception e) {
                LOG.severe("Worker error inesperado: " + e.getMessage());
            }
        }
        LOG.info("AnalysisWorker detenido");
    }

    // ─── Procesamiento individual ─────────────────────────────────────────────

    private void processOne(long batchId) {
        var payload = db.batchGetPayload(batchId);
        if (payload == null) {
            LOG.warning("batch_id=%d no tiene payload".formatted(batchId));
            return;
        }

        db.batchSetStatus(batchId, "processing");

        long t0 = System.currentTimeMillis();
        try {
            var traffic = summarizePayload(payload);
            int hour = LocalDateTime.now(ZoneOffset.UTC).getHour();

            // ★ NUEVO (Fase 2): Detección de anomalías y patrones horarios
            String deviceIp = extractDeviceIp(payload);
            double bytesPerSecond = extractBytesPerSecond(payload);

            boolean anomalyDetected = anomalyDetector.isAnomaly(deviceIp, bytesPerSecond);
            String anomalyDescription = anomalyDetector.describeAnomaly(deviceIp, bytesPerSecond);

            // Guardar anomalía en BD si fue detectada
            if (anomalyDetected) {
                try {
                    double zScore = anomalyDetector.getZScore(deviceIp, bytesPerSecond);
                    double mean = anomalyDetector.getMean(deviceIp);
                    double stdDev = anomalyDetector.getStdDev(deviceIp);
                    var ts = ISO.format(Instant.now());
                    db.anomalyInsert(batchId, deviceIp, ts, bytesPerSecond, mean, stdDev, zScore, anomalyDescription);
                    LOG.info("Anomalía registrada para " + deviceIp + ": z-score=" + String.format("%.2f", zScore));

                    // Broadcast SSE de anomalía detectada
                    if (apiServer != null) {
                        var eventData = new java.util.LinkedHashMap<String, Object>();
                        eventData.put("event", "anomaly_detected");
                        eventData.put("batch_id", batchId);
                        eventData.put("device_ip", deviceIp);
                        eventData.put("timestamp", ts);
                        eventData.put("bytes_per_sec", bytesPerSecond);
                        eventData.put("typical_bytes_per_sec", mean);
                        eventData.put("z_score", zScore);
                        eventData.put("description", anomalyDescription);
                        apiServer.broadcast(Json.obj(eventData));
                    }
                } catch (Exception e) {
                    LOG.warning("Error guardando anomalía: " + e.getMessage());
                }
            }

            hourlyAnalyzer.recordConsumption(deviceIp, hour, bytesPerSecond);
            String patternDescription = hourlyAnalyzer.describePattern(deviceIp, hour, bytesPerSecond);

            // Enriquecer el contexto para el LLM con información de anomalías
            String enrichedTraffic = traffic;
            if (anomalyDetected || !patternDescription.isEmpty()) {
                enrichedTraffic = traffic + "\n\n[ANÁLISIS DE PATRONES]\n";
                if (anomalyDetected) {
                    enrichedTraffic += "⚠️ ANOMALÍA: " + anomalyDescription + "\n";
                }
                if (!patternDescription.isEmpty()) {
                    enrichedTraffic += "📊 PATRÓN: " + patternDescription + "\n";
                }
            }

            var analysis = callLlm(enrichedTraffic);
            double elapsedS = (System.currentTimeMillis() - t0) / 1000.0;

            var risk = extractRisk(analysis);
            var ts   = ISO.format(Instant.now());

            db.analysisInsert(batchId, ts, risk, analysis, elapsedS, 0, 0, "0 B");
            db.batchSetStatus(batchId, "done");

            analysesOk.incrementAndGet();
            LOG.info("Batch %d analizado en %.1fs (riesgo: %s)".formatted(batchId, elapsedS, risk));

            // ★ NUEVO: Clasificar dominios nuevos con LLM (Fase 3)
            if (Config.FEATURE_DOMAIN_CLASSIFIER_LLM) {
                classifyNewDomainsAsync(payload);
            }

            // ★ NUEVO: Actualizar perfil del dispositivo (Fase 4)
            if (Config.FEATURE_DEVICE_PROFILING) {
                var domains = extractDomainsFromPayload(payload);
                deviceProfiler.updateProfile(deviceIp, domains);
            }

            // ★ NUEVO: Ejecutar políticas automáticas
            if (Config.FEATURE_AUTO_ENFORCE) {
                policyExecutor.executePolicy(batchId, risk, analysis, apiServer);
            }

            // ★ NUEVO: Enriquecimiento OSINT asíncrono (Fase 5)
            if (Config.FEATURE_OSINT) {
                triggerOsintIfNeeded(batchId, risk, payload);
            }

            // Human explanation si está habilitado
            if (Config.FEATURE_HUMAN_EXPLAIN) {
                generateHumanExplanation(batchId, traffic, ts);
            }

        } catch (Exception e) {
            LOG.severe("Error procesando batch %d: %s".formatted(batchId, e.getMessage()));
            db.batchSetStatus(batchId, "error");
            analysesError.incrementAndGet();
        }
    }

    // ─── LLM call ─────────────────────────────────────────────────────────────

    private String callLlm(String trafficSummary) {
        var system = Config.FEATURE_DOMAIN_CLASSIFIER ?
            """
            Eres analista SOC para red WiFi pública.
            IPs de infraestructura que NUNCA debes recomendar bloquear: %s.
            Analiza este resumen de tráfico y responde en español con:
            1) Riesgo (BAJO/MEDIO/ALTO)
            2) 2-3 hallazgos accionables
            3) Recomendación breve.
            """.formatted(Config.PROTECTED_IPS)
            :
            """
            Eres analista SOC. Responde en español: riesgo, hallazgos, recomendación.
            """;

        if (Config.GROQ_CHAT_ENABLED) {
            llamaCalls.incrementAndGet();
            var resp = GroqClient.chat(
                List.of(
                    Map.of("role", "system",  "content", system.strip()),
                    Map.of("role", "user",    "content", trafficSummary)
                ), 0.4, 512
            );
            if (resp.startsWith("[Error")) llamaErrors.incrementAndGet();
            return resp;
        }

        // Fallback a llama.cpp local
        llamaCalls.incrementAndGet();
        var prompt = LlamaClient.buildPrompt(system.strip(), trafficSummary);
        var resp = LlamaClient.complete(prompt, Config.N_PREDICT, 45);
        if (resp.startsWith("[Error")) llamaErrors.incrementAndGet();
        return resp;
    }

    private void generateHumanExplanation(long batchId, String traffic, String ts) {
        try {
            var prompt = "Resume en español para humanos la actividad de red en máximo 4 líneas.\n" +
                "Incluye: dispositivo principal, dominios dominantes, nivel de actividad y riesgo práctico.\n" +
                "Datos:\n" + traffic;
            String text;
            if (Config.GROQ_CHAT_ENABLED) {
                text = GroqClient.chatUser("Eres un asistente de red. Responde en español.", prompt);
            } else {
                text = LlamaClient.complete(LlamaClient.buildPrompt("Resume en español.", prompt), 128, 20);
            }
            db.humanExplanationInsert(batchId, ts, text, null);
        } catch (Exception e) {
            LOG.warning("Human explanation falló: " + e.getMessage());
        }
    }

    /**
     * Clasifica dominios nuevos de forma asíncrona (sin bloquear el worker).
     * Se ejecuta solo si FEATURE_DOMAIN_CLASSIFIER_LLM está habilitado.
     */
    private void classifyNewDomainsAsync(String payload) {
        try {
            var domains = extractDomainsFromPayload(payload);
            if (domains.isEmpty()) return;

            // Encontrar dominios no clasificados
            var newDomains = domains.stream()
                .filter(d -> db.domainCategoryGet(d) == null)
                .distinct()
                .limit(5)  // Max 5 por batch para no saturar LLM
                .toList();

            if (!newDomains.isEmpty()) {
                LOG.info("Clasificando %d dominios nuevos...".formatted(newDomains.size()));
                domainClassifierLLM.classifyNewDomains(newDomains);
            }
        } catch (Exception e) {
            LOG.fine("Error clasificando dominios: " + e.getMessage());
        }
    }

    /**
     * Extrae lista de dominios del payload JSON.
     * Busca campos como: domains[], domain, host, etc.
     */
    private static java.util.List<String> extractDomainsFromPayload(String payload) {
        var result = new java.util.ArrayList<String>();
        if (payload == null || payload.isEmpty()) return result;

        // Búsqueda simplista: busca "domain" en el JSON
        // En producción, se parsejaría completamente el JSON
        var lowerPayload = payload.toLowerCase();
        var parts = payload.split("[\"\\s,\\[\\]{}]");

        for (var part : parts) {
            part = part.trim();
            // Validación simple: contiene punto y no es una IP
            if (part.contains(".") &&
                !part.matches("\\d+\\.\\d+\\.\\d+\\.\\d+") &&
                part.matches("[a-z0-9.-]+")) {
                result.add(part);
            }
        }

        return result.stream().distinct().toList();
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────

    private static String summarizePayload(String payload) {
        // Usar el payload JSON tal cual como resumen de tráfico para el LLM.
        // En producción se puede parsear y construir un resumen más legible.
        return payload.length() > 2000 ? payload.substring(0, 2000) + "..." : payload;
    }

    private static String extractRisk(String analysis) {
        if (analysis == null) return "BAJO";
        var upper = analysis.toUpperCase();
        if (upper.contains("ALTO") || upper.contains("HIGH") || upper.contains("CRÍTICO")) return "ALTO";
        if (upper.contains("MEDIO") || upper.contains("MEDIUM"))                            return "MEDIO";
        return "BAJO";
    }

    private static String extractDeviceIp(String payload) {
        var sensorIp = Json.extractString(payload, "sensor_ip");
        return sensorIp != null ? sensorIp : "unknown";
    }

    private static double extractBytesPerSecond(String payload) {
        try {
            var bytesStr = Json.extractString(payload, "bytes");
            if (bytesStr != null) {
                return Double.parseDouble(bytesStr);
            }
        } catch (Exception e) {
            LOG.fine("No se pudo extraer bytes del payload: " + e.getMessage());
        }
        return 0.0;
    }

    // ─── OSINT trigger ────────────────────────────────────────────────────────

    /**
     * Dispara el enriquecimiento OSINT de forma asíncrona si el riesgo
     * supera el umbral configurado ({@code OSINT_MIN_SEVERITY}).
     *
     * <p>Extrae la primera IP externa del payload (campo {@code top_talkers}
     * o {@code source_ip}) y el primer dominio sospechoso detectado, y los
     * pasa a {@link OsintOrchestrator#enrichAsync}.
     *
     * @param batchId ID del batch procesado
     * @param risk    nivel de riesgo determinado por el LLM (BAJO/MEDIO/ALTO/CRÍTICO)
     * @param payload JSON del batch tal como llegó del sensor
     */
    private void triggerOsintIfNeeded(long batchId, String risk, String payload) {
        // Mapa de ranking de severidad
        var rankMap = Map.of("BAJO", 1, "MEDIO", 2, "ALTO", 3, "CRÍTICO", 4);
        var minRank = rankMap.getOrDefault(
            Config.OSINT_MIN_SEVERITY.toUpperCase(), 3);

        if (rankMap.getOrDefault(risk, 0) < minRank) {
            LOG.fine("OSINT omitido — riesgo %s < umbral %s".formatted(risk, Config.OSINT_MIN_SEVERITY));
            return;
        }

        // Extraer primera IP externa (no LAN) del payload
        String externalIp = null;
        var rawTalkers = Json.extractRaw(payload, "top_talkers");
        if (rawTalkers != null) {
            // Buscar IPs en el array top_talkers: primer valor no privado
            for (var part : rawTalkers.split("[\"\\s,\\[\\]{}:]")) {
                part = part.trim();
                if (part.matches("\\d+\\.\\d+\\.\\d+\\.\\d+")
                        && !PhomberRunner.isPrivateOrProtected(part)) {
                    externalIp = part;
                    break;
                }
            }
        }
        if (externalIp == null) {
            // Fallback: buscar cualquier IP pública en el payload completo
            for (var part : payload.split("[\"\\s,\\[\\]{}:]")) {
                part = part.trim();
                if (part.matches("\\d+\\.\\d+\\.\\d+\\.\\d+")
                        && !PhomberRunner.isPrivateOrProtected(part)) {
                    externalIp = part;
                    break;
                }
            }
        }

        // Extraer primer dominio sospechoso del payload
        String suspiciousDomain = null;
        var domains = extractDomainsFromPayload(payload);
        // TLDs que merecen investigación OSINT
        var riskyTlds = Set.of(".ru", ".cn", ".tk", ".pw", ".top", ".xyz",
                               ".cc", ".to", ".onion", ".biz");
        for (var domain : domains) {
            var lc = domain.toLowerCase();
            boolean isRisky = riskyTlds.stream().anyMatch(lc::endsWith);
            // Dominios con muchos subdominios (DGA heuristic: >3 partes)
            boolean isDga = lc.split("\\.").length > 3;
            if (isRisky || isDga) {
                suspiciousDomain = domain;
                break;
            }
        }
        // Si no hay dominio sospechoso pero el riesgo es ALTO/CRÍTICO,
        // tomar el primer dominio conocido para enriquecer igual
        if (suspiciousDomain == null && !domains.isEmpty()
                && rankMap.getOrDefault(risk, 0) >= 3) {
            suspiciousDomain = domains.get(0);
        }

        // Si no tenemos nada que enriquecer, salir
        if (externalIp == null && suspiciousDomain == null) {
            LOG.fine("OSINT omitido — sin IP externa ni dominio sospechoso en batch %d".formatted(batchId));
            return;
        }

        LOG.info("Disparando OSINT async batch=%d ip=%s domain=%s".formatted(
            batchId, externalIp, suspiciousDomain));

        osintOrchestrator.enrichAsync(batchId, -1L,
            externalIp, suspiciousDomain, null, apiServer);
    }
}
