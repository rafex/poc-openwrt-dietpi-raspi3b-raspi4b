package mx.rafex.analyzer;

import mx.rafex.analyzer.config.Config;
import mx.rafex.analyzer.db.DatabaseClient;
import mx.rafex.analyzer.http.ApiServer;
import mx.rafex.analyzer.mqtt.MqttConsumer;
import mx.rafex.analyzer.worker.AnalysisWorker;

import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.logging.Level;
import java.util.logging.Logger;

/**
 * Punto de entrada de ai-analyzer — Java 21, stdlib puro.
 *
 * <p>Arranque:
 * <ol>
 *   <li>Abre SQLite via Rust (Panama FFI).</li>
 *   <li>Inicia el worker de análisis LLM en un hilo virtual.</li>
 *   <li>Conecta al broker MQTT.</li>
 *   <li>Levanta el servidor HTTP en el puerto {@code PORT} (default 5000).</li>
 *   <li>Programa el resumen periódico de red.</li>
 * </ol>
 *
 * <p>Todas las piezas usan solo {@code java.* / com.sun.net.*} excepto
 * la librería MQTT (Eclipse Paho) y el binding Rust (Panama FFI).
 */
public final class Main {

    private static final Logger LOG = Logger.getLogger(Main.class.getName());

    public static void main(String[] args) throws Exception {
        configureLogging();

        LOG.info("=== AI Analyzer — Java 21 (stdlib) ===");
        LOG.info("Puerto    : " + Config.PORT);
        LOG.info("DB        : " + Config.DB_PATH);
        LOG.info("MQTT      : " + Config.MQTT_HOST + ":" + Config.MQTT_PORT);
        LOG.info("LLM       : " + (Config.GROQ_CHAT_ENABLED
            ? "Groq/" + Config.GROQ_MODEL
            : "llama.cpp " + Config.LLAMA_URL));

        // 1. Base de datos (Rust via Panama FFI)
        var db = DatabaseClient.open(Config.DB_PATH);
        LOG.info("SQLite OK");

        // 2. Worker de análisis en hilo virtual
        var worker = new AnalysisWorker(db);
        Thread.ofVirtual().name("analysis-worker").start(worker);
        LOG.info("AnalysisWorker iniciado");

        // 3. Servidor HTTP
        var mqtt   = new MqttConsumer(db, worker);  // necesario antes de ApiServer para pasarlo
        var server = new ApiServer(db, worker, mqtt);
        server.start();

        // 4. MQTT (no crítico si falla — HTTP ingest sigue funcionando)
        mqtt.start();

        // 5. Resumen periódico de red
        if (Config.FEATURE_AUTO_REPORTS && Config.SUMMARY_INTERVAL_S > 0) {
            startSummaryScheduler(db);
        }

        // 6. Shutdown hook limpio
        Runtime.getRuntime().addShutdownHook(Thread.ofVirtual().unstarted(() -> {
            LOG.info("Apagando...");
            worker.stop();
            mqtt.stop();
            server.stop();
            db.close();
            LOG.info("Bye.");
        }));

        LOG.info("=== Servidor listo en http://0.0.0.0:" + Config.PORT + " ===");

        // Mantener el hilo principal vivo
        Thread.currentThread().join();
    }

    // ── Resumen periódico ────────────────────────────────────────────────────

    private static void startSummaryScheduler(DatabaseClient db) {
        ScheduledExecutorService sched = Executors.newSingleThreadScheduledExecutor(r ->
            Thread.ofVirtual().name("summary-scheduler").unstarted(r));

        sched.scheduleAtFixedRate(() -> {
            try {
                generateSummary(db);
            } catch (Exception e) {
                LOG.warning("Error generando resumen: " + e.getMessage());
            }
        }, Config.SUMMARY_INTERVAL_S, Config.SUMMARY_INTERVAL_S, TimeUnit.SECONDS);

        LOG.info("Resumen automático cada %ds".formatted(Config.SUMMARY_INTERVAL_S));
    }

    private static void generateSummary(DatabaseClient db) {
        var recent = db.analysisListRecent(5);
        if (recent == null || recent.equals("[]")) return;

        var prompt = "Resume en 3 frases el estado de la red WiFi en el último período:\n" + recent;
        String summary;
        if (Config.GROQ_CHAT_ENABLED) {
            summary = mx.rafex.analyzer.llm.GroqClient.chatUser(
                "Eres analista de red. Responde en español, máximo 3 frases.",
                prompt
            );
        } else {
            summary = mx.rafex.analyzer.llm.LlamaClient.complete(
                mx.rafex.analyzer.llm.LlamaClient.buildPrompt(
                    "Resume el estado de la red.", prompt),
                128, 20
            );
        }

        var now = java.time.format.DateTimeFormatter.ISO_INSTANT
            .withZone(java.time.ZoneOffset.UTC)
            .format(java.time.Instant.now());
        db.summaryInsert(now, summary, null);
        LOG.fine("Resumen periódico guardado");
    }

    // ── Logging ──────────────────────────────────────────────────────────────

    private static void configureLogging() {
        var level = switch (Config.LOG_LEVEL.toUpperCase()) {
            case "DEBUG"   -> Level.FINE;
            case "WARNING" -> Level.WARNING;
            case "ERROR"   -> Level.SEVERE;
            default        -> Level.INFO;
        };
        var rootLogger = Logger.getLogger("");
        rootLogger.setLevel(level);
        for (var h : rootLogger.getHandlers()) h.setLevel(level);
    }
}
