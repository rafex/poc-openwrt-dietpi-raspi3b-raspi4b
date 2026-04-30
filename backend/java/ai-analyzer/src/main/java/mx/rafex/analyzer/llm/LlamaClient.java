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
import java.util.logging.Logger;

/**
 * Cliente HTTP para el servidor llama.cpp local.
 *
 * <p>Usa solo {@code java.net.http.HttpClient} — sin ninguna librería externa.
 * Equivale a la función {@code call_llama()} de {@code analyzer.py}.
 *
 * <p>Endpoints soportados:
 * <ul>
 *   <li>{@code /completion} — generación de texto (modelo tinyllama/qwen).</li>
 *   <li>{@code /health}    — verificación de disponibilidad.</li>
 * </ul>
 */
public final class LlamaClient {

    private static final Logger LOG = Logger.getLogger(LlamaClient.class.getName());

    private static final HttpClient HTTP = HttpClient.newBuilder()
        .connectTimeout(Duration.ofSeconds(5))
        .build();

    private LlamaClient() {}

    /**
     * Genera texto con llama.cpp a partir de un prompt.
     *
     * @param prompt texto de entrada
     * @param nPredict tokens máximos (0 = usar Config.N_PREDICT)
     * @param timeoutS timeout en segundos (0 = usar 30s)
     * @return texto generado, o "[Error llama: ...]" si falla
     */
    public static String complete(String prompt, int nPredict, int timeoutS) {
        int np = nPredict > 0  ? nPredict  : Config.N_PREDICT;
        int to = timeoutS > 0 ? timeoutS : 30;

        var body = """
            {"prompt":%s,"n_predict":%d,"temperature":0.3,"stream":false}
            """.formatted(Json.escape(prompt), np).strip();

        long t0 = System.currentTimeMillis();
        try {
            var req = HttpRequest.newBuilder()
                .uri(URI.create(Config.LLAMA_URL + "/completion"))
                .timeout(Duration.ofSeconds(to))
                .header("Content-Type", "application/json")
                .POST(HttpRequest.BodyPublishers.ofString(body))
                .build();

            var resp = HTTP.send(req, HttpResponse.BodyHandlers.ofString());
            long elapsed = System.currentTimeMillis() - t0;

            if (resp.statusCode() == 200) {
                var content = Json.extractString(resp.body(), "content");
                if (content != null) {
                    LOG.info("llama.cpp respondió en %dms (%d chars)".formatted(elapsed, content.length()));
                    return content.strip();
                }
                return "[Error llama: respuesta inesperada]";
            }
            LOG.warning("llama.cpp HTTP %d".formatted(resp.statusCode()));
            return "[Error llama: HTTP " + resp.statusCode() + "]";

        } catch (java.net.http.HttpTimeoutException e) {
            LOG.warning("llama.cpp timeout tras %dms".formatted(System.currentTimeMillis() - t0));
            return "[Error llama: timeout]";
        } catch (java.net.ConnectException e) {
            LOG.warning("llama.cpp connect refused: " + Config.LLAMA_URL);
            return "[Error llama: connect refused]";
        } catch (Exception e) {
            LOG.severe("llama.cpp error: " + e.getMessage());
            return "[Error llama: " + e.getMessage() + "]";
        }
    }

    /** Shortcut: nPredict y timeout de Config. */
    public static String complete(String prompt) {
        return complete(prompt, 0, 0);
    }

    /**
     * Verifica que llama.cpp está disponible.
     *
     * @return {@code true} si responde en ≤5s
     */
    public static boolean isAvailable() {
        try {
            var req = HttpRequest.newBuilder()
                .uri(URI.create(Config.LLAMA_URL + "/health"))
                .timeout(Duration.ofSeconds(5))
                .GET()
                .build();
            var resp = HTTP.send(req, HttpResponse.BodyHandlers.discarding());
            return resp.statusCode() == 200;
        } catch (Exception e) {
            return false;
        }
    }

    /**
     * Construye el prompt según el formato del modelo configurado.
     * Equivale a {@code build_prompt()} en Python.
     *
     * @param systemPrompt instrucción de sistema
     * @param userContent  contenido del usuario
     * @return prompt formateado para el modelo
     */
    public static String buildPrompt(String systemPrompt, String userContent) {
        return switch (Config.MODEL_FORMAT.toLowerCase()) {
            case "qwen" -> "<|im_start|>system\n%s<|im_end|>\n<|im_start|>user\n%s<|im_end|>\n<|im_start|>assistant\n"
                .formatted(systemPrompt, userContent);
            default ->   // tinyllama
                "<|system|>\n%s</s>\n<|user|>\n%s</s>\n<|assistant|>\n"
                .formatted(systemPrompt, userContent);
        };
    }
}
