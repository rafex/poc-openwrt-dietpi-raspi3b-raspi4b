package mx.rafex.analyzer.llm;

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
import mx.rafex.analyzer.util.Json;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.List;
import java.util.Map;
import java.util.logging.Logger;

/**
 * Cliente HTTP para la API de Groq (compatible con OpenAI).
 *
 * <p>Usa solo {@code java.net.http.HttpClient} — sin ninguna librería externa.
 * Si {@code GROQ_API_KEY} está vacío, todas las llamadas devuelven un mensaje
 * de error descriptivo sin lanzar excepción.
 */
public final class GroqClient {

    private static final Logger LOG = Logger.getLogger(GroqClient.class.getName());

    private static final HttpClient HTTP = HttpClient.newBuilder()
        .connectTimeout(Duration.ofSeconds(10))
        .build();

    private GroqClient() {}

    /**
     * Envía una lista de mensajes al modelo Groq configurado y devuelve el texto de respuesta.
     *
     * @param messages lista de {@code Map} con claves "role" y "content"
     * @param temperature temperatura de muestreo 0-1
     * @param maxTokens tokens máximos (0 = usar el valor de Config)
     * @return texto de respuesta, o un string "[Error ...]" si falla
     */
    public static String chat(List<Map<String, String>> messages, double temperature, int maxTokens) {
        if (!Config.GROQ_CHAT_ENABLED) {
            return "[Error: GROQ_API_KEY no configurado]";
        }
        int tokens = maxTokens > 0 ? maxTokens : Config.GROQ_MAX_TOKENS;

        // Construir array de messages JSON manualmente (sin librería)
        var msgArr = new StringBuilder("[");
        for (int i = 0; i < messages.size(); i++) {
            var m = messages.get(i);
            if (i > 0) msgArr.append(',');
            msgArr.append("{\"role\":").append(Json.escape(m.get("role")))
                  .append(",\"content\":").append(Json.escape(m.get("content")))
                  .append('}');
        }
        msgArr.append(']');

        var body = """
            {"model":%s,"messages":%s,"temperature":%s,"max_tokens":%d,"stream":false}
            """.formatted(
                Json.escape(Config.GROQ_MODEL),
                msgArr,
                temperature,
                tokens
            ).strip();

        long t0 = System.currentTimeMillis();
        try {
            var req = HttpRequest.newBuilder()
                .uri(URI.create(Config.GROQ_API_URL))
                .timeout(Duration.ofSeconds(Config.GROQ_TIMEOUT_S))
                .header("Authorization", "Bearer " + Config.GROQ_API_KEY)
                .header("Content-Type", "application/json")
                .POST(HttpRequest.BodyPublishers.ofString(body))
                .build();

            var resp = HTTP.send(req, HttpResponse.BodyHandlers.ofString());
            long elapsed = System.currentTimeMillis() - t0;

            if (resp.statusCode() == 200) {
                var responseBody = resp.body();
                // Extraer choices[0].message.content sin librería JSON
                var choicesRaw = Json.extractRaw(responseBody, "choices");
                if (choicesRaw != null && choicesRaw.startsWith("[")) {
                    // primer elemento del array
                    int start = choicesRaw.indexOf('{');
                    int end   = findMatchingBrace(choicesRaw, start);
                    if (start >= 0 && end > start) {
                        var firstChoice = choicesRaw.substring(start, end + 1);
                        var messageRaw  = Json.extractRaw(firstChoice, "message");
                        if (messageRaw != null) {
                            var content = Json.extractString(messageRaw, "content");
                            if (content != null) {
                                LOG.info("Groq (%s) respondió en %dms (%d chars)"
                                    .formatted(Config.GROQ_MODEL, elapsed, content.length()));
                                return content;
                            }
                        }
                    }
                }
                LOG.warning("Groq: respuesta no parseable: " + responseBody.substring(0, Math.min(200, responseBody.length())));
                return "[Error Groq: respuesta inesperada]";
            }

            LOG.warning("Groq HTTP %d: %s".formatted(resp.statusCode(),
                resp.body().substring(0, Math.min(200, resp.body().length()))));
            return "[Error Groq: HTTP " + resp.statusCode() + "]";

        } catch (java.net.http.HttpTimeoutException e) {
            LOG.warning("Groq timeout tras %dms".formatted(System.currentTimeMillis() - t0));
            return "[Error Groq: timeout]";
        } catch (Exception e) {
            LOG.severe("Groq error: " + e.getMessage());
            return "[Error Groq: " + e.getMessage() + "]";
        }
    }

    /** Shortcut: un único mensaje de usuario. */
    public static String chatUser(String systemPrompt, String userMessage) {
        return chat(List.of(
            Map.of("role", "system",  "content", systemPrompt),
            Map.of("role", "user",    "content", userMessage)
        ), 0.7, 0);
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    /** Encuentra el índice del cierre '}' que corresponde a '{' en pos. */
    private static int findMatchingBrace(String s, int open) {
        int depth = 0;
        for (int i = open; i < s.length(); i++) {
            if (s.charAt(i) == '{') depth++;
            if (s.charAt(i) == '}') { depth--; if (depth == 0) return i; }
        }
        return -1;
    }
}
