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

import mx.rafex.analyzer.db.DatabaseClient;

import java.time.Instant;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;
import java.util.logging.Logger;

/**
 * Motor heurístico de perfilado de dispositivos.
 *
 * <p>Analiza los dominios que visita un dispositivo (identificado por su IP)
 * y deduce su tipo: móvil iOS, móvil Android, Smart TV, laptop/desktop, IoT.
 *
 * <p>Referencia: TODO-AI.md Fase 6 — "Motor heurístico + LLM opcional:
 * iPhone, Android, Smart TV, laptop, IoT."
 *
 * <p>El perfil se mantiene en memoria y se persiste en SQLite via
 * {@link DatabaseClient#deviceProfileUpsert}.
 */
public final class DeviceProfiler {

    private static final Logger LOG = Logger.getLogger(DeviceProfiler.class.getName());
    private static final DateTimeFormatter ISO = DateTimeFormatter.ISO_INSTANT.withZone(ZoneOffset.UTC);

    // ── Dominios indicadores por tipo de dispositivo ─────────────────────────

    private static final Set<String> IOS_DOMAINS = Set.of(
        "apple.com", "icloud.com", "itunes.com", "mzstatic.com",
        "push.apple.com", "courier.push.apple.com", "gc.apple.com",
        "setup.icloud.com", "p01-fmf.icloud.com", "mask.icloud.com",
        "apple-relay.apple.com", "certs.apple.com", "ocsp.apple.com"
    );

    private static final Set<String> ANDROID_DOMAINS = Set.of(
        "gstatic.com", "googleapis.com", "play.google.com", "android.com",
        "googleplay.com", "google-analytics.com", "crashlytics.com",
        "firebase.com", "firebaseio.com", "goo.gl", "googlevideo.com"
    );

    private static final Set<String> SMART_TV_DOMAINS = Set.of(
        "netflix.com", "nflxvideo.net", "nflxext.com",
        "hbo.com", "hbomax.com",
        "disneyplus.com", "bamgrid.com",
        "primevideo.com", "amazon.com",
        "youtube.com", "googlevideo.com",
        "tvinteractive.tv", "samsungads.com", "samsungdfs.com",
        "lgsmartad.com", "lgtv.com", "smarttv.rokushop.com"
    );

    private static final Set<String> IOT_DOMAINS = Set.of(
        "update.googleapis.com", "mqtt.googleapis.com",
        "device.lifx.co", "api.lifx.co",
        "philips.com", "meethue.com",
        "nest.com", "api.nest.com",
        "belkin.com", "setup.belkin.com",
        "ifttt.com", "webhooks.ifttt.com",
        "alexa.amazon.com", "api.amazon.com",
        "pool.ntp.org", "time.google.com", "time.cloudflare.com"
    );

    private static final Set<String> LAPTOP_DOMAINS = Set.of(
        "github.com", "stackoverflow.com", "npmjs.com", "maven.org",
        "gradle.org", "docker.com", "hub.docker.com",
        "office.com", "microsoft.com", "live.com", "office365.com",
        "slack.com", "notion.so", "figma.com", "atlassian.com",
        "zoom.us", "webex.com",
        "jetbrains.com", "visualstudio.com", "code.visualstudio.com"
    );

    // ── Estado en memoria por dispositivo ────────────────────────────────────

    /** Puntuación acumulada por tipo de dispositivo por IP. */
    private final Map<String, Map<String, Integer>> scores = new ConcurrentHashMap<>();
    /** Dominios vistos por IP (para generar razones). */
    private final Map<String, Set<String>> domainsSeen = new ConcurrentHashMap<>();

    private final DatabaseClient db;

    public DeviceProfiler(DatabaseClient db) {
        this.db = db;
    }

    // ── API pública ───────────────────────────────────────────────────────────

    /**
     * Registra actividad de red de un dispositivo y actualiza su perfil.
     *
     * @param deviceIp IP del dispositivo
     * @param domains  lista de dominios visitados en este batch
     */
    public void updateProfile(String deviceIp, List<String> domains) {
        if (deviceIp == null || deviceIp.isBlank() || "unknown".equals(deviceIp)) return;
        if (domains == null || domains.isEmpty()) return;

        var score = scores.computeIfAbsent(deviceIp, k -> new HashMap<>());
        var seen  = domainsSeen.computeIfAbsent(deviceIp, k -> new LinkedHashSet<>());

        for (var domain : domains) {
            var d = domain.toLowerCase().trim();
            seen.add(d); // máximo de dominios visible en razones

            // Sumar puntos según categoría
            if (matchesDomain(d, IOS_DOMAINS))      score.merge("ios",      2, Integer::sum);
            if (matchesDomain(d, ANDROID_DOMAINS))  score.merge("android",  2, Integer::sum);
            if (matchesDomain(d, SMART_TV_DOMAINS)) score.merge("smart_tv", 3, Integer::sum);
            if (matchesDomain(d, IOT_DOMAINS))      score.merge("iot",      2, Integer::sum);
            if (matchesDomain(d, LAPTOP_DOMAINS))   score.merge("laptop",   2, Integer::sum);
        }

        // Derivar tipo y confianza
        var type  = inferType(score);
        var conf  = computeConfidence(score, type);
        var reasons = buildReasons(type, seen);
        var now   = ISO.format(Instant.now());

        // Persistir en BD
        try {
            db.deviceProfileUpsert(deviceIp, type, conf, reasons, now);
            LOG.fine("Perfil actualizado: %s → %s (conf=%.2f)".formatted(deviceIp, type, conf));
        } catch (Exception e) {
            LOG.warning("Error guardando perfil de " + deviceIp + ": " + e.getMessage());
        }
    }

    /**
     * Retorna un resumen legible del perfil de un dispositivo.
     *
     * @param deviceIp IP del dispositivo
     * @return descripción en español o cadena vacía si no hay perfil
     */
    public String getProfileSummary(String deviceIp) {
        var score = scores.get(deviceIp);
        if (score == null || score.isEmpty()) return "";

        var type = inferType(score);
        var conf = computeConfidence(score, type);
        return "Dispositivo %s clasificado como %s (confianza %.0f%%)".formatted(
            deviceIp, translateType(type), conf * 100);
    }

    // ── Helpers internos ─────────────────────────────────────────────────────

    /**
     * Comprueba si el dominio {@code d} termina en alguna de las entradas del set.
     * Ej: "push.apple.com" → termina en "apple.com" → true.
     */
    private static boolean matchesDomain(String d, Set<String> set) {
        if (set.contains(d)) return true;
        for (var entry : set) {
            if (d.endsWith("." + entry) || d.equals(entry)) return true;
        }
        return false;
    }

    /** Infiere el tipo de dispositivo a partir de las puntuaciones. */
    private static String inferType(Map<String, Integer> score) {
        if (score.isEmpty()) return "unknown";
        return score.entrySet().stream()
            .max(Map.Entry.comparingByValue())
            .map(Map.Entry::getKey)
            .orElse("unknown");
    }

    /**
     * Calcula la confianza como la proporción del tipo ganador sobre el total.
     * Mínimo 0.3 para tipos con al menos 1 punto; nunca supera 0.95.
     */
    private static double computeConfidence(Map<String, Integer> score, String type) {
        if (score.isEmpty()) return 0.0;
        int typeScore  = score.getOrDefault(type, 0);
        int totalScore = score.values().stream().mapToInt(Integer::intValue).sum();
        if (totalScore == 0) return 0.0;
        double raw = (double) typeScore / totalScore;
        return Math.min(0.95, Math.max(0.3, raw));
    }

    /** Construye una cadena JSON simple con las razones de la clasificación. */
    private static String buildReasons(String type, Set<String> seen) {
        var sb = new StringBuilder("[");
        int count = 0;
        for (var domain : seen) {
            if (isIndicatorFor(type, domain)) {
                if (count > 0) sb.append(",");
                sb.append("\"").append(domain).append("\"");
                if (++count >= 5) break; // máximo 5 razones
            }
        }
        sb.append("]");
        return sb.toString();
    }

    private static boolean isIndicatorFor(String type, String domain) {
        return switch (type) {
            case "ios"      -> matchesDomain(domain, IOS_DOMAINS);
            case "android"  -> matchesDomain(domain, ANDROID_DOMAINS);
            case "smart_tv" -> matchesDomain(domain, SMART_TV_DOMAINS);
            case "iot"      -> matchesDomain(domain, IOT_DOMAINS);
            case "laptop"   -> matchesDomain(domain, LAPTOP_DOMAINS);
            default         -> false;
        };
    }

    private static String translateType(String type) {
        return switch (type) {
            case "ios"      -> "iPhone/iPad (iOS)";
            case "android"  -> "Dispositivo Android";
            case "smart_tv" -> "Smart TV";
            case "iot"      -> "Dispositivo IoT";
            case "laptop"   -> "Laptop/Desktop";
            default         -> "Dispositivo desconocido";
        };
    }
}
