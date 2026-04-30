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

import mx.rafex.analyzer.config.Config;
import mx.rafex.analyzer.db.DatabaseClient;
import mx.rafex.analyzer.llm.GroqClient;
import mx.rafex.analyzer.llm.LlamaClient;
import mx.rafex.analyzer.util.Json;

import java.time.Instant;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.List;
import java.util.Map;
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

    // Estadísticas públicas
    public final AtomicLong analysesOk    = new AtomicLong();
    public final AtomicLong analysesError = new AtomicLong();
    public final AtomicLong llamaCalls    = new AtomicLong();
    public final AtomicLong llamaErrors   = new AtomicLong();

    private volatile boolean running = true;

    public AnalysisWorker(DatabaseClient db) {
        this.db = db;
    }

    /** Encola un batch_id para análisis asíncrono.  No bloquea. */
    public boolean enqueue(long batchId) {
        return queue.offer(batchId);
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
            var analysis = callLlm(traffic);
            double elapsedS = (System.currentTimeMillis() - t0) / 1000.0;

            var risk = extractRisk(analysis);
            var ts   = ISO.format(Instant.now());

            db.analysisInsert(batchId, ts, risk, analysis, elapsedS, 0, 0, "0 B");
            db.batchSetStatus(batchId, "done");

            analysesOk.incrementAndGet();
            LOG.info("Batch %d analizado en %.1fs (riesgo: %s)".formatted(batchId, elapsedS, risk));

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
}
