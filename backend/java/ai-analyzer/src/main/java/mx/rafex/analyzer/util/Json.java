package mx.rafex.analyzer.util;

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

import java.util.List;
import java.util.Map;

/**
 * Minimal JSON builder y parser — sin librerías externas.
 *
 * <p>No intenta ser un parser JSON completo.  Solo maneja los casos que
 * necesita ai-analyzer:
 * <ul>
 *   <li>Construir objetos y arrays JSON para respuestas HTTP.</li>
 *   <li>Extraer valores de primer nivel de un objeto JSON simple.</li>
 *   <li>Escapar strings.</li>
 * </ul>
 *
 * <p>Los strings JSON que vienen de Rust (db-lib) se pasan casi siempre
 * sin parsear — se reenvían directamente al cliente HTTP.
 */
public final class Json {

    // ── Builder ────────────────────────────────────────────────────────────────

    /** Escapa un String para incluirlo en JSON. */
    public static String escape(String s) {
        if (s == null) return "null";
        var sb = new StringBuilder(s.length() + 8);
        sb.append('"');
        for (char c : s.toCharArray()) {
            switch (c) {
                case '"'  -> sb.append("\\\"");
                case '\\' -> sb.append("\\\\");
                case '\n' -> sb.append("\\n");
                case '\r' -> sb.append("\\r");
                case '\t' -> sb.append("\\t");
                default -> {
                    if (c < 0x20) sb.append(String.format("\\u%04x", (int) c));
                    else          sb.append(c);
                }
            }
        }
        sb.append('"');
        return sb.toString();
    }

    /**
     * Serializa un Map&lt;String,Object&gt; a JSON object string.
     *
     * <p>Valores soportados: String, Number, Boolean, null, Map, List,
     * y cualquier objeto cuyo toString() sea JSON ya serializado
     * (convención: si empieza por '{' o '[' se inserta raw).
     */
    public static String obj(Map<String, Object> map) {
        var sb = new StringBuilder("{");
        boolean first = true;
        for (var e : map.entrySet()) {
            if (!first) sb.append(',');
            first = false;
            sb.append(escape(e.getKey())).append(':').append(val(e.getValue()));
        }
        sb.append('}');
        return sb.toString();
    }

    /** Serializa una List a JSON array. */
    public static String arr(List<?> list) {
        var sb = new StringBuilder("[");
        boolean first = true;
        for (var item : list) {
            if (!first) sb.append(',');
            first = false;
            sb.append(val(item));
        }
        sb.append(']');
        return sb.toString();
    }

    @SuppressWarnings("unchecked")
    private static String val(Object v) {
        if (v == null)                return "null";
        if (v instanceof Boolean b)   return b.toString();
        if (v instanceof Number n)    return n.toString();
        if (v instanceof Map<?,?> m)  return obj((Map<String,Object>) m);
        if (v instanceof List<?> l)   return arr(l);
        var s = v.toString();
        // Si ya es JSON crudo (de Rust), insertar directamente
        if ((s.startsWith("{") && s.endsWith("}")) ||
            (s.startsWith("[") && s.endsWith("]"))) {
            return s;
        }
        return escape(s);
    }

    // ── Parser mínimo ─────────────────────────────────────────────────────────

    /**
     * Extrae el valor de una clave de primer nivel de un objeto JSON simple.
     *
     * <p>Solo maneja valores string y número en el primer nivel.
     * Suficiente para parsear las peticiones entrantes del sensor y el chat.
     *
     * @return valor como String (sin comillas si es string JSON), o null si no existe
     */
    public static String extractString(String json, String key) {
        if (json == null || json.isBlank()) return null;
        // Busca  "key":"value"  o  "key": "value"
        String searchKey = "\"" + key + "\"";
        int ki = json.indexOf(searchKey);
        if (ki < 0) return null;
        int colon = json.indexOf(':', ki + searchKey.length());
        if (colon < 0) return null;
        // Saltar espacios
        int vi = colon + 1;
        while (vi < json.length() && json.charAt(vi) == ' ') vi++;
        if (vi >= json.length()) return null;

        char first = json.charAt(vi);
        if (first == '"') {
            // string value
            int end = vi + 1;
            while (end < json.length()) {
                if (json.charAt(end) == '\\') { end += 2; continue; }
                if (json.charAt(end) == '"')  { break; }
                end++;
            }
            return json.substring(vi + 1, end);
        } else {
            // número, booleano o null
            int end = vi;
            while (end < json.length() && ",}\n\r ".indexOf(json.charAt(end)) < 0) end++;
            return json.substring(vi, end).trim();
        }
    }

    /** Devuelve el JSON completo de un campo cuyo valor es un objeto o array. */
    public static String extractRaw(String json, String key) {
        if (json == null || json.isBlank()) return null;
        String searchKey = "\"" + key + "\"";
        int ki = json.indexOf(searchKey);
        if (ki < 0) return null;
        int colon = json.indexOf(':', ki + searchKey.length());
        if (colon < 0) return null;
        int vi = colon + 1;
        while (vi < json.length() && json.charAt(vi) == ' ') vi++;
        if (vi >= json.length()) return null;
        char open = json.charAt(vi);
        char close = open == '{' ? '}' : (open == '[' ? ']' : 0);
        if (close == 0) return extractString(json, key);
        int depth = 0, end = vi;
        while (end < json.length()) {
            char c = json.charAt(end);
            if (c == open)  depth++;
            if (c == close) { depth--; if (depth == 0) { end++; break; } }
            end++;
        }
        return json.substring(vi, end);
    }

    // ── Respuestas rápidas ────────────────────────────────────────────────────

    /** Construye {"error": "..."} */
    public static String error(String msg) {
        return "{\"error\":" + escape(msg) + "}";
    }

    /** Construye {"ok": true, "message": "..."} */
    public static String ok(String msg) {
        return "{\"ok\":true,\"message\":" + escape(msg) + "}";
    }

    private Json() {}
}
