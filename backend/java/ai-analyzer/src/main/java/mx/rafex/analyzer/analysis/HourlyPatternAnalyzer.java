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

import java.util.*;
import java.util.concurrent.ConcurrentHashMap;
import java.util.logging.Logger;

/**
 * Análisis de patrones horarios de consumo de ancho de banda.
 *
 * <p>Para cada dispositivo y cada hora (0-23), mantiene el consumo típico
 * de bytes. Permite detectar cambios de patrón y generar contexto para el LLM.
 */
public final class HourlyPatternAnalyzer {

    private static final Logger LOG = Logger.getLogger(HourlyPatternAnalyzer.class.getName());

    // Mapa: deviceIp → (hora → consumo promedio bytes)
    private final Map<String, Map<Integer, Double>> hourlyPatternsMap = new ConcurrentHashMap<>();

    // Factor de suavizado para media móvil exponencial (EMA)
    // Valores entre 0-1; 0.2 = 80% histórico + 20% nuevo dato
    private static final double SMOOTHING_FACTOR = 0.2;

    /**
     * Registra el consumo de bytes para una hora específica de un dispositivo.
     * Usa media móvil exponencial para actualizar el patrón típico.
     *
     * @param deviceIp IP del dispositivo
     * @param hour hora del día (0-23)
     * @param bytes bytes consumidos en este period de muestreo
     */
    public void recordConsumption(String deviceIp, int hour, double bytes) {
        var patterns = hourlyPatternsMap.computeIfAbsent(deviceIp, k -> new ConcurrentHashMap<>());

        // Obtener valor actual o inicializar a 0
        double current = patterns.getOrDefault(hour, 0.0);

        // Actualizar con media móvil exponencial
        double updated = (1 - SMOOTHING_FACTOR) * current + SMOOTHING_FACTOR * bytes;
        patterns.put(hour, updated);
    }

    /**
     * Obtiene el consumo típico esperado para un dispositivo a una hora dada.
     *
     * @param deviceIp IP del dispositivo
     * @param hour hora (0-23)
     * @return bytes típicos, o 0 si no hay histórico
     */
    public double getTypicalConsumption(String deviceIp, int hour) {
        var patterns = hourlyPatternsMap.get(deviceIp);
        if (patterns == null) return 0.0;
        return patterns.getOrDefault(hour, 0.0);
    }

    /**
     * Genera descripción en español del patrón horario y cambios detectados.
     *
     * @param deviceIp IP del dispositivo
     * @param hour hora actual (0-23)
     * @param bytes bytes actuales
     * @return descripción de patrón (vacío si es normal)
     */
    public String describePattern(String deviceIp, int hour, double bytes) {
        double typical = getTypicalConsumption(deviceIp, hour);

        // Si no tenemos histórico todavía, no hay nada que comparar
        if (typical == 0.0) {
            return "";
        }

        // Clasificar el patrón
        double ratio = bytes / typical;

        if (ratio > 3.0) {
            return "Consumo 3x mayor a la hora típica (" +
                   formatBytes(bytes) + " vs " + formatBytes(typical) + ")";
        } else if (ratio > 1.5) {
            return "Consumo 50% mayor a lo típico en esta hora";
        } else if (ratio < 0.3) {
            return "Consumo muy bajo comparado a patrón de esta hora";
        }

        return "";  // Patrón normal
    }

    /**
     * Obtiene todos los patrones horarios para un dispositivo (útil para gráficos).
     *
     * @param deviceIp IP del dispositivo
     * @return mapa hora → bytes típicos
     */
    public Map<Integer, Double> getFullPattern(String deviceIp) {
        var patterns = hourlyPatternsMap.get(deviceIp);
        return patterns != null ? new HashMap<>(patterns) : new HashMap<>();
    }

    /**
     * Identifica las horas pico (mayor consumo) para un dispositivo.
     *
     * @param deviceIp IP del dispositivo
     * @param topN número de horas pico a retornar
     * @return lista de horas (0-23) ordenadas por consumo descendente
     */
    public List<Integer> getPeakHours(String deviceIp, int topN) {
        var patterns = hourlyPatternsMap.get(deviceIp);
        if (patterns == null || patterns.isEmpty()) {
            return new ArrayList<>();
        }

        return patterns.entrySet().stream()
            .sorted((a, b) -> Double.compare(b.getValue(), a.getValue()))
            .limit(topN)
            .map(Map.Entry::getKey)
            .toList();
    }

    /**
     * Obtiene categoría del dispositivo basada en patrones horarios.
     * Útil para perfilado de dispositivos (p.ej: "usuario nocturno", "horas pico laborales").
     *
     * @param deviceIp IP del dispositivo
     * @return descripción del patrón de uso
     */
    public String categorizeUsagePattern(String deviceIp) {
        var patterns = hourlyPatternsMap.get(deviceIp);
        if (patterns == null || patterns.isEmpty()) {
            return "sin histórico";
        }

        var peakHours = getPeakHours(deviceIp, 3);
        if (peakHours.isEmpty()) {
            return "inactivo";
        }

        // Detectar si es usuario nocturno, laboral, etc.
        int morningHours = (int) peakHours.stream().filter(h -> h >= 6 && h < 12).count();
        int afternoonHours = (int) peakHours.stream().filter(h -> h >= 12 && h < 18).count();
        int nightHours = (int) peakHours.stream().filter(h -> h >= 18 || h < 6).count();

        if (nightHours >= 2) return "usuario nocturno";
        if (afternoonHours >= 2) return "usuario vespertino";
        if (morningHours >= 2) return "usuario matutino";
        return "consumo distribuido";
    }

    /**
     * Limpia el histórico de un dispositivo.
     */
    public void clearHistory(String deviceIp) {
        hourlyPatternsMap.remove(deviceIp);
    }

    // ── Utilidades ────────────────────────────────────────────────────────

    private static String formatBytes(double bytes) {
        if (bytes >= 1_000_000_000) {
            return String.format("%.1f GB", bytes / 1_000_000_000);
        } else if (bytes >= 1_000_000) {
            return String.format("%.1f MB", bytes / 1_000_000);
        } else if (bytes >= 1_000) {
            return String.format("%.1f KB", bytes / 1_000);
        }
        return String.format("%.0f B", bytes);
    }
}
