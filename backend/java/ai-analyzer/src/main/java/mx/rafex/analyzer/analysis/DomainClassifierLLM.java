package mx.rafex.analyzer.analysis;

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

import java.time.Instant;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.logging.Logger;

/**
 * Clasificador LLM de dominios nuevos.
 *
 * <p>Cuando el AnalysisWorker encuentra dominios desconocidos, los envía en batch
 * a esta clase para clasificarlos en categorías (social, video, porn, cdn, etc).
 *
 * <p>Las clasificaciones se guardan en {@code domain_categories} para futuras
 * referencias y para enriquecer el análisis LLM con contexto de dominio.
 */
public final class DomainClassifierLLM {

    private static final Logger LOG = Logger.getLogger(DomainClassifierLLM.class.getName());
    private static final DateTimeFormatter ISO = DateTimeFormatter.ISO_INSTANT.withZone(ZoneOffset.UTC);

    private final DatabaseClient db;

    public DomainClassifierLLM(DatabaseClient db) {
        this.db = db;
    }

    // ── Clasificación de dominios nuevos ───────────────────────────────────

    /**
     * Clasifica una lista de dominios desconocidos usando LLM.
     *
     * <p>Construye un prompt en español pidiendo clasificación en categorías:
     * social, video, cdn, porn, search, shopping, news, business, other.
     *
     * <p>Guarda cada clasificación en {@code domain_categories} con confidence 0.8
     * y source "llm".
     *
     * @param newDomains lista de dominios sin clasificar
     * @return map de dominio → categoría, o vacío si error
     */
    public Map<String, String> classifyNewDomains(List<String> newDomains) {
        if (newDomains == null || newDomains.isEmpty()) {
            return new HashMap<>();
        }

        var classifications = new HashMap<String, String>();

        try {
            var prompt = buildClassificationPrompt(newDomains);
            String result = callLlmForClassification(prompt);

            // Parsear respuesta: "dominio.com:categoría\ndominio2.com:otra_categoría"
            var parsed = parseClassificationResponse(result);

            // Guardar en BD
            for (var entry : parsed.entrySet()) {
                var domain = entry.getKey();
                var category = entry.getValue();
                var now = ISO.format(Instant.now());

                db.domainCategoryUpsert(domain, category, 0.8, "llm", now);
                classifications.put(domain, category);

                LOG.info("Clasificado: " + domain + " → " + category + " (LLM)");
            }

        } catch (Exception e) {
            LOG.warning("Error clasificando dominios: " + e.getMessage());
        }

        return classifications;
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    private String buildClassificationPrompt(List<String> domains) {
        var sb = new StringBuilder();
        sb.append("Clasifica estos dominios en categorías (social, video, cdn, porn, search, ");
        sb.append("shopping, news, business, streaming, other).\n");
        sb.append("Responde SOLO en formato: dominio.com:categoría\n");
        sb.append("Un dominio por línea, sin explicaciones.\n\n");

        for (var domain : domains) {
            sb.append(domain).append("\n");
        }

        return sb.toString();
    }

    private String callLlmForClassification(String prompt) {
        if (Config.GROQ_CHAT_ENABLED) {
            return GroqClient.chatUser(
                "Eres experto en clasificación de sitios web. Responde en español.",
                prompt
            );
        }

        // Fallback a llama.cpp local
        var fullPrompt = LlamaClient.buildPrompt(
            "Clasifica estos dominios correctamente.",
            prompt
        );
        return LlamaClient.complete(fullPrompt, 200, 30);
    }

    /**
     * Parsea la respuesta del LLM en formato "dominio:categoría".
     *
     * <p>Maneja líneas malformadas ignorándolas y extrayendo solo las válidas.
     */
    private Map<String, String> parseClassificationResponse(String response) {
        var result = new HashMap<String, String>();

        if (response == null || response.isEmpty()) {
            return result;
        }

        var lines = response.split("\n");
        for (var line : lines) {
            line = line.trim();
            if (line.isEmpty()) continue;

            var parts = line.split(":");
            if (parts.length == 2) {
                var domain = parts[0].trim().toLowerCase();
                var category = parts[1].trim().toLowerCase();

                // Validar dominio básico (contiene al menos un punto)
                if (domain.contains(".") && !category.isEmpty()) {
                    result.put(domain, category);
                }
            }
        }

        return result;
    }
}
