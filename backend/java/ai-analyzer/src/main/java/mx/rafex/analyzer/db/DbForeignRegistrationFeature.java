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

import java.lang.foreign.AddressLayout;
import java.lang.foreign.FunctionDescriptor;
import java.lang.foreign.ValueLayout;

import org.graalvm.nativeimage.hosted.Feature;
import org.graalvm.nativeimage.hosted.RuntimeForeignAccess;

/**
 * Registra en build-time todos los FunctionDescriptor usados por DbLibrary.
 *
 * <p>GraalVM 25 exige este registro para permitir downcalls FFM en runtime.
 */
public final class DbForeignRegistrationFeature implements Feature {

    private static final ValueLayout.OfLong   C_LONG   = ValueLayout.JAVA_LONG;
    private static final ValueLayout.OfInt    C_INT    = ValueLayout.JAVA_INT;
    private static final ValueLayout.OfDouble C_DOUBLE = ValueLayout.JAVA_DOUBLE;
    private static final AddressLayout        C_PTR    = ValueLayout.ADDRESS;

    @Override
    public void duringSetup(DuringSetupAccess access) {
        registerDowncalls();
    }

    private static void registerDowncalls() {
        RuntimeForeignAccess.registerForDowncall(FunctionDescriptor.of(C_PTR, C_PTR));
        RuntimeForeignAccess.registerForDowncall(FunctionDescriptor.ofVoid(C_PTR));
        RuntimeForeignAccess.registerForDowncall(FunctionDescriptor.of(C_LONG, C_PTR));
        RuntimeForeignAccess.registerForDowncall(FunctionDescriptor.of(C_PTR));
        RuntimeForeignAccess.registerForDowncall(FunctionDescriptor.of(C_LONG, C_PTR, C_PTR, C_PTR, C_PTR));
        RuntimeForeignAccess.registerForDowncall(FunctionDescriptor.of(C_INT, C_PTR, C_LONG, C_PTR));
        RuntimeForeignAccess.registerForDowncall(FunctionDescriptor.of(C_PTR, C_PTR, C_LONG));
        RuntimeForeignAccess.registerForDowncall(FunctionDescriptor.of(C_LONG, C_PTR, C_PTR));
        RuntimeForeignAccess.registerForDowncall(FunctionDescriptor.of(C_LONG, C_PTR, C_LONG, C_PTR, C_PTR, C_PTR, C_DOUBLE, C_LONG, C_LONG, C_PTR));
        RuntimeForeignAccess.registerForDowncall(FunctionDescriptor.of(C_LONG, C_PTR, C_LONG, C_PTR, C_PTR, C_PTR, C_PTR, C_PTR, C_PTR, C_PTR));
        RuntimeForeignAccess.registerForDowncall(FunctionDescriptor.of(C_PTR, C_PTR, C_PTR, C_LONG));
        RuntimeForeignAccess.registerForDowncall(FunctionDescriptor.of(C_LONG, C_PTR, C_PTR, C_PTR));
        RuntimeForeignAccess.registerForDowncall(FunctionDescriptor.of(C_LONG, C_PTR, C_PTR, C_PTR, C_PTR, C_PTR, C_PTR));
        RuntimeForeignAccess.registerForDowncall(FunctionDescriptor.of(C_PTR, C_PTR, C_PTR));
        RuntimeForeignAccess.registerForDowncall(FunctionDescriptor.of(C_LONG, C_PTR, C_PTR, C_PTR, C_DOUBLE, C_PTR, C_PTR));
        RuntimeForeignAccess.registerForDowncall(FunctionDescriptor.of(C_LONG, C_PTR, C_PTR, C_PTR, C_PTR, C_PTR));
        RuntimeForeignAccess.registerForDowncall(FunctionDescriptor.of(C_LONG, C_PTR, C_PTR, C_LONG, C_PTR, C_PTR, C_PTR, C_PTR));
        RuntimeForeignAccess.registerForDowncall(FunctionDescriptor.of(C_LONG, C_PTR, C_LONG, C_PTR, C_PTR, C_PTR));

        // ── OSINT (Fase 5 — añadidos al actualizar osint_enrichments) ─────────────
        // osint_insert(handle, alert_id, batch_id, target, target_type, source,
        //              phomber_raw, bing_raw, llm_result, risk, summary_es,
        //              queried_at, expires_at) → i64
        // GraalVM 25 / aarch64 computa este descriptor como (long×14)long — registrar
        // el descriptor exacto usado en DbLibrary para que el leaf-type coincida.
        RuntimeForeignAccess.registerForDowncall(FunctionDescriptor.of(C_LONG, C_PTR, C_LONG, C_LONG,
            C_PTR, C_PTR, C_PTR, C_PTR, C_PTR, C_PTR, C_PTR, C_PTR, C_PTR, C_PTR));

        // osint_is_cached(handle, target, source, now_iso) → i64
        // Ya cubierto por: FunctionDescriptor.of(C_LONG, C_PTR, C_PTR, C_PTR, C_PTR)

        // osint_list_recent(handle, limit) → *c_char
        // Ya cubierto por: FunctionDescriptor.of(C_PTR, C_PTR, C_LONG)

        // osint_get_detail(handle, id) → *c_char
        // Ya cubierto por: FunctionDescriptor.of(C_PTR, C_PTR, C_LONG)

        // osint_pending_alerts(handle, min_severity, now_iso, limit) → *c_char
        // Nuevo: 3×C_PTR + C_LONG como params, retorna C_PTR
        RuntimeForeignAccess.registerForDowncall(FunctionDescriptor.of(C_PTR, C_PTR, C_PTR, C_PTR, C_LONG));
    }
}
