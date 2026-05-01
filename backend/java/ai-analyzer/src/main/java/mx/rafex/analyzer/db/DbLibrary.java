package mx.rafex.analyzer.db;

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

import java.lang.foreign.*;
import java.lang.invoke.MethodHandle;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;

/**
 * Bindings Panama FFI para {@code libanalyzer_db.so}.
 *
 * <p>Todas las funciones son {@code static} y corresponden 1:1 a los símbolos
 * exportados por el crate Rust {@code analyzer-db}.
 *
 * <p>La carga de la librería se hace una sola vez al inicializar la clase.
 * GraalVM debe configurarse con:
 * <pre>
 *   --initialize-at-run-time=mx.rafex.analyzer.db.DbLibrary
 *   -H:+ForeignAPISupport
 * </pre>
 *
 * <h2>Gestión de memoria</h2>
 * <ul>
 *   <li>Funciones que devuelven {@code MemorySegment} (puntero a char*) transfieren
 *       la propiedad a Java — llamar {@link #db_free_string(MemorySegment)} cuando
 *       termine.</li>
 *   <li>{@link #db_last_error()} devuelve puntero interno de Rust — NO liberar.</li>
 *   <li>{@link #db_close(MemorySegment)} libera el handle.</li>
 * </ul>
 */
public final class DbLibrary {

    private static final SymbolLookup LIB;
    private static final Linker LINKER = Linker.nativeLinker();

    // Descriptores de tipos C
    private static final ValueLayout.OfLong   C_LONG   = ValueLayout.JAVA_LONG;
    private static final ValueLayout.OfInt    C_INT    = ValueLayout.JAVA_INT;
    private static final ValueLayout.OfDouble C_DOUBLE = ValueLayout.JAVA_DOUBLE;
    private static final AddressLayout        C_PTR    = ValueLayout.ADDRESS;

    static {
        LIB = loadLibraryLookup();
    }

    // ── MethodHandles ─────────────────────────────────────────────────────────

    // Gestión del handle
    private static final MethodHandle MH_DB_OPEN   = find("db_open",   FunctionDescriptor.of(C_PTR, C_PTR));
    private static final MethodHandle MH_DB_CLOSE  = find("db_close",  FunctionDescriptor.ofVoid(C_PTR));
    private static final MethodHandle MH_DB_PING   = find("db_ping",   FunctionDescriptor.of(C_LONG, C_PTR));
    private static final MethodHandle MH_DB_VERSION = find("db_sqlite_version", FunctionDescriptor.of(C_PTR));
    private static final MethodHandle MH_LAST_ERROR = find("db_last_error", FunctionDescriptor.of(C_PTR));
    private static final MethodHandle MH_FREE_STR  = find("db_free_string", FunctionDescriptor.ofVoid(C_PTR));

    // batches
    private static final MethodHandle MH_BATCH_INSERT         = find("batch_insert",         FunctionDescriptor.of(C_LONG, C_PTR, C_PTR, C_PTR, C_PTR));
    private static final MethodHandle MH_BATCH_SET_STATUS     = find("batch_set_status",     FunctionDescriptor.of(C_INT,  C_PTR, C_LONG, C_PTR));
    private static final MethodHandle MH_BATCH_GET_BY_ID      = find("batch_get_by_id",      FunctionDescriptor.of(C_PTR,  C_PTR, C_LONG));
    private static final MethodHandle MH_BATCH_GET_PAYLOAD    = find("batch_get_payload",    FunctionDescriptor.of(C_PTR,  C_PTR, C_LONG));
    private static final MethodHandle MH_BATCH_LIST_PENDING   = find("batch_list_pending",   FunctionDescriptor.of(C_PTR,  C_PTR, C_LONG));
    private static final MethodHandle MH_BATCH_LIST_RECENT    = find("batch_list_recent",    FunctionDescriptor.of(C_PTR,  C_PTR, C_LONG));
    private static final MethodHandle MH_BATCH_COUNT          = find("batch_count",          FunctionDescriptor.of(C_LONG, C_PTR));
    private static final MethodHandle MH_BATCH_COUNT_PENDING  = find("batch_count_pending",  FunctionDescriptor.of(C_LONG, C_PTR));
    private static final MethodHandle MH_BATCH_PURGE_BEFORE   = find("batch_purge_before",   FunctionDescriptor.of(C_LONG, C_PTR, C_PTR));

    // analyses
    private static final MethodHandle MH_ANALYSIS_INSERT          = find("analysis_insert",          FunctionDescriptor.of(C_LONG, C_PTR, C_LONG, C_PTR, C_PTR, C_PTR, C_DOUBLE, C_LONG, C_LONG, C_PTR));
    private static final MethodHandle MH_ANALYSIS_LIST_RECENT     = find("analysis_list_recent",     FunctionDescriptor.of(C_PTR,  C_PTR, C_LONG));
    private static final MethodHandle MH_ANALYSIS_GET_BY_BATCH    = find("analysis_get_by_batch",    FunctionDescriptor.of(C_PTR,  C_PTR, C_LONG));
    private static final MethodHandle MH_ANALYSIS_COUNT           = find("analysis_count",           FunctionDescriptor.of(C_LONG, C_PTR));
    private static final MethodHandle MH_ANALYSIS_COUNT_BY_RISK   = find("analysis_count_by_risk",   FunctionDescriptor.of(C_PTR,  C_PTR));

    // alerts
    private static final MethodHandle MH_ALERT_INSERT            = find("alert_insert",            FunctionDescriptor.of(C_LONG, C_PTR, C_LONG, C_PTR, C_PTR, C_PTR, C_PTR, C_PTR, C_PTR, C_PTR));
    private static final MethodHandle MH_ALERT_LIST_RECENT       = find("alert_list_recent",       FunctionDescriptor.of(C_PTR,  C_PTR, C_LONG));
    private static final MethodHandle MH_ALERT_LIST_BY_SEVERITY  = find("alert_list_by_severity",  FunctionDescriptor.of(C_PTR,  C_PTR, C_PTR, C_LONG));
    private static final MethodHandle MH_ALERT_COUNT_BY_SEVERITY = find("alert_count_by_severity", FunctionDescriptor.of(C_PTR,  C_PTR));

    // chat
    private static final MethodHandle MH_CHAT_SESSION_UPSERT = find("chat_session_upsert", FunctionDescriptor.of(C_LONG, C_PTR, C_PTR, C_PTR));
    private static final MethodHandle MH_CHAT_SESSION_LIST   = find("chat_session_list",   FunctionDescriptor.of(C_PTR,  C_PTR));
    private static final MethodHandle MH_CHAT_MSG_INSERT     = find("chat_message_insert", FunctionDescriptor.of(C_LONG, C_PTR, C_PTR, C_PTR, C_PTR, C_PTR, C_PTR));
    private static final MethodHandle MH_CHAT_MSG_HISTORY    = find("chat_message_history",FunctionDescriptor.of(C_PTR,  C_PTR, C_PTR, C_LONG));
    private static final MethodHandle MH_CHAT_SESSION_CLEAR  = find("chat_session_clear",  FunctionDescriptor.of(C_LONG, C_PTR, C_PTR));
    private static final MethodHandle MH_CHAT_MSG_LIST_ALL   = find("chat_message_list_all", FunctionDescriptor.of(C_PTR, C_PTR, C_LONG));

    // rules
    private static final MethodHandle MH_RULE_UPSERT = find("rule_upsert", FunctionDescriptor.of(C_LONG, C_PTR, C_PTR, C_PTR, C_PTR));
    private static final MethodHandle MH_RULE_GET    = find("rule_get",    FunctionDescriptor.of(C_PTR,  C_PTR, C_PTR));
    private static final MethodHandle MH_RULE_LIST   = find("rule_list",   FunctionDescriptor.of(C_PTR,  C_PTR));
    private static final MethodHandle MH_RULE_DELETE = find("rule_delete", FunctionDescriptor.of(C_LONG, C_PTR, C_PTR));

    // domains / whitelist / device_profiles
    private static final MethodHandle MH_DOMAIN_CAT_UPSERT    = find("domain_category_upsert", FunctionDescriptor.of(C_LONG, C_PTR, C_PTR, C_PTR, C_DOUBLE, C_PTR, C_PTR));
    private static final MethodHandle MH_DOMAIN_CAT_GET       = find("domain_category_get",    FunctionDescriptor.of(C_PTR,  C_PTR, C_PTR));
    private static final MethodHandle MH_DOMAIN_CAT_LIST      = find("domain_category_list",   FunctionDescriptor.of(C_PTR,  C_PTR));
    private static final MethodHandle MH_WHITELIST_ADD        = find("whitelist_add",          FunctionDescriptor.of(C_LONG, C_PTR, C_PTR, C_PTR, C_PTR));
    private static final MethodHandle MH_WHITELIST_CONTAINS   = find("whitelist_contains",     FunctionDescriptor.of(C_LONG, C_PTR, C_PTR));
    private static final MethodHandle MH_WHITELIST_LIST       = find("whitelist_list",         FunctionDescriptor.of(C_PTR,  C_PTR));
    private static final MethodHandle MH_WHITELIST_REMOVE     = find("whitelist_remove",       FunctionDescriptor.of(C_LONG, C_PTR, C_PTR));
    private static final MethodHandle MH_DEVICE_UPSERT        = find("device_profile_upsert", FunctionDescriptor.of(C_LONG, C_PTR, C_PTR, C_PTR, C_DOUBLE, C_PTR, C_PTR));
    private static final MethodHandle MH_DEVICE_GET           = find("device_profile_get",    FunctionDescriptor.of(C_PTR,  C_PTR, C_PTR));
    private static final MethodHandle MH_DEVICE_LIST          = find("device_profile_list",   FunctionDescriptor.of(C_PTR,  C_PTR));

    // misc: policy_actions, prompt_logs, human_explanations, summaries, reports
    private static final MethodHandle MH_POLICY_ACTION_INSERT       = find("policy_action_insert",       FunctionDescriptor.of(C_LONG, C_PTR, C_PTR, C_PTR, C_PTR, C_PTR));
    private static final MethodHandle MH_POLICY_ACTION_LIST_RECENT  = find("policy_action_list_recent",  FunctionDescriptor.of(C_PTR,  C_PTR, C_LONG));
    private static final MethodHandle MH_PROMPT_LOG_INSERT          = find("prompt_log_insert",          FunctionDescriptor.of(C_LONG, C_PTR, C_PTR, C_LONG, C_PTR, C_PTR, C_PTR, C_PTR));
    private static final MethodHandle MH_HUMAN_EXPL_INSERT          = find("human_explanation_insert",   FunctionDescriptor.of(C_LONG, C_PTR, C_LONG, C_PTR, C_PTR, C_PTR));
    private static final MethodHandle MH_HUMAN_EXPL_BY_BATCH        = find("human_explanation_get_by_batch", FunctionDescriptor.of(C_PTR, C_PTR, C_LONG));
    private static final MethodHandle MH_SUMMARY_INSERT             = find("summary_insert",             FunctionDescriptor.of(C_LONG, C_PTR, C_PTR, C_PTR, C_PTR));
    private static final MethodHandle MH_SUMMARY_LIST_RECENT        = find("summary_list_recent",        FunctionDescriptor.of(C_PTR,  C_PTR, C_LONG));
    private static final MethodHandle MH_REPORT_INSERT              = find("report_insert",              FunctionDescriptor.of(C_LONG, C_PTR, C_PTR, C_PTR, C_PTR));
    private static final MethodHandle MH_REPORT_LIST_RECENT         = find("report_list_recent",         FunctionDescriptor.of(C_PTR,  C_PTR, C_LONG));

    // ── Helpers de carga ─────────────────────────────────────────────────────

    private static MethodHandle find(String name, FunctionDescriptor desc) {
        var addr = LIB.find(name)
            .orElseThrow(() -> new UnsatisfiedLinkError("símbolo no encontrado en libanalyzer_db: " + name));
        return LINKER.downcallHandle(addr, desc);
    }

    private static SymbolLookup loadLibraryLookup() {
        var explicit = System.getProperty("analyzer.db.lib",
            System.getenv().getOrDefault("ANALYZER_DB_LIB", "")).trim();

        List<Path> candidates = new ArrayList<>();
        if (!explicit.isBlank()) {
            candidates.add(Path.of(explicit));
        }

        // Defaults conocidos para contenedor/runtime
        candidates.add(Path.of("/opt/ai-analyzer/lib/libanalyzer_db.so"));
        candidates.add(Path.of("/usr/local/lib/libanalyzer_db.so"));
        candidates.add(Path.of("libanalyzer_db.so"));
        candidates.add(Path.of("lib/libanalyzer_db.so"));

        var tried = new StringBuilder();
        for (Path candidate : candidates) {
            try {
                var normalized = candidate.toAbsolutePath().normalize();
                if (!Files.exists(normalized)) {
                    tried.append(" - ").append(normalized).append(" (no existe)\n");
                    continue;
                }
                if (!Files.isRegularFile(normalized)) {
                    tried.append(" - ").append(normalized).append(" (no es archivo regular)\n");
                    continue;
                }
                return SymbolLookup.libraryLookup(normalized, Arena.global());
            } catch (Throwable t) {
                tried.append(" - ").append(candidate.toAbsolutePath().normalize())
                    .append(" (error: ").append(t.getClass().getSimpleName()).append(": ")
                    .append(t.getMessage()).append(")\n");
            }
        }

        throw new IllegalStateException(
            "No se pudo cargar libanalyzer_db.so. Rutas probadas:\n" + tried
        );
    }

    // ── API pública ───────────────────────────────────────────────────────────

    public static MemorySegment db_open(String path) {
        try (var arena = Arena.ofConfined()) {
            var seg = arena.allocateFrom(path);
            return (MemorySegment) MH_DB_OPEN.invokeExact(seg);
        } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static void db_close(MemorySegment handle) {
        try { MH_DB_CLOSE.invokeExact(handle); }
        catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static long db_ping(MemorySegment handle) {
        try { return (long) MH_DB_PING.invokeExact(handle); }
        catch (Throwable t) { throw new RuntimeException(t); }
    }

    /** Devuelve la versión SQLite. El llamador debe liberar con db_free_string. */
    public static MemorySegment db_sqlite_version() {
        try { return (MemorySegment) MH_DB_VERSION.invokeExact(); }
        catch (Throwable t) { throw new RuntimeException(t); }
    }

    /**
     * Puntero interno de Rust — NO liberar.
     * Válido hasta la próxima llamada a cualquier función db_*.
     */
    public static MemorySegment db_last_error() {
        try { return (MemorySegment) MH_LAST_ERROR.invokeExact(); }
        catch (Throwable t) { throw new RuntimeException(t); }
    }

    /** Libera memoria de un *mut c_char devuelto por Rust. */
    public static void db_free_string(MemorySegment ptr) {
        if (ptr == null || ptr.equals(MemorySegment.NULL)) return;
        try { MH_FREE_STR.invokeExact(ptr); }
        catch (Throwable t) { throw new RuntimeException(t); }
    }

    // ── batches ───────────────────────────────────────────────────────────────

    public static long batch_insert(MemorySegment h, String receivedAt, String sensorIp, String payload) {
        try (var a = Arena.ofConfined()) {
            var at  = a.allocateFrom(receivedAt);
            var ip  = sensorIp != null ? a.allocateFrom(sensorIp) : MemorySegment.NULL;
            var pld = a.allocateFrom(payload);
            return (long) MH_BATCH_INSERT.invokeExact(h, at, ip, pld);
        } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static int batch_set_status(MemorySegment h, long id, String status) {
        try (var a = Arena.ofConfined()) {
            return (int) MH_BATCH_SET_STATUS.invokeExact(h, id, a.allocateFrom(status));
        } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static MemorySegment batch_get_by_id(MemorySegment h, long id) {
        try { return (MemorySegment) MH_BATCH_GET_BY_ID.invokeExact(h, id); }
        catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static MemorySegment batch_get_payload(MemorySegment h, long id) {
        try { return (MemorySegment) MH_BATCH_GET_PAYLOAD.invokeExact(h, id); }
        catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static MemorySegment batch_list_pending(MemorySegment h, long limit) {
        try { return (MemorySegment) MH_BATCH_LIST_PENDING.invokeExact(h, limit); }
        catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static MemorySegment batch_list_recent(MemorySegment h, long limit) {
        try { return (MemorySegment) MH_BATCH_LIST_RECENT.invokeExact(h, limit); }
        catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static long batch_count(MemorySegment h) {
        try { return (long) MH_BATCH_COUNT.invokeExact(h); }
        catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static long batch_count_pending(MemorySegment h) {
        try { return (long) MH_BATCH_COUNT_PENDING.invokeExact(h); }
        catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static long batch_purge_before(MemorySegment h, String beforeIso) {
        try (var a = Arena.ofConfined()) {
            return (long) MH_BATCH_PURGE_BEFORE.invokeExact(h, a.allocateFrom(beforeIso));
        } catch (Throwable t) { throw new RuntimeException(t); }
    }

    // ── analyses ─────────────────────────────────────────────────────────────

    public static long analysis_insert(MemorySegment h, long batchId, String timestamp,
                                       String risk, String analysis, double elapsedS,
                                       long suspiciousCount, long packets, String bytesFmt) {
        try (var a = Arena.ofConfined()) {
            return (long) MH_ANALYSIS_INSERT.invokeExact(h, batchId,
                a.allocateFrom(timestamp), a.allocateFrom(risk), a.allocateFrom(analysis),
                elapsedS, suspiciousCount, packets, a.allocateFrom(bytesFmt));
        } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static MemorySegment analysis_list_recent(MemorySegment h, long limit) {
        try { return (MemorySegment) MH_ANALYSIS_LIST_RECENT.invokeExact(h, limit); }
        catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static MemorySegment analysis_get_by_batch(MemorySegment h, long batchId) {
        try { return (MemorySegment) MH_ANALYSIS_GET_BY_BATCH.invokeExact(h, batchId); }
        catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static long analysis_count(MemorySegment h) {
        try { return (long) MH_ANALYSIS_COUNT.invokeExact(h); }
        catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static MemorySegment analysis_count_by_risk(MemorySegment h) {
        try { return (MemorySegment) MH_ANALYSIS_COUNT_BY_RISK.invokeExact(h); }
        catch (Throwable t) { throw new RuntimeException(t); }
    }

    // ── alerts ───────────────────────────────────────────────────────────────

    public static long alert_insert(MemorySegment h, long batchId, String timestamp,
                                    String severity, String alertType, String message,
                                    String sourceIp, String domain, String meta) {
        try (var a = Arena.ofConfined()) {
            var ip = sourceIp != null ? a.allocateFrom(sourceIp) : MemorySegment.NULL;
            var dm = domain   != null ? a.allocateFrom(domain)   : MemorySegment.NULL;
            var mt = meta     != null ? a.allocateFrom(meta)     : MemorySegment.NULL;
            return (long) MH_ALERT_INSERT.invokeExact(h, batchId,
                a.allocateFrom(timestamp), a.allocateFrom(severity),
                a.allocateFrom(alertType), a.allocateFrom(message), ip, dm, mt);
        } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static MemorySegment alert_list_recent(MemorySegment h, long limit) {
        try { return (MemorySegment) MH_ALERT_LIST_RECENT.invokeExact(h, limit); }
        catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static MemorySegment alert_list_by_severity(MemorySegment h, String severity, long limit) {
        try (var a = Arena.ofConfined()) {
            return (MemorySegment) MH_ALERT_LIST_BY_SEVERITY.invokeExact(h, a.allocateFrom(severity), limit);
        } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static MemorySegment alert_count_by_severity(MemorySegment h) {
        try { return (MemorySegment) MH_ALERT_COUNT_BY_SEVERITY.invokeExact(h); }
        catch (Throwable t) { throw new RuntimeException(t); }
    }

    // ── chat ─────────────────────────────────────────────────────────────────

    public static long chat_session_upsert(MemorySegment h, String sessionId, String nowIso) {
        try (var a = Arena.ofConfined()) {
            return (long) MH_CHAT_SESSION_UPSERT.invokeExact(h, a.allocateFrom(sessionId), a.allocateFrom(nowIso));
        } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static MemorySegment chat_session_list(MemorySegment h) {
        try { return (MemorySegment) MH_CHAT_SESSION_LIST.invokeExact(h); }
        catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static long chat_message_insert(MemorySegment h, String sessionId, String timestamp,
                                           String role, String content, String meta) {
        try (var a = Arena.ofConfined()) {
            var mt = meta != null ? a.allocateFrom(meta) : MemorySegment.NULL;
            return (long) MH_CHAT_MSG_INSERT.invokeExact(h,
                a.allocateFrom(sessionId), a.allocateFrom(timestamp),
                a.allocateFrom(role), a.allocateFrom(content), mt);
        } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static MemorySegment chat_message_history(MemorySegment h, String sessionId, long limit) {
        try (var a = Arena.ofConfined()) {
            return (MemorySegment) MH_CHAT_MSG_HISTORY.invokeExact(h, a.allocateFrom(sessionId), limit);
        } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static long chat_session_clear(MemorySegment h, String sessionId) {
        try (var a = Arena.ofConfined()) {
            return (long) MH_CHAT_SESSION_CLEAR.invokeExact(h, a.allocateFrom(sessionId));
        } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static MemorySegment chat_message_list_all(MemorySegment h, long limit) {
        try { return (MemorySegment) MH_CHAT_MSG_LIST_ALL.invokeExact(h, limit); }
        catch (Throwable t) { throw new RuntimeException(t); }
    }

    // ── rules ────────────────────────────────────────────────────────────────

    public static long rule_upsert(MemorySegment h, String key, String value, String updatedAt) {
        try (var a = Arena.ofConfined()) {
            return (long) MH_RULE_UPSERT.invokeExact(h, a.allocateFrom(key), a.allocateFrom(value), a.allocateFrom(updatedAt));
        } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static MemorySegment rule_get(MemorySegment h, String key) {
        try (var a = Arena.ofConfined()) {
            return (MemorySegment) MH_RULE_GET.invokeExact(h, a.allocateFrom(key));
        } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static MemorySegment rule_list(MemorySegment h) {
        try { return (MemorySegment) MH_RULE_LIST.invokeExact(h); }
        catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static long rule_delete(MemorySegment h, String key) {
        try (var a = Arena.ofConfined()) {
            return (long) MH_RULE_DELETE.invokeExact(h, a.allocateFrom(key));
        } catch (Throwable t) { throw new RuntimeException(t); }
    }

    // ── domains ──────────────────────────────────────────────────────────────

    public static long domain_category_upsert(MemorySegment h, String domain, String category,
                                              double confidence, String source, String updatedAt) {
        try (var a = Arena.ofConfined()) {
            return (long) MH_DOMAIN_CAT_UPSERT.invokeExact(h, a.allocateFrom(domain),
                a.allocateFrom(category), confidence, a.allocateFrom(source), a.allocateFrom(updatedAt));
        } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static MemorySegment domain_category_get(MemorySegment h, String domain) {
        try (var a = Arena.ofConfined()) {
            return (MemorySegment) MH_DOMAIN_CAT_GET.invokeExact(h, a.allocateFrom(domain));
        } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static MemorySegment domain_category_list(MemorySegment h) {
        try { return (MemorySegment) MH_DOMAIN_CAT_LIST.invokeExact(h); }
        catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static long whitelist_add(MemorySegment h, String domain, String reason, String createdAt) {
        try (var a = Arena.ofConfined()) {
            var rsn = reason != null ? a.allocateFrom(reason) : MemorySegment.NULL;
            return (long) MH_WHITELIST_ADD.invokeExact(h, a.allocateFrom(domain), rsn, a.allocateFrom(createdAt));
        } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static long whitelist_contains(MemorySegment h, String domain) {
        try (var a = Arena.ofConfined()) {
            return (long) MH_WHITELIST_CONTAINS.invokeExact(h, a.allocateFrom(domain));
        } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static MemorySegment whitelist_list(MemorySegment h) {
        try { return (MemorySegment) MH_WHITELIST_LIST.invokeExact(h); }
        catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static long whitelist_remove(MemorySegment h, String domain) {
        try (var a = Arena.ofConfined()) {
            return (long) MH_WHITELIST_REMOVE.invokeExact(h, a.allocateFrom(domain));
        } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static long device_profile_upsert(MemorySegment h, String ip, String deviceType,
                                             double confidence, String reasons, String updatedAt) {
        try (var a = Arena.ofConfined()) {
            var rsn = reasons != null ? a.allocateFrom(reasons) : MemorySegment.NULL;
            return (long) MH_DEVICE_UPSERT.invokeExact(h, a.allocateFrom(ip),
                a.allocateFrom(deviceType), confidence, rsn, a.allocateFrom(updatedAt));
        } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static MemorySegment device_profile_get(MemorySegment h, String ip) {
        try (var a = Arena.ofConfined()) {
            return (MemorySegment) MH_DEVICE_GET.invokeExact(h, a.allocateFrom(ip));
        } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static MemorySegment device_profile_list(MemorySegment h) {
        try { return (MemorySegment) MH_DEVICE_LIST.invokeExact(h); }
        catch (Throwable t) { throw new RuntimeException(t); }
    }

    // ── misc ─────────────────────────────────────────────────────────────────

    public static long policy_action_insert(MemorySegment h, String timestamp, String action,
                                            String reason, String details) {
        try (var a = Arena.ofConfined()) {
            var rsn = reason  != null ? a.allocateFrom(reason)  : MemorySegment.NULL;
            var det = details != null ? a.allocateFrom(details) : MemorySegment.NULL;
            return (long) MH_POLICY_ACTION_INSERT.invokeExact(h, a.allocateFrom(timestamp), a.allocateFrom(action), rsn, det);
        } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static MemorySegment policy_action_list_recent(MemorySegment h, long limit) {
        try { return (MemorySegment) MH_POLICY_ACTION_LIST_RECENT.invokeExact(h, limit); }
        catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static long prompt_log_insert(MemorySegment h, String timestamp, long batchId,
                                         String promptType, String prompt, String response, String meta) {
        try (var a = Arena.ofConfined()) {
            var rsp = response != null ? a.allocateFrom(response) : MemorySegment.NULL;
            var mt  = meta     != null ? a.allocateFrom(meta)     : MemorySegment.NULL;
            return (long) MH_PROMPT_LOG_INSERT.invokeExact(h, a.allocateFrom(timestamp), batchId,
                a.allocateFrom(promptType), a.allocateFrom(prompt), rsp, mt);
        } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static long human_explanation_insert(MemorySegment h, long batchId, String timestamp,
                                                String text, String meta) {
        try (var a = Arena.ofConfined()) {
            var mt = meta != null ? a.allocateFrom(meta) : MemorySegment.NULL;
            return (long) MH_HUMAN_EXPL_INSERT.invokeExact(h, batchId, a.allocateFrom(timestamp), a.allocateFrom(text), mt);
        } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static MemorySegment human_explanation_get_by_batch(MemorySegment h, long batchId) {
        try { return (MemorySegment) MH_HUMAN_EXPL_BY_BATCH.invokeExact(h, batchId); }
        catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static long summary_insert(MemorySegment h, String timestamp, String summary, String meta) {
        try (var a = Arena.ofConfined()) {
            var mt = meta != null ? a.allocateFrom(meta) : MemorySegment.NULL;
            return (long) MH_SUMMARY_INSERT.invokeExact(h, a.allocateFrom(timestamp), a.allocateFrom(summary), mt);
        } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static MemorySegment summary_list_recent(MemorySegment h, long limit) {
        try { return (MemorySegment) MH_SUMMARY_LIST_RECENT.invokeExact(h, limit); }
        catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static long report_insert(MemorySegment h, String timestamp, String report, String meta) {
        try (var a = Arena.ofConfined()) {
            var mt = meta != null ? a.allocateFrom(meta) : MemorySegment.NULL;
            return (long) MH_REPORT_INSERT.invokeExact(h, a.allocateFrom(timestamp), a.allocateFrom(report), mt);
        } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static MemorySegment report_list_recent(MemorySegment h, long limit) {
        try { return (MemorySegment) MH_REPORT_LIST_RECENT.invokeExact(h, limit); }
        catch (Throwable t) { throw new RuntimeException(t); }
    }

    private DbLibrary() {}
}
