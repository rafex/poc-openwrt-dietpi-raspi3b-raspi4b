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

import java.lang.foreign.MemorySegment;
import java.lang.foreign.ValueLayout;
import java.util.logging.Logger;

/**
 * Capa de conveniencia sobre {@link DbLibrary}.
 *
 * <p>Maneja automáticamente:
 * <ul>
 *   <li>Leer la cadena UTF-8 del puntero Rust y liberarla con {@code db_free_string}.</li>
 *   <li>Traducir NULL a {@code null} Java.</li>
 *   <li>Logging de errores desde {@code db_last_error()}.</li>
 * </ul>
 *
 * <p>El handle SQLite {@link #handle} es válido para toda la vida del proceso.
 * Se obtiene con {@link #open(String)} y se cierra con {@link #close()}.
 */
public final class DatabaseClient implements AutoCloseable {

    private static final Logger LOG = Logger.getLogger(DatabaseClient.class.getName());

    private final MemorySegment handle;

    private DatabaseClient(MemorySegment handle) {
        this.handle = handle;
    }

    // ── Ciclo de vida ─────────────────────────────────────────────────────────

    /**
     * Abre (o crea) la base de datos en {@code path} y aplica el esquema DDL.
     *
     * @param path ruta absoluta, p.ej. "/data/sensor.db"
     * @throws RuntimeException si no se puede abrir
     */
    public static DatabaseClient open(String path) {
        var h = DbLibrary.db_open(path);
        if (h == null || h.equals(MemorySegment.NULL)) {
            var err = lastError();
            throw new RuntimeException("No se pudo abrir la base de datos %s: %s".formatted(path, err));
        }
        LOG.info("SQLite abierto: %s (SQLite %s)".formatted(path, sqliteVersion()));
        return new DatabaseClient(h);
    }

    @Override
    public void close() {
        DbLibrary.db_close(handle);
    }

    // ── Handle raw (para DbLibrary directo) ──────────────────────────────────

    public MemorySegment handle() { return handle; }

    // ── Utilidades ───────────────────────────────────────────────────────────

    /**
     * Lee la cadena UTF-8 a la que apunta {@code ptr} y libera la memoria Rust.
     *
     * <p>Si {@code ptr} es NULL devuelve {@code null}.
     *
     * @param ptr puntero devuelto por una función {@code db_*}
     * @return contenido como String Java, o {@code null}
     */
    public static String readAndFree(MemorySegment ptr) {
        if (ptr == null || ptr.equals(MemorySegment.NULL)) return null;
        try {
            // Reinterpretar como string nul-terminado
            var rebound = ptr.reinterpret(Integer.MAX_VALUE);
            // Buscar el terminador nul
            long len = 0;
            while (rebound.get(ValueLayout.JAVA_BYTE, len) != 0) len++;
            var bytes = rebound.asSlice(0, len).toArray(ValueLayout.JAVA_BYTE);
            return new String(bytes, java.nio.charset.StandardCharsets.UTF_8);
        } finally {
            DbLibrary.db_free_string(ptr);
        }
    }

    /**
     * Igual que {@link #readAndFree} pero devuelve {@code defaultVal} si el puntero es NULL.
     */
    public static String readAndFree(MemorySegment ptr, String defaultVal) {
        var s = readAndFree(ptr);
        return s != null ? s : defaultVal;
    }

    /** Lee el último error Rust del hilo actual (NO liberar el puntero). */
    public static String lastError() {
        var ptr = DbLibrary.db_last_error();
        if (ptr == null || ptr.equals(MemorySegment.NULL)) return "(sin error)";
        var rebound = ptr.reinterpret(Integer.MAX_VALUE);
        long len = 0;
        while (rebound.get(ValueLayout.JAVA_BYTE, len) != 0) len++;
        var bytes = rebound.asSlice(0, len).toArray(ValueLayout.JAVA_BYTE);
        return new String(bytes, java.nio.charset.StandardCharsets.UTF_8);
    }

    /** Versión de SQLite. */
    public static String sqliteVersion() {
        return readAndFree(DbLibrary.db_sqlite_version(), "?");
    }

    // ── Conveniences para las operaciones más frecuentes ─────────────────────
    // (delegan a DbLibrary con el handle de esta instancia)

    public long batchInsert(String receivedAt, String sensorIp, String payload) {
        var id = DbLibrary.batch_insert(handle, receivedAt, sensorIp, payload);
        if (id == 0) LOG.warning("batch_insert falló: " + lastError());
        return id;
    }

    public int batchSetStatus(long id, String status) {
        return DbLibrary.batch_set_status(handle, id, status);
    }

    public String batchGetPayload(long id) {
        return readAndFree(DbLibrary.batch_get_payload(handle, id));
    }

    public String batchListPending(long limit) {
        return readAndFree(DbLibrary.batch_list_pending(handle, limit), "[]");
    }

    public String batchListRecent(long limit) {
        return readAndFree(DbLibrary.batch_list_recent(handle, limit), "[]");
    }

    public long batchCount()        { return DbLibrary.batch_count(handle); }
    public long batchCountPending() { return DbLibrary.batch_count_pending(handle); }

    public long analysisInsert(long batchId, String ts, String risk, String analysis,
                               double elapsedS, long suspCount, long packets, String bytesFmt) {
        return DbLibrary.analysis_insert(handle, batchId, ts, risk, analysis, elapsedS, suspCount, packets, bytesFmt);
    }

    public String analysisListRecent(long limit) {
        return readAndFree(DbLibrary.analysis_list_recent(handle, limit), "[]");
    }

    public String analysisGetByBatch(long batchId) {
        return readAndFree(DbLibrary.analysis_get_by_batch(handle, batchId));
    }

    public long analysisCount()        { return DbLibrary.analysis_count(handle); }

    public String analysisCountByRisk() {
        return readAndFree(DbLibrary.analysis_count_by_risk(handle), "{}");
    }

    public long alertInsert(long batchId, String ts, String severity, String alertType,
                            String message, String sourceIp, String domain, String meta) {
        return DbLibrary.alert_insert(handle, batchId, ts, severity, alertType, message, sourceIp, domain, meta);
    }

    public String alertListRecent(long limit) {
        return readAndFree(DbLibrary.alert_list_recent(handle, limit), "[]");
    }

    public String alertCountBySeverity() {
        return readAndFree(DbLibrary.alert_count_by_severity(handle), "{}");
    }

    public long chatSessionUpsert(String sessionId, String nowIso) {
        return DbLibrary.chat_session_upsert(handle, sessionId, nowIso);
    }

    public long chatMessageInsert(String sessionId, String ts, String role, String content, String meta) {
        return DbLibrary.chat_message_insert(handle, sessionId, ts, role, content, meta);
    }

    public String chatMessageHistory(String sessionId, long limit) {
        return readAndFree(DbLibrary.chat_message_history(handle, sessionId, limit), "[]");
    }

    public long chatSessionClear(String sessionId) {
        return DbLibrary.chat_session_clear(handle, sessionId);
    }

    public String chatMessageListAll(long limit) {
        return readAndFree(DbLibrary.chat_message_list_all(handle, limit), "[]");
    }

    public String ruleGet(String key) {
        return readAndFree(DbLibrary.rule_get(handle, key));
    }

    public long ruleUpsert(String key, String value, String updatedAt) {
        return DbLibrary.rule_upsert(handle, key, value, updatedAt);
    }

    public long domainCategoryUpsert(String domain, String category, double confidence,
                                     String source, String updatedAt) {
        return DbLibrary.domain_category_upsert(handle, domain, category, confidence, source, updatedAt);
    }

    public String domainCategoryGet(String domain) {
        return readAndFree(DbLibrary.domain_category_get(handle, domain));
    }

    public String domainCategoryList() {
        return readAndFree(DbLibrary.domain_category_list(handle), "[]");
    }

    public long whitelistContains(String domain) {
        return DbLibrary.whitelist_contains(handle, domain);
    }

    public long whitelistAdd(String domain, String reason, String createdAt) {
        return DbLibrary.whitelist_add(handle, domain, reason, createdAt);
    }

    public long whitelistRemove(String domain) {
        return DbLibrary.whitelist_remove(handle, domain);
    }

    public String whitelistList() {
        return readAndFree(DbLibrary.whitelist_list(handle), "[]");
    }

    public long deviceProfileUpsert(String ip, String deviceType, double confidence,
                                    String reasons, String updatedAt) {
        return DbLibrary.device_profile_upsert(handle, ip, deviceType, confidence, reasons, updatedAt);
    }

    public String deviceProfileList() {
        return readAndFree(DbLibrary.device_profile_list(handle), "[]");
    }

    public long policyActionInsert(String ts, String action, String reason, String details) {
        return DbLibrary.policy_action_insert(handle, ts, action, reason, details);
    }

    public String policyActionListRecent(long limit) {
        return readAndFree(DbLibrary.policy_action_list_recent(handle, limit), "[]");
    }

    public long promptLogInsert(String ts, long batchId, String promptType,
                                String prompt, String response, String meta) {
        return DbLibrary.prompt_log_insert(handle, ts, batchId, promptType, prompt, response, meta);
    }

    public long humanExplanationInsert(long batchId, String ts, String text, String meta) {
        return DbLibrary.human_explanation_insert(handle, batchId, ts, text, meta);
    }

    public String humanExplanationGetByBatch(long batchId) {
        return readAndFree(DbLibrary.human_explanation_get_by_batch(handle, batchId));
    }

    public long summaryInsert(String ts, String summary, String meta) {
        return DbLibrary.summary_insert(handle, ts, summary, meta);
    }

    public String summaryListRecent(long limit) {
        return readAndFree(DbLibrary.summary_list_recent(handle, limit), "[]");
    }

    public long reportInsert(String ts, String report, String meta) {
        return DbLibrary.report_insert(handle, ts, report, meta);
    }

    public String reportListRecent(long limit) {
        return readAndFree(DbLibrary.report_list_recent(handle, limit), "[]");
    }
}
