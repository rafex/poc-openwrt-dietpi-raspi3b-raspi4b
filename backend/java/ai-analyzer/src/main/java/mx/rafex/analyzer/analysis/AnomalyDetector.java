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
 * Detección de anomalías usando desviación estándar (2σ).
 *
 * <p>Mantiene histórico de últimas 24h de consumo de bytes por dispositivo.
 * Detecta picos anómalos comparando contra la media y desviación estándar.
 */
public final class AnomalyDetector {

    private static final Logger LOG = Logger.getLogger(AnomalyDetector.class.getName());

    // Máximo de muestras (24h con granularidad de 1 min = 1440)
    private static final int MAX_HISTORY = 1440;

    // Mínimo de muestras para hacer estadísticas confiables
    private static final int MIN_SAMPLES = 10;

    // Umbrales de desviación estándar para detectar anomalías
    private static final double ANOMALY_SIGMA_THRESHOLD = 2.0;

    private final Map<String, Deque<Double>> byteHistoryByDevice = new ConcurrentHashMap<>();
    private final Map<String, Double> meanByDevice = new ConcurrentHashMap<>();
    private final Map<String, Double> stdDevByDevice = new ConcurrentHashMap<>();

    /**
     * Analiza bytes por segundo de un dispositivo y detecta anomalías.
     *
     * @param deviceIp IP del dispositivo
     * @param bytesPerSecond consumo de bytes por segundo
     * @return true si los bytes están fuera de 2σ (anomalía detectada)
     */
    public boolean isAnomaly(String deviceIp, double bytesPerSecond) {
        var history = byteHistoryByDevice.computeIfAbsent(deviceIp, k -> new LinkedList<>());

        // Agregar la muestra nueva
        history.addLast(bytesPerSecond);
        if (history.size() > MAX_HISTORY) {
            history.removeFirst();  // Mantener ventana deslizante de 24h
        }

        // Necesitamos mínimo de muestras para estadísticas confiables
        if (history.size() < MIN_SAMPLES) {
            return false;
        }

        // Calcular media
        double mean = history.stream()
            .mapToDouble(Double::doubleValue)
            .average()
            .orElse(0.0);

        // Calcular desviación estándar
        double variance = history.stream()
            .mapToDouble(d -> Math.pow(d - mean, 2))
            .average()
            .orElse(0.0);
        double stdDev = Math.sqrt(variance);

        // Guardar para referencia posterior
        meanByDevice.put(deviceIp, mean);
        stdDevByDevice.put(deviceIp, stdDev);

        // Detectar si está fuera de 2σ
        double zScore = Math.abs(bytesPerSecond - mean) / (stdDev > 0 ? stdDev : 1.0);
        return zScore > ANOMALY_SIGMA_THRESHOLD;
    }

    /**
     * Obtiene la media histórica para un dispositivo.
     */
    public double getMean(String deviceIp) {
        return meanByDevice.getOrDefault(deviceIp, 0.0);
    }

    /**
     * Obtiene la desviación estándar histórica para un dispositivo.
     */
    public double getStdDev(String deviceIp) {
        return stdDevByDevice.getOrDefault(deviceIp, 0.0);
    }

    /**
     * Obtiene el z-score para un valor dado.
     * Mide cuántas desviaciones estándar está alejado de la media.
     */
    public double getZScore(String deviceIp, double bytesPerSecond) {
        double mean = getMean(deviceIp);
        double stdDev = getStdDev(deviceIp);
        return stdDev > 0 ? Math.abs(bytesPerSecond - mean) / stdDev : 0.0;
    }

    /**
     * Genera descripción en español de la anomalía detectada.
     */
    public String describeAnomaly(String deviceIp, double bytesPerSecond) {
        double mean = getMean(deviceIp);
        double stdDev = getStdDev(deviceIp);
        double zScore = getZScore(deviceIp, bytesPerSecond);

        if (zScore <= ANOMALY_SIGMA_THRESHOLD) {
            return "";  // No es anomalía
        }

        double percentageAbove = ((bytesPerSecond - mean) / (mean > 0 ? mean : 1.0)) * 100;
        String mbCurrent = String.format("%.1f", bytesPerSecond / 1_000_000);
        String mbTypical = String.format("%.1f", mean / 1_000_000);

        return "Pico anómalo: " + mbCurrent + " MB/s (típico " + mbTypical + " MB/s, " +
               (percentageAbove > 0 ? "+" : "") + String.format("%.0f%%", percentageAbove) + ")";
    }

    /**
     * Obtiene el histórico completo de un dispositivo (útil para gráficos).
     */
    public List<Double> getHistory(String deviceIp) {
        var history = byteHistoryByDevice.get(deviceIp);
        return history != null ? new ArrayList<>(history) : new ArrayList<>();
    }

    /**
     * Limpia el histórico de un dispositivo (ej: después de cambio de contexto).
     */
    public void clearHistory(String deviceIp) {
        byteHistoryByDevice.remove(deviceIp);
        meanByDevice.remove(deviceIp);
        stdDevByDevice.remove(deviceIp);
    }
}
