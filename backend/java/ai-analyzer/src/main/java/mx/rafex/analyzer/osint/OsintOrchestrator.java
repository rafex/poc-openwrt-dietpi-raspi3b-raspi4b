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

import mx.rafex.analyzer.db.DatabaseClient;
import mx.rafex.analyzer.http.ApiServer;
import mx.rafex.analyzer.util.Json;

import java.time.Instant;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.time.temporal.ChronoUnit;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.logging.Logger;

/**
 * Orquesta el pipeline completo OSINT:
 * <ol>
 *   <li>PhomberRunner — scans de IP, DNS, WHOIS, MAC via subprocess</li>
 *   <li>BingDorker   — búsquedas de reputación via SearchAPI.io</li>
 *   <li>OsintLLM     — extracción JSON de los datos OSINT (temp=0.05)</li>
 *   <li>DatabaseClient.osintInsert — persistencia con TTL por fuente</li>
 *   <li>ApiServer.broadcast — notificación SSE "osint_done"</li>
 * </ol>
 *
 * <p>El método {@link #enrichAsync} lanza el enriquecimiento en un <b>hilo
 * virtual</b> (Project Loom) para no bloquear el worker principal.
 *
 * <p>TTL de caché por fuente (en segundos):
 * <ul>
 *   <li>phomber-ip    → 24h (geoloc/ASN estable)</li>
 *   <li>phomber-mac   → 30d (vendor MAC permanente)</li>
 *   <li>phomber-dns   → 6h  (DNS puede cambiar)</li>
 *   <li>phomber-whois → 72h (WHOIS cambia poco)</li>
 *   <li>bing-dork     → 7d  (reputación estable)</li>
 * </ul>
 */
public final class OsintOrchestrator {

    private static final Logger LOG = Logger.getLogger(OsintOrchestrator.class.getName());
    private static final DateTimeFormatter ISO = DateTimeFormatter.ISO_INSTANT.withZone(ZoneOffset.UTC);

    /** TTL en segundos por fuente. */
    private static final Map<String, Long> TTL = Map.of(
        "phomber-ip",    86_400L,         // 24h
        "phomber-mac",   2_592_000L,      // 30d
        "phomber-dns",   21_600L,         // 6h
        "phomber-whois", 259_200L,        // 72h
        "bing-dork",     604_800L         // 7d
    );

    private final DatabaseClient db;
    private final PhomberRunner  phomber;
    private final BingDorker     bing;
    private final OsintLLM       llm;

    public OsintOrchestrator(DatabaseClient db) {
        this.db      = db;
        this.phomber = new PhomberRunner();
        this.bing    = new BingDorker();
        this.llm     = new OsintLLM();
    }

    /**
     * Lanza el enriquecimiento en un hilo virtual (Project Loom).
     * Retorna inmediatamente — el resultado se persiste en SQLite y
     * se notifica vía SSE cuando termina.
     */
    public void enrichAsync(long batchId, long alertId,
                            String sourceIp, String domain, String mac,
                            ApiServer apiServer) {
        Thread.ofVirtual()
            .name("osint-" + batchId)
            .start(() -> {
                try {
                    enrich(batchId, alertId, sourceIp, domain, mac, apiServer);
                } catch (Exception e) {
                    LOG.warning("OSINT error batch=%d: %s".formatted(batchId, e.getMessage()));
                }
            });
    }

    /**
     * Pipeline OSINT síncrono. Llamar desde hilo virtual o thread separado.
     *
     * @param batchId   ID del batch que disparó el enriquecimiento
     * @param alertId   ID de la alerta (-1 si no aplica)
     * @param sourceIp  IP externa detectada (puede ser null)
     * @param domain    Dominio sospechoso (puede ser null)
     * @param mac       MAC del dispositivo (puede ser null)
     * @param apiServer referencia al servidor SSE (puede ser null en tests)
     */
    public void enrich(long batchId, long alertId,
                       String sourceIp, String domain, String mac,
                       ApiServer apiServer) {

        var phomberOutputs = new LinkedHashMap<String, String>();
        String bingJson = "[]";

        // ── Scans PHOMBER ──────────────────────────────────────────────────────
        if (sourceIp != null && !sourceIp.isBlank()
                && !PhomberRunner.isPrivateOrProtected(sourceIp)) {

            if (!db.osintIsCached(sourceIp, "phomber-ip")) {
                phomberOutputs.put("ip",  phomber.scanIp(sourceIp));
                phomberOutputs.put("dns", phomber.scanDns(sourceIp));
            }
            if (bing.isAvailable() && !db.osintIsCached(sourceIp, "bing-dork")) {
                var snippets = bing.dorkIp(sourceIp);
                bingJson = BingDorker.toJsonArray(snippets);
                if (!snippets.isEmpty()) {
                    saveEnrichment(alertId, batchId, sourceIp, "ip", "bing-dork",
                        "", bingJson, "{}");
                }
            }
        }

        if (domain != null && !domain.isBlank()) {
            if (!db.osintIsCached(domain, "phomber-whois")) {
                phomberOutputs.put("whois", phomber.scanWhois(domain));
                if (!phomberOutputs.containsKey("dns")) {
                    phomberOutputs.put("dns", phomber.scanDns(domain));
                }
            }
            if (bing.isAvailable() && !db.osintIsCached(domain, "bing-dork")) {
                var snippets = bing.dorkDomain(domain);
                var domainBingJson = BingDorker.toJsonArray(snippets);
                if (!snippets.isEmpty()) {
                    bingJson = domainBingJson;  // usar el más reciente para el LLM
                    saveEnrichment(alertId, batchId, domain, "domain", "bing-dork",
                        "", domainBingJson, "{}");
                }
            }
        }

        if (mac != null && !mac.isBlank() && !db.osintIsCached(mac, "phomber-mac")) {
            phomberOutputs.put("mac", phomber.scanMac(mac));
        }

        if (phomberOutputs.isEmpty() && bingJson.equals("[]")) {
            LOG.fine("OSINT: todo en caché batch=%d alert=%d".formatted(batchId, alertId));
            return;
        }

        // ── LLM: extrae JSON del contexto OSINT ───────────────────────────────
        var alertCtx = buildAlertContext(alertId, sourceIp, domain);
        LOG.info("OsintLLM: %s scans + Bing batch=%d".formatted(phomberOutputs.keySet(), batchId));

        var llmJson    = llm.analyze(alertCtx, phomberOutputs, bingJson);
        var risk       = OsintLLM.extractField(llmJson, "risk");
        var summaryEs  = OsintLLM.extractField(llmJson, "summary_es");
        risk      = risk      != null ? risk      : "BAJO";
        summaryEs = summaryEs != null ? summaryEs : "";

        // ── Persistir resultado principal ─────────────────────────────────────
        var primaryTarget = sourceIp != null ? sourceIp : domain != null ? domain : mac;
        var primaryType   = sourceIp != null ? "ip"     : domain != null ? "domain" : "mac";
        var primarySource = "phomber-" + primaryType;

        var phomberCombined = buildCombinedPhomberText(phomberOutputs);
        saveEnrichment(alertId, batchId, primaryTarget, primaryType, primarySource,
            phomberCombined, bingJson, llmJson, risk, summaryEs);

        // ── Notificar dashboard via SSE ───────────────────────────────────────
        if (apiServer != null) {
            var event = new LinkedHashMap<String, Object>();
            event.put("event",      "osint_done");
            event.put("batch_id",   batchId);
            event.put("alert_id",   alertId);
            event.put("target",     primaryTarget);
            event.put("risk",       risk);
            event.put("summary_es", summaryEs);
            event.put("timestamp",  ISO.format(Instant.now()));
            apiServer.broadcast(Json.obj(event));
        }

        LOG.info("OSINT completado: target=%s risk=%s batch=%d".formatted(primaryTarget, risk, batchId));
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private void saveEnrichment(long alertId, long batchId,
                                String target, String targetType, String source,
                                String phomberRaw, String bingRaw, String llmResult) {
        saveEnrichment(alertId, batchId, target, targetType, source,
            phomberRaw, bingRaw, llmResult, null, null);
    }

    private void saveEnrichment(long alertId, long batchId,
                                String target, String targetType, String source,
                                String phomberRaw, String bingRaw, String llmResult,
                                String risk, String summaryEs) {
        try {
            var now       = ISO.format(Instant.now());
            var ttlSec    = TTL.getOrDefault(source, 86_400L);
            var expiresAt = ISO.format(Instant.now().plus(ttlSec, ChronoUnit.SECONDS));
            db.osintInsert(
                alertId, batchId,
                target, targetType, source,
                phomberRaw.isBlank() ? null : phomberRaw,
                bingRaw.equals("[]") ? null : bingRaw,
                llmResult.equals("{}") ? null : llmResult,
                risk, summaryEs,
                now, expiresAt
            );
        } catch (Exception e) {
            LOG.warning("Error guardando OSINT: " + e.getMessage());
        }
    }

    private Map<String, String> buildAlertContext(long alertId, String sourceIp, String domain) {
        var ctx = new LinkedHashMap<String, String>();
        ctx.put("alert_type", "osint_enrichment");
        ctx.put("severity",   "HIGH");
        ctx.put("source_ip",  sourceIp != null ? sourceIp : "");
        ctx.put("domain",     domain   != null ? domain   : "");
        ctx.put("message",    "Enriquecimiento OSINT alert_id=" + alertId);
        ctx.put("timestamp",  ISO.format(Instant.now()));
        return ctx;
    }

    private static String buildCombinedPhomberText(Map<String, String> outputs) {
        var sb = new StringBuilder();
        for (var entry : outputs.entrySet()) {
            if (entry.getValue() != null && !entry.getValue().isBlank()) {
                sb.append("[").append(entry.getKey().toUpperCase()).append("]\n");
                sb.append(entry.getValue()).append("\n\n");
            }
        }
        return sb.toString().strip();
    }
}
