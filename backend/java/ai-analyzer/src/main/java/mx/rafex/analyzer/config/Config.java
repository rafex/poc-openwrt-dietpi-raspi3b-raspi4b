package mx.rafex.analyzer.config;

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

import java.util.Set;
import java.util.LinkedHashSet;

/**
 * Configuración leída exclusivamente de variables de entorno (sin ninguna
 * librería externa — solo System.getenv).
 *
 * Equivalente al bloque de constantes al inicio de analyzer.py.
 */
public final class Config {

    // ── MQTT ─────────────────────────────────────────────────────────────────
    public static final String MQTT_HOST  = env("MQTT_HOST",  "192.168.1.167");
    public static final int    MQTT_PORT  = intEnv("MQTT_PORT", 1883);
    public static final String MQTT_TOPIC = env("MQTT_TOPIC", "rafexpi/sensor/batch");

    // ── Base de datos ─────────────────────────────────────────────────────────
    public static final String DB_PATH = env("DB_PATH", "/data/sensor.db");

    // ── llama.cpp ─────────────────────────────────────────────────────────────
    public static final String LLAMA_URL    = env("LLAMA_URL",    "http://192.168.1.167:8081");
    public static final int    N_PREDICT    = intEnv("N_PREDICT",    256);
    public static final String MODEL_FORMAT = env("MODEL_FORMAT", "tinyllama");

    // ── Groq ──────────────────────────────────────────────────────────────────
    public static final String  GROQ_API_KEY      = env("GROQ_API_KEY", "");
    public static final String  GROQ_MODEL        = env("GROQ_MODEL",   "qwen/qwen3-32b");
    public static final boolean GROQ_CHAT_ENABLED  = !GROQ_API_KEY.isBlank();
    public static final String  GROQ_API_URL      = "https://api.groq.com/openai/v1/chat/completions";
    public static final int     GROQ_MAX_TOKENS   = intEnv("GROQ_MAX_TOKENS", 1024);
    public static final int     GROQ_TIMEOUT_S    = intEnv("GROQ_TIMEOUT_S",  30);

    // ── Red e infraestructura ─────────────────────────────────────────────────
    public static final int    PORT            = intEnv("PORT", 5000);
    public static final String ROUTER_IP       = env("ROUTER_IP",       "192.168.1.1");
    public static final String ROUTER_USER     = env("ROUTER_USER",     "root");
    public static final String SSH_KEY         = env("SSH_KEY",         "/opt/keys/captive-portal");
    public static final String PORTAL_IP       = env("PORTAL_IP",       "192.168.1.167");
    public static final String ADMIN_IP        = env("ADMIN_IP",        "192.168.1.113");
    public static final String RASPI4B_IP      = env("RASPI4B_IP",      "192.168.1.167");
    public static final String RASPI3B_IP      = env("RASPI3B_IP",      "192.168.1.181");
    public static final String PORTAL_NODE_IP  = env("PORTAL_NODE_IP",  "192.168.1.182");
    public static final String AP_EXTENDER_IP  = env("AP_EXTENDER_IP",  "192.168.1.183");

    /** IPs que NUNCA deben bloquearse — misma lógica que PROTECTED_IPS en Python. */
    public static final Set<String> PROTECTED_IPS = dedupeSet(
        ROUTER_IP, PORTAL_IP, RASPI4B_IP, RASPI3B_IP,
        PORTAL_NODE_IP, AP_EXTENDER_IP, ADMIN_IP
    );

    // ── Políticas sociales / porn ─────────────────────────────────────────────
    public static final boolean SOCIAL_BLOCK_ENABLED    = boolEnv("SOCIAL_BLOCK_ENABLED", true);
    public static final int     SOCIAL_POLICY_START_HOUR = intEnv("SOCIAL_POLICY_START_HOUR", 9);
    public static final int     SOCIAL_POLICY_END_HOUR   = intEnv("SOCIAL_POLICY_END_HOUR",   17);
    public static final String  SOCIAL_POLICY_TZ         = env("SOCIAL_POLICY_TZ", "America/Mexico_City");
    public static final int     SOCIAL_MIN_HITS          = intEnv("SOCIAL_MIN_HITS", 3);
    public static final boolean PORN_BLOCK_ENABLED       = boolEnv("PORN_BLOCK_ENABLED", true);

    // ── Feature flags ─────────────────────────────────────────────────────────
    public static final boolean FEATURE_DOMAIN_CLASSIFIER             = boolEnv("FEATURE_DOMAIN_CLASSIFIER",             true);
    public static final boolean FEATURE_DOMAIN_CLASSIFIER_LLM        = boolEnv("FEATURE_DOMAIN_CLASSIFIER_LLM",        false);
    public static final int     DOMAIN_CLASSIFIER_LLM_MAX_NEW        = intEnv("DOMAIN_CLASSIFIER_LLM_MAX_NEW_PER_REQUEST", 2);
    public static final int     DOMAIN_CLASSIFIER_LLM_TIMEOUT_S      = intEnv("DOMAIN_CLASSIFIER_LLM_TIMEOUT_S",          8);
    public static final int     DOMAIN_CLASSIFIER_LLM_N_PREDICT      = intEnv("DOMAIN_CLASSIFIER_LLM_N_PREDICT",          48);
    public static final int     DOMAIN_CLASSIFIER_LLM_MAX_QUEUE_SIZE = intEnv("DOMAIN_CLASSIFIER_LLM_MAX_QUEUE_SIZE",     4);
    public static final boolean FEATURE_PORTAL_RISK_MESSAGE          = boolEnv("FEATURE_PORTAL_RISK_MESSAGE", true);
    public static final boolean FEATURE_CHAT                         = boolEnv("FEATURE_CHAT",              true);
    public static final boolean FEATURE_DEVICE_PROFILING             = boolEnv("FEATURE_DEVICE_PROFILING",  true);
    public static final boolean FEATURE_AUTO_REPORTS                 = boolEnv("FEATURE_AUTO_REPORTS",      true);
    public static final boolean FEATURE_HUMAN_EXPLAIN               = boolEnv("FEATURE_HUMAN_EXPLAIN",     true);

    // ── Misc ──────────────────────────────────────────────────────────────────
    public static final String LOG_LEVEL          = env("LOG_LEVEL",       "INFO");
    public static final int    SUMMARY_INTERVAL_S = intEnv("SUMMARY_INTERVAL_S", 60);

    // ── Helpers ───────────────────────────────────────────────────────────────

    private static String env(String key, String def) {
        var v = System.getenv(key);
        return (v != null && !v.isBlank()) ? v : def;
    }

    private static int intEnv(String key, int def) {
        try { return Integer.parseInt(env(key, String.valueOf(def))); }
        catch (NumberFormatException e) { return def; }
    }

    private static boolean boolEnv(String key, boolean def) {
        var v = System.getenv(key);
        if (v == null || v.isBlank()) return def;
        return v.equalsIgnoreCase("true") || v.equals("1");
    }

    private static Set<String> dedupeSet(String... values) {
        var out = new LinkedHashSet<String>();
        for (var value : values) {
            if (value != null && !value.isBlank()) out.add(value);
        }
        return Set.copyOf(out);
    }

    private Config() {}
}
