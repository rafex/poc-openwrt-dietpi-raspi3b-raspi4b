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

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.Set;
import java.util.concurrent.TimeUnit;
import java.util.logging.Logger;
import java.util.regex.Pattern;

/**
 * Ejecuta PHOMBER como subprocess, piping comandos a stdin.
 *
 * <p>PHOMBER es una herramienta OSINT interactiva (Python, CLI).
 * Protocolo de uso:
 * <pre>
 *   stdin  → "{command} {target}\nexit\n"
 *   stdout ← tablas ASCII con información de la herramienta
 * </pre>
 *
 * <p>El stdout se devuelve limpio de códigos ANSI para que el LLM lo lea
 * directamente. No hace falta un parser — el LLM entiende las tablas ASCII
 * perfectamente.
 *
 * <p>Prefijos de IPs privadas nunca se consultan a APIs externas.
 */
public final class PhomberRunner {

    private static final Logger LOG = Logger.getLogger(PhomberRunner.class.getName());

    /** Regex para eliminar secuencias de escape ANSI del stdout de PHOMBER. */
    private static final Pattern ANSI_RE =
        Pattern.compile("(?:[@-Z\\\\-_]|\\[[0-?]*[ -/]*[@-~])");

    /** Comandos soportados por PHOMBER. */
    private static final Set<String> SUPPORTED = Set.of("ip", "mac", "whois", "dns");

    /** Prefijos de IPs privadas — no consultar a APIs externas. */
    private static final String[] LAN_PREFIXES = {
        "10.", "172.16.", "172.17.", "172.18.", "172.19.", "172.20.",
        "172.21.", "172.22.", "172.23.", "172.24.", "172.25.", "172.26.",
        "172.27.", "172.28.", "172.29.", "172.30.", "172.31.",
        "192.168.", "127.", "169.254.", "::1", "fc", "fd"
    };

    private final int timeoutS;
    private final boolean available;

    public PhomberRunner() {
        this.timeoutS = Config.PHOMBER_TIMEOUT_S;
        this.available = detect();
    }

    /** Devuelve {@code true} si PHOMBER está disponible en el sistema. */
    public boolean isAvailable() { return available; }

    /**
     * Ejecuta un comando PHOMBER para el target dado.
     *
     * @param command "ip" | "mac" | "whois" | "dns"
     * @param target  IP, MAC o dominio objetivo
     * @return stdout limpio de ANSI, o mensaje de error entre corchetes
     */
    public String run(String command, String target) {
        if (!SUPPORTED.contains(command)) {
            return "[Error] Comando no soportado: " + command;
        }
        if (!available) {
            return "[Error] PHOMBER no disponible — instala con: pip install phomber";
        }
        LOG.fine("PHOMBER %s %s".formatted(command, target));

        try {
            var pb = new ProcessBuilder("phomber")
                .redirectErrorStream(false);
            var proc = pb.start();

            // Enviar comando a stdin y cerrar para que PHOMBER sepa que terminamos
            var stdin = proc.getOutputStream();
            stdin.write(("%s %s\nexit\n".formatted(command, target))
                .getBytes(StandardCharsets.UTF_8));
            stdin.flush();
            stdin.close();

            // Leer stdout completo
            var rawBytes = proc.getInputStream().readAllBytes();
            var rawText  = new String(rawBytes, StandardCharsets.UTF_8);

            // Esperar que termine (con timeout)
            boolean finished = proc.waitFor(timeoutS, TimeUnit.SECONDS);
            if (!finished) {
                proc.destroyForcibly();
                LOG.warning("PHOMBER timeout %s %s (%ds)".formatted(command, target, timeoutS));
                return "[Timeout] phomber %s %s excedió %ds".formatted(command, target, timeoutS);
            }

            var clean = stripAnsi(rawText).strip();
            return clean.isEmpty()
                ? "[Sin output de PHOMBER para %s %s]".formatted(command, target)
                : clean;

        } catch (IOException e) {
            LOG.warning("PHOMBER I/O error: " + e.getMessage());
            return "[Error] phomber %s %s: %s".formatted(command, target, e.getMessage());
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return "[Error] phomber interrumpido";
        }
    }

    // ── Métodos de alto nivel ─────────────────────────────────────────────────

    /** Lookup de IP pública (geoloc, ASN, reputación). */
    public String scanIp(String ip) {
        if (isPrivateOrProtected(ip)) return "[Omitido] %s es IP privada/protegida".formatted(ip);
        return run("ip", ip);
    }

    /** Lookup de proveedor MAC (OUI database). */
    public String scanMac(String mac) { return run("mac", mac); }

    /** Consulta WHOIS de dominio (registrador, fechas, país). */
    public String scanWhois(String domain) { return run("whois", domain); }

    /** Resolución DNS inversa / registros A, MX, TXT, NS. */
    public String scanDns(String target) { return run("dns", target); }

    // ── Helpers ───────────────────────────────────────────────────────────────

    public static boolean isPrivateOrProtected(String ip) {
        if (ip == null || ip.isBlank()) return true;
        if (Config.PROTECTED_IPS.contains(ip)) return true;
        for (var prefix : LAN_PREFIXES) {
            if (ip.startsWith(prefix)) return true;
        }
        return false;
    }

    private static String stripAnsi(String text) {
        return ANSI_RE.matcher(text).replaceAll("");
    }

    private static boolean detect() {
        try {
            var proc = new ProcessBuilder("phomber", "--version")
                .redirectErrorStream(true)
                .start();
            proc.waitFor(5, TimeUnit.SECONDS);
            LOG.info("PHOMBER detectado");
            return true;
        } catch (Exception ignored) {}
        LOG.warning("PHOMBER no encontrado — instala con: pip install phomber");
        return false;
    }
}
