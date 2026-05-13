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
import mx.rafex.analyzer.util.Json;

import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.logging.Logger;

/**
 * Búsquedas OSINT vía Bing usando SearchAPI.io como proxy.
 *
 * <p>La Bing Web Search API fue <b>retirada en agosto 2025</b>.
 * SearchAPI.io actúa como intermediario y acepta todos los operadores
 * Bing en el parámetro {@code q}, incluyendo el exclusivo
 * {@code ip:X.X.X.X} (reverse-IP lookup).
 *
 * <p>Sin {@code SEARCH_API_TOKEN} configurado, todas las búsquedas retornan
 * lista vacía (modo degradado — PHOMBER sigue funcionando).
 *
 * <p>Solo usa {@code java.net.http.HttpClient} — sin dependencias externas.
 *
 * @see <a href="https://www.searchapi.io/docs/bing">SearchAPI.io Bing docs</a>
 */
public final class BingDorker {

    private static final Logger LOG = Logger.getLogger(BingDorker.class.getName());

    private static final HttpClient HTTP = HttpClient.newBuilder()
        .connectTimeout(Duration.ofSeconds(10))
        .build();

    /** Templates de dork por tipo de indicador. */
    private static final Map<String, String> TEMPLATES = Map.of(
        "ip_reputation", "ip:{t} malware OR botnet OR scanner OR \"tor exit\" OR \"abuse report\"",
        "ip_cohost",     "ip:{t}",
        "domain_rep",    "\"{t}\" malware OR phishing OR \"command and control\" OR IOC OR \"threat report\"",
        "domain_sec",    "site:abuse.ch OR site:urlhaus.abuse.ch OR site:virustotal.com \"{t}\"",
        "domain_paste",  "site:pastebin.com OR site:github.com \"{t}\""
    );

    /** Registro de un resultado de Bing. */
    public record Result(String title, String url, String snippet) {
        /** Serializa a JSON string para el LLM y la BD. */
        public String toJson() {
            return "{\"title\":%s,\"url\":%s,\"snippet\":%s}"
                .formatted(Json.escape(title), Json.escape(url), Json.escape(snippet));
        }
    }

    private final boolean available;

    public BingDorker() {
        this.available = !Config.BING_API_KEY.isBlank();
        if (!available) {
            LOG.info("Bing dorks deshabilitados — configura SEARCH_API_TOKEN (SearchAPI.io)");
        }
    }

    public boolean isAvailable() { return available; }

    /**
     * Busca reputación de una IP pública usando operadores Bing exclusivos.
     * El operador {@code ip:X.X.X.X} es exclusivo de Bing y devuelve
     * todos los dominios co-hospedados y menciones web.
     */
    public List<Result> dorkIp(String ip) {
        if (PhomberRunner.isPrivateOrProtected(ip)) return List.of();
        var results = search(TEMPLATES.get("ip_reputation").replace("{t}", ip), 5);
        if (results.isEmpty()) {
            results = search(TEMPLATES.get("ip_cohost").replace("{t}", ip), 3);
        }
        return results;
    }

    /**
     * Busca reputación de un dominio en fuentes de threat intelligence.
     * Usa site: operators para abuse.ch, URLhaus, VirusTotal.
     */
    public List<Result> dorkDomain(String domain) {
        var results = new ArrayList<Result>();
        results.addAll(search(TEMPLATES.get("domain_rep").replace("{t}", domain), 5));
        results.addAll(search(TEMPLATES.get("domain_sec").replace("{t}", domain), 3));

        // Deduplicar por URL
        var seen    = new java.util.LinkedHashSet<String>();
        var unique  = new ArrayList<Result>();
        for (var r : results) {
            if (seen.add(r.url())) unique.add(r);
            if (unique.size() >= 7) break;
        }
        return unique;
    }

    /**
     * Serializa una lista de resultados a JSON array string para la BD.
     * Formato: [{title, url, snippet}, ...]
     */
    public static String toJsonArray(List<Result> results) {
        if (results.isEmpty()) return "[]";
        var sb = new StringBuilder("[");
        for (int i = 0; i < results.size(); i++) {
            if (i > 0) sb.append(',');
            sb.append(results.get(i).toJson());
        }
        return sb.append(']').toString();
    }

    // ── Búsqueda HTTP ─────────────────────────────────────────────────────────

    private List<Result> search(String query, int count) {
        if (!available) return List.of();

        var encodedQ = URLEncoder.encode(query, StandardCharsets.UTF_8);
        var url = "%s?engine=bing&q=%s&count=%d&api_key=%s"
            .formatted(Config.BING_ENDPOINT, encodedQ, count, Config.BING_API_KEY);

        try {
            var req = HttpRequest.newBuilder()
                .uri(URI.create(url))
                .timeout(Duration.ofSeconds(15))
                .header("Accept", "application/json")
                .GET()
                .build();

            var resp = HTTP.send(req, HttpResponse.BodyHandlers.ofString());
            if (resp.statusCode() != 200) {
                LOG.warning("Bing dork HTTP %d para: %s".formatted(resp.statusCode(), query.substring(0, Math.min(60, query.length()))));
                return List.of();
            }

            return parseResults(resp.body(), count);

        } catch (java.net.http.HttpTimeoutException e) {
            LOG.warning("Bing dork timeout: " + query.substring(0, Math.min(60, query.length())));
            return List.of();
        } catch (Exception e) {
            LOG.warning("Bing dork error: " + e.getMessage());
            return List.of();
        }
    }

    /**
     * Parsea los resultados de SearchAPI.io manualmente (sin librería JSON).
     * Busca el array "organic_results" o "webPages.value" según el formato.
     */
    private static List<Result> parseResults(String body, int maxCount) {
        var out = new ArrayList<Result>();
        // SearchAPI.io puede devolver "organic_results" o formato Bing nativo
        String arrayRaw = Json.extractRaw(body, "organic_results");
        if (arrayRaw == null) {
            var webPages = Json.extractRaw(body, "webPages");
            if (webPages != null) {
                arrayRaw = Json.extractRaw(webPages, "value");
            }
        }
        if (arrayRaw == null || !arrayRaw.startsWith("[")) return out;

        // Parsear items del array manualmente
        int depth = 0, start = -1;
        for (int i = 0; i < arrayRaw.length() && out.size() < maxCount; i++) {
            char c = arrayRaw.charAt(i);
            if (c == '{') { if (depth++ == 0) start = i; }
            else if (c == '}') {
                if (--depth == 0 && start >= 0) {
                    var item = arrayRaw.substring(start, i + 1);
                    var title   = Json.extractString(item, "title");
                    var url     = Json.extractString(item, "link");
                    if (url == null) url = Json.extractString(item, "url");
                    var snippet = Json.extractString(item, "snippet");
                    if (title != null && url != null) {
                        out.add(new Result(
                            title,
                            url,
                            snippet != null ? snippet : ""
                        ));
                    }
                    start = -1;
                }
            }
        }
        return out;
    }
}
