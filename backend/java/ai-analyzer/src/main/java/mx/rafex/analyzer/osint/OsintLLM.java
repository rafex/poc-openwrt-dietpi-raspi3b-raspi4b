package mx.rafex.analyzer.osint;

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
import mx.rafex.analyzer.llm.GroqClient;
import mx.rafex.analyzer.llm.LlamaClient;
import mx.rafex.analyzer.util.Json;

import java.util.List;
import java.util.Map;
import java.util.logging.Logger;
import java.util.regex.Pattern;

/**
 * Cliente LLM para extracción OSINT estructurada.
 *
 * <p>Recibe el texto limpio de PHOMBER (tablas ASCII) más snippets de Bing
 * y extrae un JSON estructurado con indicadores de seguridad.
 *
 * <p><b>Temperatura 0.05</b> — extracción determinista de hechos.
 * No se requiere creatividad: el LLM actúa como parser inteligente.
 *
 * <p><b>El LLM como parser</b> — el texto PHOMBER son tablas ASCII que el
 * LLM (incluso TinyLlama 1.1B Q4) entiende perfectamente. No hace falta
 * escribir parsers frágiles: si PHOMBER cambia su formato el LLM se adapta.
 *
 * <p>Compatible con Groq (prioridad si GROQ_API_KEY presente) y llama.cpp
 * local. El formato del prompt se adapta al modelo configurado (MODEL_FORMAT).
 */
public final class OsintLLM {

    private static final Logger LOG = Logger.getLogger(OsintLLM.class.getName());

    /** Regex para extraer el primer objeto JSON de la respuesta del LLM. */
    private static final Pattern JSON_RE = Pattern.compile("\\{[\\s\\S]*\\}");

    private static final String SYSTEM_PROMPT =
        "Eres un analista SOC experto en OSINT (Open Source Intelligence). " +
        "Recibirás datos en texto plano de herramientas de reconocimiento. " +
        "Tu tarea es extraer información de seguridad relevante. " +
        "Responde SIEMPRE con JSON válido, sin markdown, sin explicaciones adicionales.";

    private static final String JSON_SCHEMA = """
        {
          "risk": "BAJO|MEDIO|ALTO|CRÍTICO",
          "indicators": {
            "ip_country": null,
            "ip_isp": null,
            "ip_org": null,
            "ip_is_tor": false,
            "ip_is_datacenter": false,
            "mac_vendor": null,
            "domain_age_days": null,
            "domain_registrar": null,
            "domain_country": null,
            "dns_reverse": null,
            "known_malicious": false
          },
          "bing_findings": [],
          "key_findings": ["hallazgo 1", "hallazgo 2"],
          "recommended_action": "block|monitor|alert|none",
          "confidence": 0.75,
          "summary_es": "Resumen en español de 2-3 oraciones."
        }""";

    /**
     * Analiza el contexto OSINT y devuelve JSON estructurado.
     *
     * @param alert          contexto de la alerta (tipo, severidad, IP, dominio)
     * @param phomberOutputs mapa de tipo_scan → texto PHOMBER limpio (ip, dns, whois, mac)
     * @param bingSnippets   snippets de Bing como JSON array string
     * @return JSON string con los indicadores extraídos, o {@code "{}"} si falla
     */
    public String analyze(Map<String, String> alert,
                          Map<String, String> phomberOutputs,
                          String bingSnippets) {
        var userPrompt = buildPrompt(alert, phomberOutputs, bingSnippets);
        var raw = callLlm(userPrompt);
        return extractJson(raw);
    }

    // ── Prompt builder ────────────────────────────────────────────────────────

    private String buildPrompt(Map<String, String> alert,
                                Map<String, String> phomberOutputs,
                                String bingSnippets) {
        var sb = new StringBuilder();
        sb.append("Analiza los datos OSINT siguientes y extrae información de seguridad.\n\n");

        sb.append("═══ ALERTA DETECTADA ═══\n");
        sb.append("Tipo       : ").append(alert.getOrDefault("alert_type", "unknown")).append('\n');
        sb.append("Severidad  : ").append(alert.getOrDefault("severity",   "unknown")).append('\n');
        sb.append("Fuente IP  : ").append(alert.getOrDefault("source_ip",  "N/A")).append('\n');
        sb.append("Dominio    : ").append(alert.getOrDefault("domain",     "N/A")).append('\n');
        sb.append("Descripción: ").append(alert.getOrDefault("message",    "N/A")).append('\n');
        sb.append('\n');

        // Output de PHOMBER — texto ASCII que el LLM lee directamente
        for (var entry : phomberOutputs.entrySet()) {
            var scanType = entry.getKey();
            var output   = entry.getValue();
            if (output != null && !output.startsWith("[Omitido]") && !output.startsWith("[Error]")) {
                sb.append("═══ PHOMBER ").append(scanType.toUpperCase()).append(" ═══\n");
                sb.append(output).append("\n\n");
            }
        }

        // Snippets de Bing
        if (bingSnippets != null && !bingSnippets.equals("[]") && !bingSnippets.isBlank()) {
            sb.append("═══ BING OSINT (reputación web) ═══\n");
            sb.append(bingSnippets).append("\n\n");
        }

        sb.append("═══ INSTRUCCIÓN ═══\n");
        sb.append("Extrae la información de seguridad y responde ÚNICAMENTE con este JSON:\n");
        sb.append(JSON_SCHEMA);

        return sb.toString();
    }

    // ── LLM call ─────────────────────────────────────────────────────────────

    private String callLlm(String userPrompt) {
        if (Config.GROQ_CHAT_ENABLED) {
            return callGroq(userPrompt);
        }
        return callLlama(userPrompt);
    }

    private String callGroq(String userPrompt) {
        LOG.fine("OsintLLM → Groq (temp=0.05)");
        return GroqClient.chat(
            List.of(
                Map.of("role", "system", "content", SYSTEM_PROMPT),
                Map.of("role", "user",   "content", userPrompt)
            ),
            0.05,   // temperatura — extracción determinista
            512
        );
    }

    private String callLlama(String userPrompt) {
        LOG.fine("OsintLLM → llama.cpp local (temp=0.05)");
        // LlamaClient.complete usa temperatura 0.3 por defecto.
        // Para OSINT necesitamos 0.05 — construimos el body manualmente
        // reutilizando el buildPrompt con el formato correcto del modelo.
        var fullPrompt = LlamaClient.buildPrompt(SYSTEM_PROMPT, userPrompt);
        return callLlamaWithTemp(fullPrompt, 0.05, 512, Config.OSINT_LLM_TIMEOUT_S);
    }

    /** Llama a llama.cpp con temperatura personalizada. */
    private static String callLlamaWithTemp(String prompt, double temperature,
                                             int nPredict, int timeoutS) {
        try {
            var body = """
                {"prompt":%s,"n_predict":%d,"temperature":%s,"stream":false}
                """.formatted(Json.escape(prompt), nPredict, temperature).strip();

            var req = java.net.http.HttpClient.newBuilder()
                .connectTimeout(java.time.Duration.ofSeconds(5))
                .build()
                .send(
                    java.net.http.HttpRequest.newBuilder()
                        .uri(java.net.URI.create(Config.LLAMA_URL + "/completion"))
                        .timeout(java.time.Duration.ofSeconds(timeoutS))
                        .header("Content-Type", "application/json")
                        .POST(java.net.http.HttpRequest.BodyPublishers.ofString(body))
                        .build(),
                    java.net.http.HttpResponse.BodyHandlers.ofString()
                );

            if (req.statusCode() == 200) {
                var content = Json.extractString(req.body(), "content");
                return content != null ? content.strip() : "{}";
            }
            return "{}";
        } catch (Exception e) {
            LOG.warning("OsintLLM llama.cpp error: " + e.getMessage());
            return "{}";
        }
    }

    // ── Extracción de JSON ────────────────────────────────────────────────────

    /**
     * Extrae el primer objeto JSON de la respuesta del LLM.
     * El LLM puede incluir texto antes/después del JSON.
     */
    private static String extractJson(String raw) {
        if (raw == null || raw.isBlank()) return "{}";
        var m = JSON_RE.matcher(raw);
        return m.find() ? m.group(0) : "{}";
    }

    /** Extrae un campo string del JSON retornado por analyze(). */
    public static String extractField(String json, String field) {
        return Json.extractString(json, field);
    }
}
