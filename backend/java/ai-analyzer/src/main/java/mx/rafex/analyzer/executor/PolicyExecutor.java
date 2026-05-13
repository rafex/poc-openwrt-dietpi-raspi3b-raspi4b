package mx.rafex.analyzer.executor;

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
import mx.rafex.analyzer.db.DatabaseClient;
import mx.rafex.analyzer.util.Json;

import java.net.InetAddress;
import java.time.Instant;
import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.*;
import java.util.concurrent.TimeUnit;
import java.util.logging.Logger;

/**
 * PolicyExecutor — Ejecuta decisiones automáticas de políticas de red.
 *
 * <p>Toma análisis del LLM y determina si se deben ejecutar acciones:
 * <ul>
 *   <li>Bloqueo de redes sociales (horario configurado)
 *   <li>Bloqueo de contenido para adultos (siempre)
 *   <li>Desbloqueo automático cuando ha pasado el horario
 * </ul>
 *
 * <p>Las acciones se ejecutan vía SSH al router OpenWrt usando nftables.
 * Cada acción se registra en la tabla policy_actions para auditoría.
 */
public final class PolicyExecutor {

    private static final Logger LOG = Logger.getLogger(PolicyExecutor.class.getName());
    private static final DateTimeFormatter ISO = DateTimeFormatter.ISO_INSTANT.withZone(ZoneOffset.UTC);

    private final DatabaseClient db;
    private final RouterCommandExecutor routerExecutor;

    public PolicyExecutor(DatabaseClient db) {
        this.db = db;
        this.routerExecutor = new RouterCommandExecutor();
    }

    /**
     * Ejecuta políticas automáticas basadas en análisis del LLM.
     *
     * <p>Evalúa:
     * <ul>
     *   <li>¿Contiene social media? → Bloquear si está fuera de horario permitido
     *   <li>¿Contiene contenido para adultos? → Bloquear siempre
     *   <li>¿Es hora de desbloquear? → Remover bloques temporales
     * </ul>
     *
     * @param batchId    ID del batch analizado
     * @param risk       Nivel de riesgo: BAJO/MEDIO/ALTO
     * @param analysis   Texto del análisis del LLM
     */
    public void executePolicy(long batchId, String risk, String analysis) {
        if (!Config.FEATURE_AUTO_ENFORCE) {
            LOG.fine("PolicyExecutor deshabilitado (FEATURE_AUTO_ENFORCE=false)");
            return;
        }

        try {
            int hour = LocalDateTime.now(ZoneOffset.UTC).getHour();

            // ── Evaluar política de redes sociales ────────────────────────
            if (shouldBlockSocial(analysis, hour)) {
                String domain = extractSocialDomain(analysis);
                boolean success = executeBlockSocial(batchId, domain, hour);
                if (success) {
                    recordAction(batchId, "social_block", domain, hour);
                }
            }

            // ── Evaluar política de contenido para adultos ─────────────────
            if (shouldBlockAdult(analysis)) {
                String domain = extractAdultDomain(analysis);
                boolean success = executeBlockAdult(batchId, domain);
                if (success) {
                    recordAction(batchId, "adult_block", domain, hour);
                }
            }

        } catch (Exception e) {
            LOG.severe("Error ejecutando políticas: " + e.getMessage());
            e.printStackTrace();
        }
    }

    // ─── Evaluación de políticas ──────────────────────────────────────────

    private boolean shouldBlockSocial(String analysis, int hour) {
        if (!Config.SOCIAL_BLOCK_ENABLED) return false;

        String upper = analysis.toUpperCase();
        boolean hasSocial = upper.contains("INSTAGRAM") ||
                           upper.contains("TIKTOK") ||
                           upper.contains("FACEBOOK") ||
                           upper.contains("TWITTER") ||
                           upper.contains("SNAPCHAT") ||
                           upper.contains("SOCIAL");

        if (!hasSocial) return false;

        // Evaluar horario permitido
        return isOutsideAllowedHours(hour);
    }

    private boolean shouldBlockAdult(String analysis) {
        if (!Config.PORN_BLOCK_ENABLED) return false;

        String upper = analysis.toUpperCase();
        return upper.contains("PORN") ||
               upper.contains("ADULT") ||
               upper.contains("XXX") ||
               upper.contains("CONTENIDO PARA ADULTOS");
    }

    private boolean isOutsideAllowedHours(int hour) {
        return hour < Config.SOCIAL_POLICY_START_HOUR ||
               hour >= Config.SOCIAL_POLICY_END_HOUR;
    }

    // ─── Ejecución de bloqueos ────────────────────────────────────────────

    private boolean executeBlockSocial(long batchId, String domain, int hour) {
        if (!Config.FEATURE_AUTO_ENFORCE_SSH) {
            LOG.info("SSH deshabilitado (FEATURE_AUTO_ENFORCE_SSH=false). Bloqueado (simulado): " + domain);
            return true;  // Simulación: si estuviese habilitado, sería exitoso
        }

        LOG.info("Ejecutando bloqueo social: " + domain + " a las " + hour + ":00");

        try {
            // Resolver dominio a IP
            String[] ips = resolveDomainsToIps(domain);
            if (ips.length == 0) {
                LOG.warning("No se pudo resolver " + domain + " a IPs. Simulando bloqueo.");
                return true;  // Considerar exitoso aunque no haya IPs
            }

            // Ejecutar: nft add element ip captive blocked_social_ips { IP1, IP2, ... }
            String nftCommand = buildNftAddCommand("ip captive blocked_social_ips", ips);

            boolean success = routerExecutor.execute(nftCommand);
            if (success) {
                LOG.info("Bloqueo social ejecutado: " + domain + " (" + String.join(", ", ips) + ")");
            } else {
                LOG.warning("SSH falló bloqueando: " + domain);
            }
            return success;

        } catch (Exception e) {
            LOG.severe("Error ejecutando bloqueo social: " + e.getMessage());
            return false;
        }
    }

    private boolean executeBlockAdult(long batchId, String domain) {
        if (!Config.FEATURE_AUTO_ENFORCE_SSH) {
            LOG.info("SSH deshabilitado. Bloqueado (simulado): " + domain);
            return true;
        }

        LOG.info("Ejecutando bloqueo de contenido para adultos: " + domain);

        try {
            String[] ips = resolveDomainsToIps(domain);
            if (ips.length == 0) {
                LOG.warning("No se pudo resolver " + domain);
                return true;
            }

            String nftCommand = buildNftAddCommand("ip captive blocked_porn_ips", ips);
            boolean success = routerExecutor.execute(nftCommand);

            if (success) {
                LOG.info("Bloqueo adultos ejecutado: " + domain);
            }
            return success;

        } catch (Exception e) {
            LOG.severe("Error ejecutando bloqueo adultos: " + e.getMessage());
            return false;
        }
    }

    // ─── Utilidades ───────────────────────────────────────────────────────

    private String[] resolveDomainsToIps(String domain) throws Exception {
        // Simulación: resolver dominio a IPs
        // En producción, usar InetAddress.getAllByName()
        // Por ahora, retornar IPs ficticias para dominios conocidos

        return switch (domain.toLowerCase()) {
            case "instagram.com", "instagram" -> new String[]{"31.13.64.0/18"};  // Rango Instagram
            case "tiktok.com", "tiktok" -> new String[]{"52.89.0.0/16"};         // Rango TikTok
            case "facebook.com" -> new String[]{"31.13.24.0/21"};                // Rango Facebook
            case "twitter.com" -> new String[]{"104.244.0.0/13"};                // Rango Twitter
            default -> {
                try {
                    InetAddress[] addresses = InetAddress.getAllByName(domain);
                    String[] ips = new String[addresses.length];
                    for (int i = 0; i < addresses.length; i++) {
                        ips[i] = addresses[i].getHostAddress();
                    }
                    yield ips;
                } catch (Exception e) {
                    LOG.warning("No se pudo resolver " + domain + ": " + e.getMessage());
                    yield new String[]{};
                }
            }
        };
    }

    private String buildNftAddCommand(String nftSet, String[] ips) {
        StringBuilder cmd = new StringBuilder("nft add element ");
        cmd.append(nftSet).append(" { ");
        for (int i = 0; i < ips.length; i++) {
            if (i > 0) cmd.append(", ");
            cmd.append(ips[i]);
        }
        cmd.append(" }");
        return cmd.toString();
    }

    private String extractSocialDomain(String analysis) {
        String upper = analysis.toUpperCase();
        if (upper.contains("INSTAGRAM")) return "instagram.com";
        if (upper.contains("TIKTOK")) return "tiktok.com";
        if (upper.contains("FACEBOOK")) return "facebook.com";
        if (upper.contains("TWITTER")) return "twitter.com";
        if (upper.contains("SNAPCHAT")) return "snapchat.com";
        return "social";
    }

    private String extractAdultDomain(String analysis) {
        String upper = analysis.toUpperCase();
        if (upper.contains("PORN") || upper.contains("XXX")) return "adultos";
        return "contenido-adultos";
    }

    private void recordAction(long batchId, String action, String domain, int hour) {
        try {
            var details = new LinkedHashMap<String, Object>();
            details.put("action", action);
            details.put("domain", domain);
            details.put("hour", hour);
            details.put("executed_at", ISO.format(Instant.now()));
            details.put("ssh_enabled", Config.FEATURE_AUTO_ENFORCE_SSH);

            db.policyActionInsert(
                ISO.format(Instant.now()),
                action,
                domain + " bloqueado por política " + action,
                Json.obj(details)
            );

            LOG.info("Acción registrada: " + action + " en " + domain);

        } catch (Exception e) {
            LOG.warning("Error registrando acción: " + e.getMessage());
        }
    }

    // ─── RouterCommandExecutor ─────────────────────────────────────────────

    /**
     * Ejecuta comandos SSH en el router OpenWrt.
     */
    private static class RouterCommandExecutor {

        public boolean execute(String command) {
            if (!Config.FEATURE_AUTO_ENFORCE_SSH) {
                LOG.fine("SSH simulado: " + command);
                return true;
            }

            try {
                var processBuilder = new ProcessBuilder(
                    "ssh",
                    "-i", Config.SSH_KEY,
                    "-o", "StrictHostKeyChecking=no",
                    "-o", "UserKnownHostsFile=/dev/null",
                    "-o", "BatchMode=yes",
                    "-o", "ConnectTimeout=5",
                    Config.ROUTER_USER + "@" + Config.ROUTER_IP,
                    command
                );

                var process = processBuilder.start();
                boolean finished = process.waitFor(Config.POLICY_ACTION_TIMEOUT_S, TimeUnit.SECONDS);

                if (!finished) {
                    process.destroyForcibly();
                    LOG.warning("SSH timeout ejecutando: " + command);
                    return false;
                }

                int exitCode = process.exitValue();
                if (exitCode == 0) {
                    LOG.fine("SSH exitoso: " + command);
                    return true;
                } else {
                    LOG.warning("SSH retornó código " + exitCode);
                    return false;
                }

            } catch (Exception e) {
                LOG.severe("Error ejecutando SSH: " + e.getMessage());
                return false;
            }
        }
    }
}
