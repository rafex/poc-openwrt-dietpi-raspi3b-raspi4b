package mx.rafex.analyzer.http;

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

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import mx.rafex.analyzer.config.Config;
import mx.rafex.analyzer.db.DatabaseClient;
import mx.rafex.analyzer.llm.GroqClient;
import mx.rafex.analyzer.llm.LlamaClient;
import mx.rafex.analyzer.mqtt.MqttConsumer;
import mx.rafex.analyzer.util.Json;
import mx.rafex.analyzer.worker.AnalysisWorker;

import java.io.*;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.*;
import java.util.concurrent.*;
import java.util.logging.Logger;

/**
 * Servidor HTTP basado en {@code com.sun.net.httpserver.HttpServer} (JDK built-in).
 *
 * <p>Sin ningún framework — solo stdlib de Java 21 + hilos virtuales (Loom).
 *
 * <p>Este servidor expone <strong>únicamente la API REST y el canal SSE</strong>.
 * Las páginas HTML ({@code /dashboard}, {@code /chat}, etc.) las sirve el frontend
 * Node.js compilado con Vite ({@code frontend/}), ya sea en desarrollo ({@code npm run dev})
 * o en producción (nginx en contenedor podman).
 *
 * <p>Rutas disponibles:
 * <pre>
 *   GET    /health                → estado del sistema (JSON)
 *   GET    /api/analyses          → JSON últimos análisis
 *   GET    /api/alerts            → JSON últimas alertas
 *   GET    /api/stats             → JSON estadísticas
 *   POST   /api/ingest            → insertar batch via HTTP (testing)
 *   POST   /api/chat              → chat con LLM
 *   GET    /api/chat/history      → historial de chat
 *   DELETE /api/chat/session      → limpiar sesión
 *   GET    /api/whitelist         → listar whitelist
 *   POST   /api/whitelist         → agregar dominio
 *   DELETE /api/whitelist         → eliminar dominio
 *   GET    /api/profiles          → perfiles de dispositivos
 *   GET    /api/reports           → reportes de red
 *   GET    /api/summaries         → resúmenes periódicos
 *   GET    /events                → SSE tiempo real
 *   OPTIONS *                     → CORS preflight
 * </pre>
 *
 * <p><strong>Separación de responsabilidades:</strong>
 * <ul>
 *   <li>Frontend (Node.js/Vite/nginx) → sirve HTML, CSS, JS en {@code :3000} (prod) / {@code :5173} (dev)
 *   <li>Backend Java (este servidor)  → API REST + SSE en {@code :5000}
 *   <li>nginx proxy                   → enruta {@code /api/*}, {@code /health}, {@code /events}
 *       al backend y el resto al frontend
 * </ul>
 */
public final class ApiServer {

    private static final Logger LOG = Logger.getLogger(ApiServer.class.getName());
    private static final DateTimeFormatter ISO = DateTimeFormatter.ISO_INSTANT.withZone(ZoneOffset.UTC);

    private final DatabaseClient db;
    private final AnalysisWorker worker;
    private final MqttConsumer   mqtt;

    /** Clientes SSE activos. */
    private final Set<SseClient> sseClients = ConcurrentHashMap.newKeySet();

    private final HttpServer server;

    /** Tiempo de inicio del proceso. */
    private final String startedAt = ISO.format(Instant.now());

    public ApiServer(DatabaseClient db, AnalysisWorker worker, MqttConsumer mqtt) throws IOException {
        this.db     = db;
        this.worker = worker;
        this.mqtt   = mqtt;

        server = HttpServer.create(new InetSocketAddress(Config.PORT), 128);
        // ExecutorService de hilos virtuales — Project Loom
        server.setExecutor(Executors.newVirtualThreadPerTaskExecutor());

        registerRoutes();
    }

    public void start() {
        server.start();
        LOG.info("HTTP server en http://0.0.0.0:%d".formatted(Config.PORT));
    }

    public void stop() {
        server.stop(2);
    }

    // ─── Registro de rutas ────────────────────────────────────────────────────

    private void registerRoutes() {
        // ── API REST ──────────────────────────────────────────────────────────
        // Las páginas HTML las sirve el frontend Node.js/Vite (no este servidor).
        server.createContext("/health",          this::handleHealth);
        server.createContext("/api/analyses",    this::handleAnalyses);
        server.createContext("/api/alerts",      this::handleAlerts);
        server.createContext("/api/stats",       this::handleStats);
        server.createContext("/api/ingest",      this::handleIngest);
        server.createContext("/api/chat",        this::handleChat);
        server.createContext("/api/whitelist",   this::handleWhitelist);
        server.createContext("/api/profiles",    this::handleProfiles);
        server.createContext("/api/reports",     this::handleReports);
        server.createContext("/api/summaries",   this::handleSummaries);

        // ── SSE ───────────────────────────────────────────────────────────────
        server.createContext("/events",          this::handleSse);

        // ── Raíz / catch-all ─────────────────────────────────────────────────
        // Devuelve un índice JSON de la API; el HTML lo sirve el frontend.
        server.createContext("/", ex -> {
            // CORS preflight para todas las rutas
            if ("OPTIONS".equals(ex.getRequestMethod())) {
                corsOk(ex);
                return;
            }
            var path = ex.getRequestURI().getPath();
            if ("/".equals(path)) {
                json(ex, 200, """
                    {"service":"ai-analyzer","version":"1.0.0",
                     "endpoints":["/health","/api/analyses","/api/alerts",
                     "/api/stats","/api/ingest","/api/chat","/api/whitelist",
                     "/api/profiles","/api/reports","/api/summaries","/events"],
                     "ui":"served by frontend (Node.js/Vite)"}
                    """.strip());
            } else {
                json(ex, 404, Json.error("Ruta no encontrada: " + path
                    + " — las páginas HTML las sirve el frontend en :3000"));
            }
        });
    }

    // ─── Handlers ─────────────────────────────────────────────────────────────

    private void handleHealth(HttpExchange ex) throws IOException {
        var resp = new LinkedHashMap<String, Object>();
        resp.put("status",         "ok");
        resp.put("started_at",     startedAt);
        resp.put("mqtt_connected", mqtt.isConnected());
        resp.put("groq_enabled",   Config.GROQ_CHAT_ENABLED);
        resp.put("chat_provider",  Config.GROQ_CHAT_ENABLED ? "groq" : "llama");
        resp.put("llama_url",      Config.LLAMA_URL);
        resp.put("db_path",        Config.DB_PATH);
        resp.put("batches_total",  db.batchCount());
        resp.put("analyses_total", db.analysisCount());
        resp.put("queue_pending",  db.batchCountPending());
        resp.put("analyses_ok",    worker.analysesOk.get());
        resp.put("analyses_error", worker.analysesError.get());
        json(ex, 200, Json.obj(resp));
    }

    private void handleAnalyses(HttpExchange ex) throws IOException {
        if (!"GET".equals(ex.getRequestMethod())) { json(ex, 405, Json.error("Método no permitido")); return; }
        var limit = queryParam(ex, "limit", "20");
        var data = db.analysisListRecent(Long.parseLong(limit));
        json(ex, 200, data != null ? data : "[]");
    }

    private void handleAlerts(HttpExchange ex) throws IOException {
        if (!"GET".equals(ex.getRequestMethod())) { json(ex, 405, Json.error("Método no permitido")); return; }
        var limit = queryParam(ex, "limit", "50");
        json(ex, 200, db.alertListRecent(Long.parseLong(limit)));
    }

    private void handleStats(HttpExchange ex) throws IOException {
        var resp = new LinkedHashMap<String, Object>();
        resp.put("batches_total",     db.batchCount());
        resp.put("batches_pending",   db.batchCountPending());
        resp.put("analyses_total",    db.analysisCount());
        resp.put("analyses_by_risk",  db.analysisCountByRisk());
        resp.put("alerts_by_severity",db.alertCountBySeverity());
        resp.put("analyses_ok",       worker.analysesOk.get());
        resp.put("analyses_error",    worker.analysesError.get());
        resp.put("llama_calls",       worker.llamaCalls.get());
        resp.put("llama_errors",      worker.llamaErrors.get());
        json(ex, 200, Json.obj(resp));
    }

    private void handleIngest(HttpExchange ex) throws IOException {
        if (!"POST".equals(ex.getRequestMethod())) { json(ex, 405, Json.error("Método no permitido")); return; }
        var body = new String(ex.getRequestBody().readAllBytes(), StandardCharsets.UTF_8);
        if (body.isBlank()) { json(ex, 400, Json.error("Body vacío")); return; }

        var sensorIp  = Json.extractString(body, "sensor_ip");
        var receivedAt = ISO.format(Instant.now());
        long batchId = db.batchInsert(receivedAt, sensorIp, body);
        if (batchId <= 0) { json(ex, 500, Json.error("No se pudo insertar batch")); return; }
        worker.enqueue(batchId);

        // Notificar SSE
        broadcast("{\"event\":\"batch_received\",\"batch_id\":" + batchId + "}");
        json(ex, 200, "{\"batch_id\":" + batchId + ",\"queued\":true}");
    }

    private void handleChat(HttpExchange ex) throws IOException {
        var path   = ex.getRequestURI().getPath();
        var method = ex.getRequestMethod();

        // GET /api/chat/history
        if ("GET".equals(method) && path.endsWith("/history")) {
            var sessionId = queryParam(ex, "session_id", null);
            String result;
            if (sessionId != null) {
                result = db.chatMessageHistory(sessionId, 100);
            } else {
                result = db.chatMessageListAll(50);
            }
            json(ex, 200, result != null ? result : "[]");
            return;
        }

        // DELETE /api/chat/session
        if ("DELETE".equals(method) && path.endsWith("/session")) {
            var sessionId = queryParam(ex, "session_id", null);
            if (sessionId == null) { json(ex, 400, Json.error("Falta session_id")); return; }
            db.chatSessionClear(sessionId);
            json(ex, 200, Json.ok("Sesión borrada"));
            return;
        }

        // POST /api/chat
        if ("POST".equals(method)) {
            if (!Config.FEATURE_CHAT) { json(ex, 403, Json.error("Chat deshabilitado")); return; }
            var body = new String(ex.getRequestBody().readAllBytes(), StandardCharsets.UTF_8);
            var question  = Json.extractString(body, "question");
            var sessionId = Json.extractString(body, "session_id");
            if (question == null || question.isBlank()) { json(ex, 400, Json.error("Falta question")); return; }
            if (sessionId == null) sessionId = UUID.randomUUID().toString();

            var now = ISO.format(Instant.now());
            db.chatSessionUpsert(sessionId, now);
            db.chatMessageInsert(sessionId, now, "user", question, null);

            // Llamar al LLM (en hilo virtual, pero ya estamos en uno)
            String answer;
            String provider;
            if (Config.GROQ_CHAT_ENABLED) {
                var history = db.chatMessageHistory(sessionId, 10);
                var msgs = buildChatMessages(history, question);
                answer   = GroqClient.chat(msgs, 0.7, 0);
                provider = "groq";
            } else {
                var prompt = LlamaClient.buildPrompt(
                    "Eres asistente de seguridad de red WiFi. Responde en español.",
                    question
                );
                answer   = LlamaClient.complete(prompt, Config.N_PREDICT, 30);
                provider = "llama";
            }

            db.chatMessageInsert(sessionId, ISO.format(Instant.now()), "assistant", answer,
                "{\"provider\":\"" + provider + "\"}");

            var resp = new LinkedHashMap<String, Object>();
            resp.put("session_id", sessionId);
            resp.put("answer",     answer);
            resp.put("provider",   provider);
            json(ex, 200, Json.obj(resp));
            return;
        }

        json(ex, 405, Json.error("Método no permitido"));
    }

    private void handleWhitelist(HttpExchange ex) throws IOException {
        var method = ex.getRequestMethod();
        switch (method) {
            case "GET" -> json(ex, 200, db.whitelistList());
            case "POST" -> {
                var body   = new String(ex.getRequestBody().readAllBytes(), StandardCharsets.UTF_8);
                var domain = Json.extractString(body, "domain");
                var reason = Json.extractString(body, "reason");
                if (domain == null) { json(ex, 400, Json.error("Falta domain")); return; }
                db.whitelistAdd(domain, reason, ISO.format(Instant.now()));
                json(ex, 200, Json.ok("Dominio agregado"));
            }
            case "DELETE" -> {
                var domain = queryParam(ex, "domain", null);
                if (domain == null) { json(ex, 400, Json.error("Falta domain")); return; }
                db.whitelistRemove(domain);
                json(ex, 200, Json.ok("Dominio eliminado"));
            }
            default -> json(ex, 405, Json.error("Método no permitido"));
        }
    }

    private void handleProfiles(HttpExchange ex) throws IOException {
        if (!"GET".equals(ex.getRequestMethod())) { json(ex, 405, Json.error("Método no permitido")); return; }
        json(ex, 200, db.deviceProfileList());
    }

    private void handleReports(HttpExchange ex) throws IOException {
        if (!"GET".equals(ex.getRequestMethod())) { json(ex, 405, Json.error("Método no permitido")); return; }
        json(ex, 200, db.reportListRecent(10));
    }

    private void handleSummaries(HttpExchange ex) throws IOException {
        if (!"GET".equals(ex.getRequestMethod())) { json(ex, 405, Json.error("Método no permitido")); return; }
        json(ex, 200, db.summaryListRecent(10));
    }

    // ── SSE ──────────────────────────────────────────────────────────────────

    private void handleSse(HttpExchange ex) throws IOException {
        ex.getResponseHeaders().set("Content-Type", "text/event-stream");
        ex.getResponseHeaders().set("Cache-Control", "no-cache");
        ex.getResponseHeaders().set("Connection", "keep-alive");
        ex.sendResponseHeaders(200, 0);

        var client = new SseClient(ex.getResponseBody());
        sseClients.add(client);
        LOG.fine("SSE: nuevo cliente (%d total)".formatted(sseClients.size()));

        // Enviar evento inicial de conexión
        client.send("connected", "{\"msg\":\"SSE conectado\"}");

        // El hilo virtual permanece bloqueado hasta que el cliente desconecte
        try {
            client.await();
        } finally {
            sseClients.remove(client);
            LOG.fine("SSE: cliente desconectado (%d restantes)".formatted(sseClients.size()));
        }
    }

    /** Envía un evento SSE a todos los clientes conectados. */
    public void broadcast(String data) {
        var dead = new ArrayList<SseClient>();
        for (var c : sseClients) {
            try { c.send("message", data); }
            catch (IOException e) { dead.add(c); }
        }
        sseClients.removeAll(dead);
    }

    // ── Helpers HTTP ─────────────────────────────────────────────────────────

    /**
     * Responde con JSON y cabeceras CORS para que el frontend (dev en :5173,
     * prod en :3000) pueda consumir la API desde otro origen.
     */
    private static void json(HttpExchange ex, int status, String body) throws IOException {
        var bytes = body.getBytes(StandardCharsets.UTF_8);
        var h = ex.getResponseHeaders();
        h.set("Content-Type",                 "application/json; charset=UTF-8");
        h.set("Access-Control-Allow-Origin",  "*");
        h.set("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS");
        h.set("Access-Control-Allow-Headers", "Content-Type, Authorization");
        ex.sendResponseHeaders(status, bytes.length);
        try (var out = ex.getResponseBody()) { out.write(bytes); }
    }

    /** Responde 204 a peticiones CORS preflight (OPTIONS). */
    private static void corsOk(HttpExchange ex) throws IOException {
        var h = ex.getResponseHeaders();
        h.set("Access-Control-Allow-Origin",  "*");
        h.set("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS");
        h.set("Access-Control-Allow-Headers", "Content-Type, Authorization");
        h.set("Access-Control-Max-Age",       "86400");
        ex.sendResponseHeaders(204, -1);
        ex.getResponseBody().close();
    }

    private static String queryParam(HttpExchange ex, String key, String def) {
        var query = ex.getRequestURI().getQuery();
        if (query == null) return def;
        for (var part : query.split("&")) {
            var kv = part.split("=", 2);
            if (kv.length == 2 && kv[0].equals(key)) return kv[1];
        }
        return def;
    }

    /** Reconstruye la lista de mensajes para el contexto del chat a partir del historial JSON. */
    private static List<Map<String, String>> buildChatMessages(String historyJson, String latestQuestion) {
        var msgs = new ArrayList<Map<String, String>>();
        msgs.add(Map.of("role", "system", "content",
            "Eres TARS, asistente de seguridad de red WiFi. Responde en español."));

        // Parseo simplificado: el historial es un JSON array de objetos
        // Suficiente para recuperar role + content de cada mensaje
        if (historyJson != null && !historyJson.equals("[]")) {
            var arr = historyJson.strip();
            int i = 1; // saltar '['
            while (i < arr.length() - 1) {
                int start = arr.indexOf('{', i);
                if (start < 0) break;
                int end = findClose(arr, start, '{', '}');
                if (end < 0) break;
                var obj = arr.substring(start, end + 1);
                var role    = Json.extractString(obj, "role");
                var content = Json.extractString(obj, "content");
                if (role != null && content != null) {
                    msgs.add(Map.of("role", role, "content", content));
                }
                i = end + 1;
            }
        }
        // El mensaje del usuario ya está en el historial (lo insertamos antes de llamar aquí)
        return msgs;
    }

    private static int findClose(String s, int open, char openC, char closeC) {
        int depth = 0;
        for (int i = open; i < s.length(); i++) {
            if (s.charAt(i) == openC)  depth++;
            if (s.charAt(i) == closeC) { depth--; if (depth == 0) return i; }
        }
        return -1;
    }

    // ── SSE client ────────────────────────────────────────────────────────────

    private static final class SseClient {
        private final OutputStream out;
        private final CountDownLatch latch = new CountDownLatch(1);

        SseClient(OutputStream out) { this.out = out; }

        void send(String event, String data) throws IOException {
            var msg = "event: %s\ndata: %s\n\n".formatted(event, data);
            out.write(msg.getBytes(StandardCharsets.UTF_8));
            out.flush();
        }

        void await() {
            try { latch.await(); }
            catch (InterruptedException e) { Thread.currentThread().interrupt(); }
        }

        void disconnect() { latch.countDown(); }
    }
}
