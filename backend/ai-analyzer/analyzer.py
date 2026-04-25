#!/usr/bin/env python3
"""
AI Analyzer — Raspi 4B (k8s pod)

Flujo:
  1. Mosquitto MQTT ← sensor publica batches en "rafexpi/sensor/batch"
  2. on_mqtt_message → guarda batch en SQLite (status=pending) → encola ID
  3. worker_thread   → toma un ID a la vez → llama.cpp → guarda análisis en SQLite
  4. HTTP REST       → sirve historial desde SQLite + SSE en tiempo real
  5. /api/ingest     → también acepta HTTP POST directo (testing, fallback)

Variables de entorno:
    MQTT_HOST       Broker Mosquitto          (default: 192.168.1.167)
    MQTT_PORT       Puerto MQTT               (default: 1883)
    MQTT_TOPIC      Topic de batches          (default: rafexpi/sensor/batch)
    DB_PATH         Ruta SQLite               (default: /data/sensor.db)
    LLAMA_URL       URL llama.cpp server      (default: http://192.168.1.167:8081)
    N_PREDICT       Tokens máximos respuesta  (default: 256)
    MODEL_FORMAT    Formato del prompt        (default: tinyllama) — tinyllama | qwen
    PORT            Puerto HTTP               (default: 5000)
    LOG_LEVEL       Nivel de log              (default: INFO)
"""

import json
import logging
import os
import pathlib
import queue
import re
import sqlite3
import threading
import time
from collections import Counter
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse
from uuid import uuid4
from zoneinfo import ZoneInfo

import paho.mqtt.client as mqtt
import requests

from router_mcp import RouterMCP

# ─── Configuración ────────────────────────────────────────────────────────────
MQTT_HOST  = os.environ.get("MQTT_HOST",  "192.168.1.167")
MQTT_PORT  = int(os.environ.get("MQTT_PORT",  "1883"))
MQTT_TOPIC = os.environ.get("MQTT_TOPIC", "rafexpi/sensor/batch")
DB_PATH    = os.environ.get("DB_PATH",    "/data/sensor.db")
LLAMA_URL     = os.environ.get("LLAMA_URL",     "http://192.168.1.167:8081")
N_PREDICT     = int(os.environ.get("N_PREDICT",     "256"))
MODEL_FORMAT  = os.environ.get("MODEL_FORMAT",  "tinyllama")  # tinyllama | qwen
PORT          = int(os.environ.get("PORT",          "5000"))
LOG_LEVEL     = os.environ.get("LOG_LEVEL",     "INFO")
ROUTER_IP     = os.environ.get("ROUTER_IP", "192.168.1.1")
ROUTER_USER   = os.environ.get("ROUTER_USER", "root")
SSH_KEY       = os.environ.get("SSH_KEY", "/opt/keys/captive-portal")
PORTAL_IP     = os.environ.get("PORTAL_IP", "192.168.1.167")
ADMIN_IP      = os.environ.get("ADMIN_IP", "192.168.1.113")
RASPI4B_IP    = os.environ.get("RASPI4B_IP", "192.168.1.167")
RASPI3B_IP    = os.environ.get("RASPI3B_IP", "192.168.1.181")
PORTAL_NODE_IP = os.environ.get("PORTAL_NODE_IP", "192.168.1.182")
AP_EXTENDER_IP = os.environ.get("AP_EXTENDER_IP", "192.168.1.183")

# IPs que NUNCA deben bloquearse ni expulsarse del portal.
# Incluye toda la infraestructura: router, Raspis, máquina admin.
# Esta constante se usa tanto en Python como se inyecta en el prompt del LLM.
PROTECTED_IPS: frozenset[str] = frozenset(filter(None, [
    ROUTER_IP,
    PORTAL_IP,
    RASPI4B_IP,
    RASPI3B_IP,
    PORTAL_NODE_IP,
    AP_EXTENDER_IP,
    ADMIN_IP,
]))

SOCIAL_BLOCK_ENABLED = os.environ.get("SOCIAL_BLOCK_ENABLED", "true").lower() == "true"
SOCIAL_POLICY_START_HOUR = int(os.environ.get("SOCIAL_POLICY_START_HOUR", "9"))
SOCIAL_POLICY_END_HOUR = int(os.environ.get("SOCIAL_POLICY_END_HOUR", "17"))
SOCIAL_POLICY_TZ = os.environ.get("SOCIAL_POLICY_TZ", "America/Mexico_City")
SOCIAL_MIN_HITS = int(os.environ.get("SOCIAL_MIN_HITS", "3"))
PORN_BLOCK_ENABLED = os.environ.get("PORN_BLOCK_ENABLED", "true").lower() == "true"
WHITELIST_DOMAINS_DEFAULT = os.environ.get(
    "WHITELIST_DOMAINS_DEFAULT",
    "localhost.com,localhost.com.mx,microsoft.com,apple.com,google.com,openwrt.org",
)
FEATURE_HUMAN_EXPLAIN = os.environ.get("FEATURE_HUMAN_EXPLAIN", "true").lower() == "true"
FEATURE_DOMAIN_CLASSIFIER = os.environ.get("FEATURE_DOMAIN_CLASSIFIER", "true").lower() == "true"
FEATURE_DOMAIN_CLASSIFIER_LLM = os.environ.get("FEATURE_DOMAIN_CLASSIFIER_LLM", "false").lower() == "true"
DOMAIN_CLASSIFIER_LLM_MAX_NEW_PER_REQUEST = int(os.environ.get("DOMAIN_CLASSIFIER_LLM_MAX_NEW_PER_REQUEST", "2"))
DOMAIN_CLASSIFIER_LLM_TIMEOUT_S = int(os.environ.get("DOMAIN_CLASSIFIER_LLM_TIMEOUT_S", "8"))
DOMAIN_CLASSIFIER_LLM_N_PREDICT = int(os.environ.get("DOMAIN_CLASSIFIER_LLM_N_PREDICT", "48"))
DOMAIN_CLASSIFIER_LLM_MAX_QUEUE_SIZE = int(os.environ.get("DOMAIN_CLASSIFIER_LLM_MAX_QUEUE_SIZE", "4"))
FEATURE_PORTAL_RISK_MESSAGE = os.environ.get("FEATURE_PORTAL_RISK_MESSAGE", "true").lower() == "true"
FEATURE_CHAT = os.environ.get("FEATURE_CHAT", "true").lower() == "true"
FEATURE_DEVICE_PROFILING = os.environ.get("FEATURE_DEVICE_PROFILING", "true").lower() == "true"
FEATURE_AUTO_REPORTS = os.environ.get("FEATURE_AUTO_REPORTS", "true").lower() == "true"
SUMMARY_INTERVAL_S = int(os.environ.get("SUMMARY_INTERVAL_S", "60"))

# ─── Groq API (chat de alta capacidad) ───────────────────────────────────────
GROQ_API_KEY      = os.environ.get("GROQ_API_KEY", "")
GROQ_MODEL        = os.environ.get("GROQ_MODEL",   "qwen/qwen3-32b")
GROQ_CHAT_ENABLED = bool(GROQ_API_KEY)
GROQ_API_URL      = "https://api.groq.com/openai/v1/chat/completions"
GROQ_MAX_TOKENS   = int(os.environ.get("GROQ_MAX_TOKENS", "1024"))
GROQ_TIMEOUT_S    = int(os.environ.get("GROQ_TIMEOUT_S",  "30"))

RULE_HUMAN_EXPLAIN_KEY = "human_explain_template"
DEFAULT_HUMAN_EXPLAIN_TEMPLATE = (
    "Resume en español para humanos la actividad de red en máximo 4 líneas.\\n"
    "Incluye: dispositivo principal, dominios dominantes, nivel de actividad y riesgo práctico.\\n"
    "Datos:\\n{traffic}\\n"
)

SOCIAL_NETWORK_DOMAINS = {
    "facebook": ["facebook.com", "fbcdn.net", "messenger.com", "whatsapp.com", "whatsapp.net"],
    "instagram": ["instagram.com", "cdninstagram.com"],
    "x": ["twitter.com", "x.com", "twimg.com"],
    "tiktok": ["tiktok.com", "tiktokcdn.com", "byteoversea.com"],
    "youtube": ["youtube.com", "youtu.be", "googlevideo.com", "ytimg.com"],
    "linkedin": ["linkedin.com", "licdn.com"],
    "snapchat": ["snapchat.com", "sc-cdn.net"],
}
SOCIAL_DOMAIN_SET = {
    d for doms in SOCIAL_NETWORK_DOMAINS.values() for d in doms
}

PORN_DOMAIN_ROOTS = {
    "pornhub.com", "xvideos.com", "xnxx.com", "xhamster.com", "redtube.com",
    "youporn.com", "tube8.com", "spankbang.com", "beeg.com", "brazzers.com",
}

RULE_ANALYSIS_KEY = "analysis_prompt_template"
RULE_ACTION_KEY = "action_prompt_template"

DEFAULT_ANALYSIS_PROMPT_TEMPLATE = (
    "Eres analista SOC para red WiFi pública.\n"
    "IPs de infraestructura que NUNCA debes recomendar bloquear: {protected_ips}.\n"
    "Analiza este resumen de tráfico:\n"
    "{traffic}\n\n"
    "Responde en español con:\n"
    "1) Riesgo (BAJO/MEDIO/ALTO)\n"
    "2) 2-3 hallazgos accionables\n"
    "3) Recomendación breve."
)

DEFAULT_ACTION_PROMPT_TEMPLATE = (
    "Eres motor de decisiones de seguridad. Tu salida debe ser JSON estricto.\n"
    "Contexto:\n"
    "{policy_context}\n\n"
    "REGLA ABSOLUTA: Las siguientes IPs son infraestructura del sistema y NUNCA deben bloquearse "
    "ni aparecer como objetivo de ninguna acción: {protected_ips}.\n"
    "Si detectas actividad en esas IPs, ignóralas completamente.\n\n"
    "Regla base: de {start_hour}:00 a {end_hour}:00 no debe haber tráfico de redes sociales.\n"
    "Si hay evidencia suficiente, decide 'block'. Si no hay evidencia o fuera de horario, decide 'unblock' o 'none'.\n"
    "Salida JSON exacta:\n"
    "{\"action\":\"block|unblock|none\",\"reason\":\"texto corto\"}"
)

logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format="%(asctime)s %(levelname)-5s [%(funcName)s] %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
)
log = logging.getLogger("analyzer")

STATIC_DIR = pathlib.Path(__file__).parent

# ─── Cola de trabajo ──────────────────────────────────────────────────────────
work_queue = queue.Queue()   # contiene batch_id (int) a procesar

# ─── SSE clients ──────────────────────────────────────────────────────────────
sse_queues = []
sse_lock   = threading.Lock()

# ─── Estadísticas en memoria ──────────────────────────────────────────────────
stats = {
    "batches_received":  0,
    "analyses_ok":       0,
    "analyses_error":    0,
    "llama_calls":       0,
    "llama_errors":      0,
    "mqtt_connected":    False,
    "started_at":        datetime.now(timezone.utc).isoformat(),
}

router_mcp = None
policy_state = {"social_block_active": False, "porn_block_enabled": PORN_BLOCK_ENABLED}

# ─── Caché en memoria para clasificación de dominios (TTL 300 s) ──────────────
_DOMAIN_CACHE_TTL_S = 300
_domain_cache: dict[str, tuple[dict, float]] = {}   # domain → (result, expires_at)
_domain_cache_lock = threading.Lock()


# ─── SQLite ───────────────────────────────────────────────────────────────────
def db_connect() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH, check_same_thread=False, timeout=10)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")   # permite lecturas concurrentes
    return conn


def init_db():
    pathlib.Path(DB_PATH).parent.mkdir(parents=True, exist_ok=True)
    conn = db_connect()
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS batches (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            received_at TEXT    NOT NULL,
            sensor_ip   TEXT,
            status      TEXT    NOT NULL DEFAULT 'pending',
            payload     TEXT    NOT NULL
        );

        CREATE TABLE IF NOT EXISTS analyses (
            id               INTEGER PRIMARY KEY AUTOINCREMENT,
            batch_id         INTEGER NOT NULL REFERENCES batches(id),
            timestamp        TEXT    NOT NULL,
            risk             TEXT    NOT NULL DEFAULT 'BAJO',
            analysis         TEXT    NOT NULL DEFAULT '',
            elapsed_s        REAL    NOT NULL DEFAULT 0,
            suspicious_count INTEGER NOT NULL DEFAULT 0,
            packets          INTEGER NOT NULL DEFAULT 0,
            bytes_fmt        TEXT    NOT NULL DEFAULT '0 B'
        );

        CREATE TABLE IF NOT EXISTS policy_actions (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp   TEXT NOT NULL,
            action      TEXT NOT NULL,
            reason      TEXT,
            details     TEXT
        );

        CREATE TABLE IF NOT EXISTS ai_rules (
            key         TEXT PRIMARY KEY,
            value       TEXT NOT NULL,
            updated_at  TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS model_prompt_logs (
            id           INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp    TEXT NOT NULL,
            batch_id     INTEGER,
            prompt_type  TEXT NOT NULL,
            prompt       TEXT NOT NULL,
            response     TEXT,
            meta         TEXT
        );

        CREATE TABLE IF NOT EXISTS domain_whitelist (
            domain      TEXT PRIMARY KEY,
            reason      TEXT,
            created_at  TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS human_explanations (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            batch_id   INTEGER NOT NULL REFERENCES batches(id),
            timestamp  TEXT NOT NULL,
            text       TEXT NOT NULL,
            meta       TEXT
        );

        CREATE TABLE IF NOT EXISTS network_alerts (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            batch_id    INTEGER NOT NULL REFERENCES batches(id),
            timestamp   TEXT NOT NULL,
            severity    TEXT NOT NULL,
            alert_type  TEXT NOT NULL,
            message     TEXT NOT NULL,
            source_ip   TEXT,
            domain      TEXT,
            meta        TEXT
        );

        CREATE TABLE IF NOT EXISTS domain_categories (
            domain      TEXT PRIMARY KEY,
            category    TEXT NOT NULL,
            confidence  REAL NOT NULL DEFAULT 0.5,
            source      TEXT NOT NULL DEFAULT 'rule',
            updated_at  TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS network_summaries (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp  TEXT NOT NULL,
            summary    TEXT NOT NULL,
            meta       TEXT
        );

        CREATE TABLE IF NOT EXISTS network_reports (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp  TEXT NOT NULL,
            report     TEXT NOT NULL,
            meta       TEXT
        );

        CREATE TABLE IF NOT EXISTS device_profiles (
            ip          TEXT PRIMARY KEY,
            device_type TEXT NOT NULL,
            confidence  REAL NOT NULL DEFAULT 0.5,
            reasons     TEXT,
            updated_at  TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS chat_sessions (
            session_id  TEXT PRIMARY KEY,
            created_at  TEXT NOT NULL,
            updated_at  TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS chat_messages (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id  TEXT NOT NULL,
            timestamp   TEXT NOT NULL,
            role        TEXT NOT NULL,
            content     TEXT NOT NULL,
            meta        TEXT
        );

        CREATE INDEX IF NOT EXISTS idx_batches_status   ON batches(status);
        CREATE INDEX IF NOT EXISTS idx_analyses_batch   ON analyses(batch_id);
        CREATE INDEX IF NOT EXISTS idx_analyses_created ON analyses(timestamp DESC);
        CREATE INDEX IF NOT EXISTS idx_policy_created   ON policy_actions(timestamp DESC);
        CREATE INDEX IF NOT EXISTS idx_prompt_type      ON model_prompt_logs(prompt_type, id DESC);
        CREATE INDEX IF NOT EXISTS idx_human_batch      ON human_explanations(batch_id, id DESC);
        CREATE INDEX IF NOT EXISTS idx_alerts_batch     ON network_alerts(batch_id, id DESC);
        CREATE INDEX IF NOT EXISTS idx_alerts_created   ON network_alerts(timestamp DESC);
        CREATE INDEX IF NOT EXISTS idx_alerts_sev       ON network_alerts(severity, id DESC);
        CREATE INDEX IF NOT EXISTS idx_summaries_ts     ON network_summaries(timestamp DESC);
        CREATE INDEX IF NOT EXISTS idx_reports_ts       ON network_reports(timestamp DESC);
        CREATE INDEX IF NOT EXISTS idx_chat_session_ts  ON chat_messages(session_id, id DESC);
    """)
    # Migración: añadir columnas nuevas a tablas existentes (idempotente)
    for migration_sql in [
        "ALTER TABLE device_profiles ADD COLUMN hostname TEXT",
        "ALTER TABLE device_profiles ADD COLUMN mac      TEXT",
    ]:
        try:
            conn.execute(migration_sql)
            conn.commit()
        except Exception:
            pass   # La columna ya existe — ignorar
    now = datetime.now(timezone.utc).isoformat()
    conn.execute(
        "INSERT OR IGNORE INTO ai_rules (key,value,updated_at) VALUES (?,?,?)",
        (RULE_ANALYSIS_KEY, DEFAULT_ANALYSIS_PROMPT_TEMPLATE, now),
    )
    conn.execute(
        "INSERT OR IGNORE INTO ai_rules (key,value,updated_at) VALUES (?,?,?)",
        (RULE_ACTION_KEY, DEFAULT_ACTION_PROMPT_TEMPLATE, now),
    )
    conn.execute(
        "INSERT OR IGNORE INTO ai_rules (key,value,updated_at) VALUES (?,?,?)",
        (RULE_HUMAN_EXPLAIN_KEY, DEFAULT_HUMAN_EXPLAIN_TEMPLATE, now),
    )
    for domain in [d.strip().lower() for d in WHITELIST_DOMAINS_DEFAULT.split(",") if d.strip()]:
        conn.execute(
            "INSERT OR IGNORE INTO domain_whitelist (domain,reason,created_at) VALUES (?,?,?)",
            (domain, "seed_default", now),
        )
    conn.commit()
    conn.close()
    log.info("SQLite inicializado en %s", DB_PATH)


def db_store_batch(summary: dict) -> int:
    conn = db_connect()
    cur = conn.execute(
        "INSERT INTO batches (received_at, sensor_ip, status, payload) VALUES (?,?,'pending',?)",
        (
            summary.get("timestamp", datetime.now(timezone.utc).isoformat()),
            summary.get("sensor_ip", "?"),
            json.dumps(summary, ensure_ascii=False),
        ),
    )
    batch_id = cur.lastrowid
    conn.commit()
    conn.close()
    return batch_id


def db_set_status(batch_id: int, status: str):
    conn = db_connect()
    conn.execute("UPDATE batches SET status=? WHERE id=?", (status, batch_id))
    conn.commit()
    conn.close()


def db_save_analysis(batch_id: int, result: dict):
    conn = db_connect()
    conn.execute(
        """INSERT INTO analyses
           (batch_id, timestamp, risk, analysis, elapsed_s, suspicious_count, packets, bytes_fmt)
           VALUES (?,?,?,?,?,?,?,?)""",
        (
            batch_id,
            result["timestamp"],
            result["risk"],
            result["analysis"],
            result["elapsed_s"],
            result["suspicious_count"],
            result["packets"],
            result["bytes_fmt"],
        ),
    )
    conn.execute("UPDATE batches SET status='done' WHERE id=?", (batch_id,))
    conn.commit()
    conn.close()


def db_get_history(limit: int = 50) -> list:
    conn = db_connect()
    rows = conn.execute(
        """SELECT a.id, a.batch_id, a.timestamp, a.risk, a.analysis,
                  a.elapsed_s, a.suspicious_count, a.packets, a.bytes_fmt,
                  b.payload, b.sensor_ip
           FROM   analyses a
           JOIN   batches  b ON a.batch_id = b.id
           ORDER  BY a.id DESC
           LIMIT  ?""",
        (limit,),
    ).fetchall()
    conn.close()
    items = []
    for row in rows:
        summary = json.loads(row["payload"])
        items.append({
            "id":               row["id"],
            "batch_id":         row["batch_id"],
            "timestamp":        row["timestamp"],
            "risk":             row["risk"],
            "analysis":         row["analysis"],
            "elapsed_s":        row["elapsed_s"],
            "suspicious_count": row["suspicious_count"],
            "packets":          row["packets"],
            "bytes_fmt":        row["bytes_fmt"],
            "summary":          summary,
            "suspicious":       summary.get("suspicious", []),
            "lan_devices":      summary.get("lan_devices", []),
            "dns_queries":      summary.get("dns_queries", [])[:20],
        })
    items.reverse()   # cronológico ascendente para el dashboard
    return items


def db_queue_stats() -> dict:
    conn = db_connect()
    def count(status):
        return conn.execute(
            "SELECT COUNT(*) FROM batches WHERE status=?", (status,)
        ).fetchone()[0]
    result = {
        "pending":    count("pending"),
        "processing": count("processing"),
        "done":       count("done"),
        "error":      count("error"),
        "queue_size": work_queue.qsize(),
    }
    conn.close()
    return result


def db_store_policy_action(action: str, reason: str, details: dict):
    conn = db_connect()
    conn.execute(
        "INSERT INTO policy_actions (timestamp, action, reason, details) VALUES (?,?,?,?)",
        (
            datetime.now(timezone.utc).isoformat(),
            action,
            reason,
            json.dumps(details, ensure_ascii=False),
        ),
    )
    conn.commit()
    conn.close()


def db_get_policy_actions(limit: int = 50) -> list:
    conn = db_connect()
    rows = conn.execute(
        "SELECT id,timestamp,action,reason,details FROM policy_actions ORDER BY id DESC LIMIT ?",
        (limit,),
    ).fetchall()
    conn.close()
    items = []
    for row in rows:
        details = {}
        try:
            details = json.loads(row["details"] or "{}")
        except Exception:
            pass
        items.append({
            "id": row["id"],
            "timestamp": row["timestamp"],
            "action": row["action"],
            "reason": row["reason"],
            "details": details,
        })
    items.reverse()
    return items


def db_get_rule(key: str, fallback: str = "") -> str:
    conn = db_connect()
    row = conn.execute("SELECT value FROM ai_rules WHERE key=?", (key,)).fetchone()
    conn.close()
    return row["value"] if row else fallback


def db_set_rule(key: str, value: str):
    now = datetime.now(timezone.utc).isoformat()
    conn = db_connect()
    conn.execute(
        "INSERT INTO ai_rules (key,value,updated_at) VALUES (?,?,?) "
        "ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at",
        (key, value, now),
    )
    conn.commit()
    conn.close()


def db_get_rules() -> dict:
    conn = db_connect()
    rows = conn.execute("SELECT key,value,updated_at FROM ai_rules ORDER BY key").fetchall()
    conn.close()
    out = {}
    for r in rows:
        out[r["key"]] = {"value": r["value"], "updated_at": r["updated_at"]}
    return out


def db_log_prompt(prompt_type: str, prompt: str, response: str, batch_id: int | None = None, meta: dict | None = None):
    conn = db_connect()
    conn.execute(
        "INSERT INTO model_prompt_logs (timestamp,batch_id,prompt_type,prompt,response,meta) VALUES (?,?,?,?,?,?)",
        (
            datetime.now(timezone.utc).isoformat(),
            batch_id,
            prompt_type,
            prompt,
            response,
            json.dumps(meta or {}, ensure_ascii=False),
        ),
    )
    conn.commit()
    conn.close()


def db_get_prompt_logs(limit: int = 50, prompt_type: str | None = None) -> list:
    conn = db_connect()
    if prompt_type:
        rows = conn.execute(
            "SELECT id,timestamp,batch_id,prompt_type,prompt,response,meta FROM model_prompt_logs "
            "WHERE prompt_type=? ORDER BY id DESC LIMIT ?",
            (prompt_type, limit),
        ).fetchall()
    else:
        rows = conn.execute(
            "SELECT id,timestamp,batch_id,prompt_type,prompt,response,meta FROM model_prompt_logs "
            "ORDER BY id DESC LIMIT ?",
            (limit,),
        ).fetchall()
    conn.close()
    items = []
    for r in rows:
        try:
            meta = json.loads(r["meta"] or "{}")
        except Exception:
            meta = {}
        items.append({
            "id": r["id"],
            "timestamp": r["timestamp"],
            "batch_id": r["batch_id"],
            "prompt_type": r["prompt_type"],
            "prompt": r["prompt"],
            "response": r["response"],
            "meta": meta,
        })
    items.reverse()
    return items


def db_store_human_explanation(batch_id: int, text: str, meta: dict | None = None):
    conn = db_connect()
    conn.execute(
        "INSERT INTO human_explanations (batch_id,timestamp,text,meta) VALUES (?,?,?,?)",
        (
            batch_id,
            datetime.now(timezone.utc).isoformat(),
            text,
            json.dumps(meta or {}, ensure_ascii=False),
        ),
    )
    conn.commit()
    conn.close()


def db_get_human_explanations(limit: int = 20) -> list[dict]:
    conn = db_connect()
    rows = conn.execute(
        "SELECT id,batch_id,timestamp,text,meta FROM human_explanations ORDER BY id DESC LIMIT ?",
        (limit,),
    ).fetchall()
    conn.close()
    out = []
    for r in rows:
        try:
            meta = json.loads(r["meta"] or "{}")
        except Exception:
            meta = {}
        out.append({
            "id": r["id"],
            "batch_id": r["batch_id"],
            "timestamp": r["timestamp"],
            "text": r["text"],
            "meta": meta,
        })
    out.reverse()
    return out


def db_store_alerts(batch_id: int, alerts: list[dict]):
    if not alerts:
        return
    now = datetime.now(timezone.utc).isoformat()
    conn = db_connect()
    for a in alerts:
        conn.execute(
            "INSERT INTO network_alerts (batch_id,timestamp,severity,alert_type,message,source_ip,domain,meta) "
            "VALUES (?,?,?,?,?,?,?,?)",
            (
                batch_id,
                now,
                str(a.get("severity") or "info").lower(),
                str(a.get("type") or "generic"),
                str(a.get("message") or ""),
                str(a.get("source_ip") or ""),
                str(a.get("domain") or ""),
                json.dumps(a.get("meta") or {}, ensure_ascii=False),
            ),
        )
    conn.commit()
    conn.close()


def db_get_alerts(limit: int = 80) -> list[dict]:
    conn = db_connect()
    rows = conn.execute(
        "SELECT id,batch_id,timestamp,severity,alert_type,message,source_ip,domain,meta "
        "FROM network_alerts ORDER BY id DESC LIMIT ?",
        (limit,),
    ).fetchall()
    conn.close()
    out = []
    for r in rows:
        try:
            meta = json.loads(r["meta"] or "{}")
        except Exception:
            meta = {}
        out.append({
            "id": r["id"],
            "batch_id": r["batch_id"],
            "timestamp": r["timestamp"],
            "severity": r["severity"],
            "alert_type": r["alert_type"],
            "message": r["message"],
            "source_ip": r["source_ip"],
            "domain": r["domain"],
            "meta": meta,
        })
    out.reverse()
    return out


def db_store_summary(text: str, meta: dict | None = None):
    conn = db_connect()
    conn.execute(
        "INSERT INTO network_summaries (timestamp,summary,meta) VALUES (?,?,?)",
        (datetime.now(timezone.utc).isoformat(), text, json.dumps(meta or {}, ensure_ascii=False)),
    )
    conn.commit()
    conn.close()


def db_get_summaries(limit: int = 20) -> list[dict]:
    conn = db_connect()
    rows = conn.execute(
        "SELECT id,timestamp,summary,meta FROM network_summaries ORDER BY id DESC LIMIT ?",
        (limit,),
    ).fetchall()
    conn.close()
    items = []
    for r in rows:
        try:
            meta = json.loads(r["meta"] or "{}")
        except Exception:
            meta = {}
        items.append({
            "id": r["id"],
            "timestamp": r["timestamp"],
            "summary": r["summary"],
            "meta": meta,
        })
    items.reverse()
    return items


def db_store_report(text: str, meta: dict | None = None):
    conn = db_connect()
    conn.execute(
        "INSERT INTO network_reports (timestamp,report,meta) VALUES (?,?,?)",
        (datetime.now(timezone.utc).isoformat(), text, json.dumps(meta or {}, ensure_ascii=False)),
    )
    conn.commit()
    conn.close()


def db_get_reports(limit: int = 20) -> list[dict]:
    conn = db_connect()
    rows = conn.execute(
        "SELECT id,timestamp,report,meta FROM network_reports ORDER BY id DESC LIMIT ?",
        (limit,),
    ).fetchall()
    conn.close()
    items = []
    for r in rows:
        try:
            meta = json.loads(r["meta"] or "{}")
        except Exception:
            meta = {}
        items.append({
            "id": r["id"],
            "timestamp": r["timestamp"],
            "report": r["report"],
            "meta": meta,
        })
    items.reverse()
    return items


def db_upsert_device_profile(
    ip: str,
    device_type: str,
    confidence: float,
    reasons: list[str],
    hostname: str | None = None,
    mac: str | None = None,
):
    ip = str(ip or "").strip()
    if not ip:
        return
    conn = db_connect()
    conn.execute(
        "INSERT INTO device_profiles (ip,device_type,confidence,reasons,hostname,mac,updated_at) VALUES (?,?,?,?,?,?,?) "
        "ON CONFLICT(ip) DO UPDATE SET "
        "device_type=excluded.device_type,confidence=excluded.confidence,reasons=excluded.reasons,"
        "hostname=COALESCE(excluded.hostname,device_profiles.hostname),"
        "mac=COALESCE(excluded.mac,device_profiles.mac),"
        "updated_at=excluded.updated_at",
        (
            ip,
            str(device_type or "desconocido"),
            max(0.0, min(float(confidence), 1.0)),
            json.dumps(reasons or [], ensure_ascii=False),
            str(hostname).strip() if hostname else None,
            str(mac).strip().lower() if mac else None,
            datetime.now(timezone.utc).isoformat(),
        ),
    )
    conn.commit()
    conn.close()


def db_get_device_profiles(limit: int = 100) -> list[dict]:
    conn = db_connect()
    rows = conn.execute(
        "SELECT ip,device_type,confidence,reasons,hostname,mac,updated_at "
        "FROM device_profiles ORDER BY updated_at DESC LIMIT ?",
        (limit,),
    ).fetchall()
    conn.close()
    out = []
    for r in rows:
        try:
            reasons = json.loads(r["reasons"] or "[]")
        except Exception:
            reasons = []
        out.append({
            "ip":          r["ip"],
            "device_type": r["device_type"],
            "confidence":  r["confidence"],
            "reasons":     reasons,
            "hostname":    r["hostname"],
            "mac":         r["mac"],
            "updated_at":  r["updated_at"],
        })
    return out


def db_upsert_chat_session(session_id: str):
    now = datetime.now(timezone.utc).isoformat()
    conn = db_connect()
    conn.execute(
        "INSERT INTO chat_sessions (session_id,created_at,updated_at) VALUES (?,?,?) "
        "ON CONFLICT(session_id) DO UPDATE SET updated_at=excluded.updated_at",
        (session_id, now, now),
    )
    conn.commit()
    conn.close()


def db_store_chat_message(session_id: str, role: str, content: str, meta: dict | None = None):
    db_upsert_chat_session(session_id)
    conn = db_connect()
    conn.execute(
        "INSERT INTO chat_messages (session_id,timestamp,role,content,meta) VALUES (?,?,?,?,?)",
        (
            session_id,
            datetime.now(timezone.utc).isoformat(),
            role,
            content,
            json.dumps(meta or {}, ensure_ascii=False),
        ),
    )
    conn.commit()
    conn.close()


def db_get_chat_history(session_id: str, limit: int = 40) -> list[dict]:
    conn = db_connect()
    rows = conn.execute(
        "SELECT id,session_id,timestamp,role,content,meta FROM chat_messages "
        "WHERE session_id=? ORDER BY id DESC LIMIT ?",
        (session_id, limit),
    ).fetchall()
    conn.close()
    out = []
    for r in rows[::-1]:
        try:
            meta = json.loads(r["meta"] or "{}")
        except Exception:
            meta = {}
        out.append({
            "id":         r["id"],
            "session_id": r["session_id"],
            "timestamp":  r["timestamp"],
            "role":       r["role"],
            "content":    r["content"],
            "provider":   meta.get("provider", ""),  # campo directo para el frontend
            "meta":       meta,
        })
    return out


def db_get_domain_category(domain: str) -> dict | None:
    d = _normalize_domain(domain)
    if not d:
        return None
    conn = db_connect()
    row = conn.execute(
        "SELECT domain,category,confidence,source,updated_at FROM domain_categories WHERE domain=?",
        (d,),
    ).fetchone()
    conn.close()
    return dict(row) if row else None


def db_set_domain_category(domain: str, category: str, confidence: float, source: str):
    d = _normalize_domain(domain)
    c = str(category or "otros").strip().lower()
    s = str(source or "rule").strip().lower()
    if not d:
        return
    conn = db_connect()
    conn.execute(
        "INSERT INTO domain_categories (domain,category,confidence,source,updated_at) VALUES (?,?,?,?,?) "
        "ON CONFLICT(domain) DO UPDATE SET "
        "category=excluded.category,confidence=excluded.confidence,source=excluded.source,updated_at=excluded.updated_at",
        (d, c, float(confidence), s, datetime.now(timezone.utc).isoformat()),
    )
    conn.commit()
    conn.close()


def _normalize_domain(value: str) -> str:
    d = str(value or "").strip().lower().rstrip(".")
    return d


def _domain_in_roots(domain: str, roots: set[str]) -> bool:
    d = _normalize_domain(domain)
    if not d:
        return False
    for root in roots:
        r = _normalize_domain(root)
        if not r:
            continue
        if d == r or d.endswith("." + r):
            return True
    return False


def db_get_whitelist() -> list[dict]:
    conn = db_connect()
    rows = conn.execute(
        "SELECT domain,reason,created_at FROM domain_whitelist ORDER BY domain"
    ).fetchall()
    conn.close()
    return [dict(r) for r in rows]


def db_get_whitelist_set() -> set[str]:
    return {_normalize_domain(x["domain"]) for x in db_get_whitelist() if _normalize_domain(x["domain"])}


def db_whitelist_add(domain: str, reason: str = ""):
    d = _normalize_domain(domain)
    if not d:
        return
    conn = db_connect()
    conn.execute(
        "INSERT INTO domain_whitelist (domain,reason,created_at) VALUES (?,?,?) "
        "ON CONFLICT(domain) DO UPDATE SET reason=excluded.reason",
        (d, reason or "manual", datetime.now(timezone.utc).isoformat()),
    )
    conn.commit()
    conn.close()


def db_whitelist_remove(domain: str):
    d = _normalize_domain(domain)
    if not d:
        return
    conn = db_connect()
    conn.execute("DELETE FROM domain_whitelist WHERE domain=?", (d,))
    conn.commit()
    conn.close()


def db_get_domain_stats(limit_batches: int = 50, top_n: int = 20) -> dict:
    conn = db_connect()
    rows = conn.execute(
        "SELECT id,payload FROM batches ORDER BY id DESC LIMIT ?",
        (max(1, min(limit_batches, 500)),),
    ).fetchall()
    conn.close()

    dns = Counter()
    sni = Counter()
    http = Counter()
    combined = Counter()
    scanned = 0

    for row in rows:
        try:
            payload = json.loads(row["payload"])
        except Exception:
            continue
        scanned += 1
        for k, counter in (
            ("dns_query_counts", dns),
            ("tls_sni_counts", sni),
            ("http_host_counts", http),
        ):
            m = payload.get(k) or {}
            if not isinstance(m, dict):
                continue
            for domain, count in m.items():
                d = _normalize_domain(domain)
                if not d:
                    continue
                try:
                    n = int(count)
                except Exception:
                    n = 1
                n = max(1, n)
                counter[d] += n
                combined[d] += n

    def top_items(counter: Counter, n: int):
        return [{"domain": d, "count": c} for d, c in counter.most_common(n)]

    return {
        "window_batches": scanned,
        "visibility": {
            "dns": "completo",
            "tls_sni": "dominio",
            "http": "dominio",
        },
        "dns": top_items(dns, top_n),
        "tls_sni": top_items(sni, top_n),
        "http": top_items(http, top_n),
        "combined": top_items(combined, top_n),
    }


def db_get_blocked_site_events(limit: int = 80) -> list[dict]:
    actions = db_get_policy_actions(limit)
    allowed_actions = {
        "social_block_on",
        "social_block_refresh",
        "porn_enforcement",
        "porn_ip_block_only",
    }
    out = []
    for a in actions:
        action = str(a.get("action", ""))
        if action not in allowed_actions:
            continue
        details = a.get("details") or {}
        domains = []
        category = "unknown"
        reason = a.get("reason") or ""

        if "social" in action:
            category = "social"
            social = details.get("social") or {}
            domains = list((social.get("matched_domains") or {}).keys())
            if not reason:
                reason = "Tráfico de redes sociales en ventana restringida"
        elif "porn" in action:
            category = "porn"
            domains = list((details.get("trigger_domains") or {}).keys())
            if not reason:
                reason = "Detección de tráfico a sitios pornográficos"

        out.append({
            "id": a.get("id"),
            "timestamp": a.get("timestamp"),
            "action": action,
            "category": category,
            "reason": reason,
            "domains": domains[:30],
        })
    return out


# ─── Prompt builder ───────────────────────────────────────────────────────────
def _safe_format(template: str, context: dict) -> str:
    text = template
    for k, v in context.items():
        text = text.replace("{" + k + "}", str(v))
    return text


def _wrap_prompt(user_body: str, system_text: str) -> str:
    if MODEL_FORMAT == "qwen":
        return (
            "<|im_start|>system\n"
            f"{system_text}\n"
            "<|im_end|>\n"
            f"<|im_start|>user\n{user_body}<|im_end|>\n"
            "<|im_start|>assistant\n"
        )
    return (
        "<|system|>\n"
        f"{system_text}\n"
        "</s>\n"
        f"<|user|>\n{user_body}</s>\n"
        "<|assistant|>\n"
    )


def _prompt_body(summary: dict) -> str:
    """Cuerpo del prompt — formato compacto ~180 tokens, válido para cualquier modelo."""
    duration = summary.get("duration_seconds", 30)
    packets  = summary.get("total_packets", 0)
    bfmt     = summary.get("total_bytes_fmt", "0B")
    pps      = summary.get("pps", 0)

    proto_str = ",".join(
        f"{k}:{v}" for k, v in sorted(
            summary.get("protocols", {}).items(), key=lambda x: -x[1]
        )[:3]
    ) or "-"

    # Construir mapa ip→hostname desde dhcp_devices para enriquecer top_talkers
    dhcp_map: dict[str, str] = {}
    for dev in (summary.get("dhcp_devices") or []):
        ip  = dev.get("ip", "")
        hn  = dev.get("hostname", "")
        if ip and hn and hn != "desconocido":
            dhcp_map[ip] = hn

    talkers_parts = []
    for t in summary.get("top_talkers", [])[:3]:
        ip = t["ip"]
        hn = dhcp_map.get(ip)
        talkers_parts.append(f"{ip}({hn})" if hn else ip)
    talkers_str = ",".join(talkers_parts) or "-"

    ports_str = ",".join(
        str(p["port"]) for p in summary.get("top_dst_ports", [])[:4]
    ) or "-"

    dns_str = ",".join(summary.get("dns_queries", [])[:4]) or "-"

    suspicious = summary.get("suspicious", [])[:3]
    susp_str = "; ".join(
        f"[{s['type'].upper()}]{s.get('src', s.get('port','?'))}"
        for s in suspicious
    ) if suspicious else "-"

    # Top 2 clientes más activos con sus top 3 dominios
    cdc: dict = summary.get("client_domain_counts") or {}
    client_lines = []
    if isinstance(cdc, dict):
        # Ordenar clientes por total de peticiones de dominio
        sorted_clients = sorted(
            cdc.items(),
            key=lambda kv: sum(kv[1].values()) if isinstance(kv[1], dict) else 0,
            reverse=True,
        )[:2]
        for client_ip, dom_map in sorted_clients:
            if not isinstance(dom_map, dict):
                continue
            top_doms = sorted(dom_map.items(), key=lambda x: -x[1])[:3]
            doms_str = ",".join(f"{d}×{c}" for d, c in top_doms)
            hn = dhcp_map.get(client_ip, "")
            label = f"{client_ip}({hn})" if hn else client_ip
            client_lines.append(f"{label}→{doms_str}")
    clients_str = "; ".join(client_lines) if client_lines else "-"

    # Clientes autorizados en portal cautivo
    captive_allowed = summary.get("captive_allowed") or []
    captive_str = str(len(captive_allowed)) if isinstance(captive_allowed, list) else "-"

    # Top 2 peticiones HTTP (rutas sospechosas de alto valor)
    http_reqs = (summary.get("http_requests") or [])[:2]
    http_str = "; ".join(http_reqs) if http_reqs else "-"

    return (
        f"WiFi {duration}s: pkt={packets} pps={pps} bytes={bfmt}\n"
        f"Proto:{proto_str}\n"
        f"IPs:{talkers_str}\n"
        f"Ports:{ports_str}\n"
        f"DNS:{dns_str}\n"
        f"Alertas:{susp_str}\n"
        f"Clientes_top:{clients_str}\n"
        f"Portal_autorizados:{captive_str}\n"
        f"HTTP_req:{http_str}\n"
    )


def build_analysis_prompt(summary: dict) -> str:
    traffic = _prompt_body(summary)
    tpl = db_get_rule(RULE_ANALYSIS_KEY, DEFAULT_ANALYSIS_PROMPT_TEMPLATE)
    user_body = _safe_format(tpl, {
        "traffic": traffic,
        "protected_ips": ", ".join(sorted(PROTECTED_IPS)),
    })
    return _wrap_prompt(
        user_body=user_body,
        system_text="Analista SOC de seguridad WiFi. Responde en español claro.",
    )


def build_action_prompt(policy_context: dict) -> str:
    tpl = db_get_rule(RULE_ACTION_KEY, DEFAULT_ACTION_PROMPT_TEMPLATE)
    ctx = {
        "policy_context": json.dumps(policy_context, ensure_ascii=False, indent=2),
        "start_hour": SOCIAL_POLICY_START_HOUR,
        "end_hour": SOCIAL_POLICY_END_HOUR,
        "protected_ips": ", ".join(sorted(PROTECTED_IPS)),
    }
    user_body = _safe_format(tpl, ctx)
    return _wrap_prompt(
        user_body=user_body,
        system_text="Motor de decisión de políticas de red. Entrega salida en JSON estricto.",
    )


# ─── llama.cpp ───────────────────────────────────────────────────────────────
def call_llama(
    prompt: str,
    *,
    timeout_s: int = 120,
    n_predict: int | None = None,
    temperature: float = 0.7,
    top_p: float = 0.9,
) -> str:
    stats["llama_calls"] += 1
    try:
        t0   = time.time()
        stop_tokens = (
            ["<|im_end|>", "<|endoftext|>"]
            if MODEL_FORMAT == "qwen"
            else ["</s>", "<|user|>", "<|system|>"]
        )
        resp = requests.post(
            f"{LLAMA_URL}/completion",
            json={
                "prompt":      prompt,
                "n_predict":   int(n_predict if n_predict is not None else N_PREDICT),
                "temperature": float(temperature),
                "top_p":       float(top_p),
                "stop":        stop_tokens,
                "stream":      False,
            },
            timeout=max(1, int(timeout_s)),
        )
        elapsed = round(time.time() - t0, 1)
        if resp.status_code == 200:
            text = resp.json().get("content", "").strip()
            log.info("llama.cpp respondió en %ss (%d chars)", elapsed, len(text))
            return text
        log.warning("llama.cpp HTTP %d", resp.status_code)
        stats["llama_errors"] += 1
        return f"[Error llama.cpp: HTTP {resp.status_code}]"
    except Exception as e:
        log.error("llama.cpp error: %s", e)
        stats["llama_errors"] += 1
        return f"[Error: {e}]"


def call_groq_chat(
    messages: list[dict],
    *,
    temperature: float = 0.7,
    max_tokens: int | None = None,
) -> str:
    """Llama a la API de Groq (compatible OpenAI) con el modelo configurado.

    Args:
        messages: Lista de dicts {"role": "system|user|assistant", "content": "..."}
        temperature: Temperatura de muestreo (0-1).
        max_tokens: Límite de tokens en la respuesta (default: GROQ_MAX_TOKENS).

    Returns:
        Texto de respuesta del modelo, o cadena "[Error ...]" si falla.
    """
    if not GROQ_CHAT_ENABLED:
        return "[Error: GROQ_API_KEY no configurado]"
    t0 = time.time()
    try:
        resp = requests.post(
            GROQ_API_URL,
            headers={
                "Authorization": f"Bearer {GROQ_API_KEY}",
                "Content-Type":  "application/json",
            },
            json={
                "model":       GROQ_MODEL,
                "messages":    messages,
                "temperature": float(temperature),
                "max_tokens":  int(max_tokens if max_tokens is not None else GROQ_MAX_TOKENS),
                "stream":      False,
            },
            timeout=GROQ_TIMEOUT_S,
        )
        elapsed = round(time.time() - t0, 1)
        if resp.status_code == 200:
            text = (
                resp.json()
                .get("choices", [{}])[0]
                .get("message", {})
                .get("content", "")
                .strip()
            )
            log.info("Groq (%s) respondió en %ss (%d chars)", GROQ_MODEL, elapsed, len(text))
            return text
        log.warning("Groq HTTP %d: %s", resp.status_code, resp.text[:200])
        return f"[Error Groq: HTTP {resp.status_code}]"
    except Exception as e:
        log.error("Groq error: %s", e)
        return f"[Error Groq: {e}]"


def _social_bucket_for_domain(domain: str) -> str | None:
    d = _normalize_domain(domain)
    for bucket, roots in SOCIAL_NETWORK_DOMAINS.items():
        for root in roots:
            r = _normalize_domain(root)
            if d == r or d.endswith("." + r):
                return bucket
    return None


def _domain_matches_roots(domain: str, roots: set[str]) -> bool:
    return _domain_in_roots(domain, roots)


def _combined_domain_counts(summary: dict) -> dict:
    combined_counts = {}
    for source in ("dns_query_counts", "http_host_counts", "tls_sni_counts"):
        source_map = summary.get(source) or {}
        if isinstance(source_map, dict):
            for domain, count in source_map.items():
                d = str(domain).lower().strip()
                if not d:
                    continue
                try:
                    n = int(count)
                except Exception:
                    n = 1
                combined_counts[d] = combined_counts.get(d, 0) + max(1, n)
    if combined_counts:
        return combined_counts

    # Compatibilidad con batches viejos que solo traen listas únicas.
    for domain in (
        (summary.get("dns_queries") or [])
        + (summary.get("http_hosts") or [])
        + (summary.get("tls_sni_hosts") or [])
    ):
        d = str(domain).lower().strip()
        if d:
            combined_counts[d] = combined_counts.get(d, 0) + 1
    return combined_counts


def _top_domains_text(summary: dict, n: int = 4) -> str:
    combined = _combined_domain_counts(summary)
    if not combined:
        return "-"
    top = sorted(combined.items(), key=lambda x: -x[1])[:n]
    return ", ".join(f"{d}({c})" for d, c in top)


def _fallback_human_explain(summary: dict, analysis_text: str, risk: str) -> str:
    talker = "-"
    top_talkers = summary.get("top_talkers") or []
    if top_talkers:
        talker = str(top_talkers[0].get("ip") or "-")
    pkt = int(summary.get("total_packets") or 0)
    domains = _top_domains_text(summary, 4)
    suspicious = int(len(summary.get("suspicious") or []))
    risk_phrase = "bajo"
    if risk == "MEDIO":
        risk_phrase = "moderado"
    elif risk == "ALTO":
        risk_phrase = "alto"
    return (
        f"En los últimos {summary.get('duration_seconds', 30)} segundos, el dispositivo {talker} "
        f"concentró la mayor actividad. Se observaron {pkt} paquetes y consultas a: {domains}. "
        f"Se detectaron {suspicious} señales sospechosas. El riesgo operativo estimado es {risk_phrase}. "
        f"{analysis_text[:180].strip()}"
    ).strip()


def build_human_explanation(summary: dict, analysis_text: str, risk: str) -> str:
    if not FEATURE_HUMAN_EXPLAIN:
        return _fallback_human_explain(summary, analysis_text, risk)
    tpl = db_get_rule(RULE_HUMAN_EXPLAIN_KEY, DEFAULT_HUMAN_EXPLAIN_TEMPLATE)
    traffic = (
        f"packets={summary.get('total_packets', 0)} "
        f"bytes={summary.get('total_bytes_fmt', '0 B')} "
        f"pps={summary.get('pps', 0)} "
        f"top_domains={_top_domains_text(summary, 5)} "
        f"suspicious={len(summary.get('suspicious') or [])} "
        f"top_talker={(summary.get('top_talkers') or [{}])[0].get('ip', '-')}"
    )
    user_body = _safe_format(tpl, {"traffic": traffic})
    prompt = _wrap_prompt(
        user_body=user_body,
        system_text="Eres analista de red y traductor técnico. Explica para audiencia no técnica.",
    )
    response = call_llama(
        prompt,
        temperature=0.6,
        top_p=0.9,
    ).strip()
    if not response or response.startswith("[Error"):
        return _fallback_human_explain(summary, analysis_text, risk)
    db_log_prompt(
        prompt_type="human_explain",
        prompt=prompt,
        response=response,
        meta={"risk": risk},
    )
    return response


def _is_rare_domain(domain: str) -> bool:
    d = _normalize_domain(domain)
    if not d or "." not in d:
        return False
    tld = d.rsplit(".", 1)[-1]
    uncommon_tlds = {"xyz", "top", "click", "gq", "work", "cam", "rest", "zip"}
    left = d.split(".", 1)[0]
    looks_dga = len(left) >= 12 and sum(ch.isdigit() for ch in left) >= 3
    return tld in uncommon_tlds or looks_dga


def detect_behavior_alerts(summary: dict) -> list[dict]:
    alerts = []
    combined = _combined_domain_counts(summary)
    total_domain_hits = sum(combined.values()) if combined else 0
    unique_domains = len(combined)

    if unique_domains >= 25:
        alerts.append({
            "severity": "medium" if unique_domains < 45 else "high",
            "type": "many_distinct_domains",
            "message": f"Se detectaron {unique_domains} dominios distintos en una sola ventana.",
            "meta": {"unique_domains": unique_domains},
        })

    if combined:
        top_domain, top_count = sorted(combined.items(), key=lambda x: -x[1])[0]
        concentration = (top_count / total_domain_hits) if total_domain_hits else 0
        if top_count >= 12 and concentration >= 0.45:
            alerts.append({
                "severity": "medium",
                "type": "repeated_domain_queries",
                "message": f"Dominio repetido anómalamente: {top_domain} ({top_count} consultas).",
                "domain": top_domain,
                "meta": {"count": top_count, "ratio": round(concentration, 3)},
            })

    rare_domains = [d for d in combined.keys() if _is_rare_domain(d)]
    for d in rare_domains[:8]:
        alerts.append({
            "severity": "high",
            "type": "rare_domain_pattern",
            "message": f"Dominio con patrón inusual detectado: {d}",
            "domain": d,
        })

    for s in (summary.get("suspicious") or []):
        alerts.append({
            "severity": "medium",
            "type": f"sensor_{s.get('type', 'event')}",
            "message": s.get("detail") or f"Evento sospechoso: {s.get('type', 'event')}",
            "source_ip": s.get("src") or "",
            "meta": s,
        })

    # Fase 4.3 — Alerta correlacionada: dominio DGA desde IP no autorizada en portal
    captive_allowed: list = summary.get("captive_allowed") or []
    if rare_domains and isinstance(captive_allowed, list):
        authorized_set = set(captive_allowed)
        cdc: dict = summary.get("client_domain_counts") or {}
        for client_ip, dom_map in (cdc.items() if isinstance(cdc, dict) else []):
            if not isinstance(dom_map, dict):
                continue
            client_rare = [d for d in dom_map if _is_rare_domain(d) and d in rare_domains]
            if not client_rare:
                continue
            is_unauthorized = client_ip not in authorized_set
            severity = "critical" if is_unauthorized else "high"
            alerts.append({
                "severity": severity,
                "type": "dga_suspicious_client",
                "message": (
                    f"{'IP no autorizada' if is_unauthorized else 'IP autorizada'} {client_ip} "
                    f"genera consultas DGA: {', '.join(client_rare[:3])}"
                ),
                "source_ip": client_ip,
                "domain": client_rare[0],
                "meta": {
                    "rare_domains": client_rare[:5],
                    "captive_authorized": not is_unauthorized,
                    "captive_allowed_count": len(authorized_set),
                },
            })

    # Alertas por peticiones HTTP sospechosas (Fase 3.2)
    for req in (summary.get("suspicious_http_requests") or [])[:5]:
        alerts.append({
            "severity": "high",
            "type": "suspicious_http_request",
            "message": f"Petición HTTP con patrón malicioso: {req.get('request', req.get('uri', '?'))}",
            "source_ip": req.get("src", ""),
            "meta": req,
        })

    return alerts


def _heuristic_domain_category(domain: str) -> tuple[str, float]:
    d = _normalize_domain(domain)
    if not d:
        return "otros", 0.4
    rules = [
        ("redes_sociales", ("facebook.com", "instagram.com", "x.com", "twitter.com", "tiktok.com", "snapchat.com")),
        ("streaming", ("youtube.com", "googlevideo.com", "netflix.com", "disneyplus.com", "spotify.com", "twitch.tv")),
        ("desarrollo", ("github.com", "gitlab.com", "pypi.org", "npmjs.com", "docker.com")),
        ("infraestructura", ("cloudflare.com", "cloudflare-dns.com", "akamai", "fastly", "amazonaws.com", "azure.com", "gstatic.com")),
        ("mensajeria", ("whatsapp.com", "telegram.org", "messenger.com", "signal.org")),
        ("productividad", ("office.com", "microsoft.com", "google.com", "notion.so", "slack.com")),
        ("adulto", tuple(PORN_DOMAIN_ROOTS)),
    ]
    for cat, roots in rules:
        if _domain_in_roots(d, set(roots)):
            return cat, 0.92
    return "otros", 0.55


def _llm_domain_category(domain: str) -> tuple[str, float]:
    prompt = _wrap_prompt(
        user_body=(
            "Clasifica este dominio en una categoría de red. "
            "Responde SOLO JSON: {\"category\":\"...\",\"confidence\":0.0}\n"
            f"dominio: {domain}\n"
            "categorías válidas: infraestructura, redes_sociales, streaming, desarrollo, mensajeria, productividad, adulto, otros"
        ),
        system_text="Clasificador determinista de dominios.",
    )
    response = call_llama(
        prompt,
        timeout_s=DOMAIN_CLASSIFIER_LLM_TIMEOUT_S,
        n_predict=DOMAIN_CLASSIFIER_LLM_N_PREDICT,
        temperature=0.1,
        top_p=0.5,
    )
    m = re.search(r"\{.*\}", response or "", flags=re.S)
    if not m:
        return "otros", 0.4
    try:
        obj = json.loads(m.group(0))
    except Exception:
        return "otros", 0.4
    cat = str(obj.get("category") or "otros").strip().lower()
    conf = float(obj.get("confidence") or 0.5)
    allowed = {"infraestructura", "redes_sociales", "streaming", "desarrollo", "mensajeria", "productividad", "adulto", "otros"}
    if cat not in allowed:
        cat = "otros"
    conf = max(0.0, min(conf, 1.0))
    return cat, conf


def classify_domain(domain: str, *, allow_llm: bool = True, refresh_cached_otros: bool = False) -> dict:
    # 1) Caché en memoria (evita round-trips a SQLite y llamadas LLM redundantes)
    _now = time.time()
    with _domain_cache_lock:
        mem_entry = _domain_cache.get(domain)
        if mem_entry is not None:
            mem_result, expires_at = mem_entry
            if _now < expires_at:
                # Solo usar si no es "otros" candidato a reclasificación
                if not (allow_llm and refresh_cached_otros
                        and str(mem_result.get("category") or "") == "otros"
                        and str(mem_result.get("source") or "") != "llm"):
                    return mem_result

    # 2) Caché en SQLite (persistente entre reinicios)
    cached = db_get_domain_category(domain)
    if cached:
        if not (
            allow_llm
            and refresh_cached_otros
            and str(cached.get("category") or "") == "otros"
            and str(cached.get("source") or "") != "llm"
        ):
            # Actualizar caché en memoria con el resultado de SQLite
            with _domain_cache_lock:
                _domain_cache[domain] = (cached, _now + _DOMAIN_CACHE_TTL_S)
            return cached

    # 3) Clasificación por heurística (y opcionalmente LLM)
    cat, conf = _heuristic_domain_category(domain)
    source = "rule"
    if FEATURE_DOMAIN_CLASSIFIER and FEATURE_DOMAIN_CLASSIFIER_LLM and allow_llm and cat == "otros":
        cat, conf = _llm_domain_category(domain)
        source = "llm"
    db_set_domain_category(domain, cat, conf, source)
    result = db_get_domain_category(domain) or {
        "domain": _normalize_domain(domain), "category": cat, "confidence": conf,
        "source": source, "updated_at": datetime.now(timezone.utc).isoformat(),
    }
    # Guardar en caché en memoria
    with _domain_cache_lock:
        _domain_cache[domain] = (result, _now + _DOMAIN_CACHE_TTL_S)
    return result


def domain_category_breakdown(limit_batches: int = 50, top_n: int = 25) -> dict:
    stats_map = db_get_domain_stats(limit_batches=limit_batches, top_n=max(60, top_n))
    cat_counter = Counter()
    detail = []
    queue_now = work_queue.qsize()
    llm_safe_mode = (
        FEATURE_DOMAIN_CLASSIFIER
        and FEATURE_DOMAIN_CLASSIFIER_LLM
        and queue_now <= DOMAIN_CLASSIFIER_LLM_MAX_QUEUE_SIZE
    )
    llm_budget = max(0, DOMAIN_CLASSIFIER_LLM_MAX_NEW_PER_REQUEST if llm_safe_mode else 0)

    for item in stats_map.get("combined", []):
        domain = item.get("domain")
        count = int(item.get("count") or 0)
        if not domain or count <= 0:
            continue
        cached = db_get_domain_category(domain)
        allow_llm = llm_budget > 0
        refresh_cached_otros = bool(
            cached
            and str(cached.get("category") or "") == "otros"
            and str(cached.get("source") or "") != "llm"
        )

        cat_info = classify_domain(
            domain,
            allow_llm=allow_llm,
            refresh_cached_otros=allow_llm and refresh_cached_otros,
        )
        if allow_llm and str(cat_info.get("source") or "") == "llm":
            llm_budget = max(0, llm_budget - 1)

        cat = cat_info.get("category") or "otros"
        cat_counter[cat] += count
        detail.append({
            "domain": domain,
            "count": count,
            "category": cat,
            "confidence": cat_info.get("confidence", 0.5),
            "source": cat_info.get("source", "rule"),
        })
    total = sum(cat_counter.values()) or 1
    categories = [
        {"category": c, "count": n, "pct": round((n / total) * 100.0, 2)}
        for c, n in cat_counter.most_common(top_n)
    ]
    return {
        "window_batches": stats_map.get("window_batches", 0),
        "llm_classifier": {
            "enabled": FEATURE_DOMAIN_CLASSIFIER_LLM,
            "safe_mode": llm_safe_mode,
            "queue_size": queue_now,
            "max_queue_size": DOMAIN_CLASSIFIER_LLM_MAX_QUEUE_SIZE,
            "max_new_per_request": DOMAIN_CLASSIFIER_LLM_MAX_NEW_PER_REQUEST,
            "used_budget": max(0, DOMAIN_CLASSIFIER_LLM_MAX_NEW_PER_REQUEST - llm_budget) if llm_safe_mode else 0,
            "timeout_s": DOMAIN_CLASSIFIER_LLM_TIMEOUT_S,
            "n_predict": DOMAIN_CLASSIFIER_LLM_N_PREDICT,
        },
        "categories": categories,
        "domains": detail[:top_n],
    }


def _infer_device_type_from_domains(domains: set[str]) -> tuple[str, float, list[str]]:
    dset = {_normalize_domain(d) for d in domains if _normalize_domain(d)}
    reasons = []
    scores = {
        "iphone_ios": 0.0,
        "android_phone": 0.0,
        "smart_tv": 0.0,
        "laptop_dev": 0.0,
        "iot": 0.0,
    }
    for d in dset:
        if _domain_in_roots(d, {"icloud.com", "apple.com", "mzstatic.com"}):
            scores["iphone_ios"] += 1.3
            reasons.append(f"consulta {d} (ecosistema Apple)")
        if _domain_in_roots(d, {"googleapis.com", "gvt1.com", "play.googleapis.com"}):
            scores["android_phone"] += 1.1
            reasons.append(f"consulta {d} (servicios Android)")
        if _domain_in_roots(d, {"netflix.com", "nflxvideo.net", "disneyplus.com", "roku.com", "smarttv"}):
            scores["smart_tv"] += 1.4
            reasons.append(f"consulta {d} (consumo OTT/TV)")
        if _domain_in_roots(d, {"github.com", "gitlab.com", "pypi.org", "npmjs.com"}):
            scores["laptop_dev"] += 1.5
            reasons.append(f"consulta {d} (entorno desarrollo)")
        if _domain_in_roots(d, {"tuya", "iot", "ring.com", "blinkforhome.com"}):
            scores["iot"] += 1.1
            reasons.append(f"consulta {d} (patrón IoT)")

    best = max(scores.items(), key=lambda x: x[1])
    label_map = {
        "iphone_ios": "telefono_ios",
        "android_phone": "telefono_android",
        "smart_tv": "smart_tv",
        "laptop_dev": "laptop",
        "iot": "iot",
    }
    if best[1] <= 0:
        return "desconocido", 0.4, ["sin huellas suficientes de dominio"]
    confidence = min(0.97, 0.55 + (best[1] / 6.0))
    return label_map.get(best[0], "desconocido"), confidence, reasons[:4]


def infer_and_store_device_profiles(summary: dict):
    if not FEATURE_DEVICE_PROFILING:
        return
    cdc = summary.get("client_domain_counts") or {}
    if not isinstance(cdc, dict):
        return

    # Fase 4.1 — construir mapa ip→hostname y ip→mac desde dhcp_devices e ip_to_mac
    dhcp_hostname_map: dict[str, str] = {}
    for dev in (summary.get("dhcp_devices") or []):
        ip = dev.get("ip", "")
        hn = dev.get("hostname", "")
        if ip and hn and hn != "desconocido":
            dhcp_hostname_map[ip] = hn
    ip_to_mac: dict[str, str] = summary.get("ip_to_mac") or {}

    for client_ip, dom_map in cdc.items():
        if not isinstance(dom_map, dict):
            continue
        domains = set(dom_map.keys())
        if not domains:
            continue
        dtype, conf, reasons = _infer_device_type_from_domains(domains)
        hostname = dhcp_hostname_map.get(client_ip)
        mac = ip_to_mac.get(client_ip)
        if hostname:
            reasons = [f"hostname:{hostname}"] + reasons
        db_upsert_device_profile(client_ip, dtype, conf, reasons, hostname=hostname, mac=mac)


def _generate_summary_text(limit_batches: int = 6) -> tuple[str, dict]:
    history = db_get_history(limit_batches)
    if not history:
        return "Sin datos recientes de red para resumir.", {"window_batches": 0}

    packets = sum(int(x.get("packets") or 0) for x in history)
    suspicious_events = sum(int(x.get("suspicious_count") or 0) for x in history)
    devices = set()
    for item in history:
        s = item.get("summary") or {}
        for ip in (s.get("lan_devices") or []):
            devices.add(ip)

    domain_stats = db_get_domain_stats(limit_batches=limit_batches, top_n=6)
    top_domains = ", ".join([d["domain"] for d in domain_stats.get("combined", [])[:4]]) or "sin dominios destacados"
    cats = domain_category_breakdown(limit_batches=limit_batches, top_n=4).get("categories", [])
    cat_text = ", ".join([f"{c['category']} {c['pct']}%" for c in cats[:3]]) if cats else "sin categoría dominante"
    level = "baja"
    if packets > 2000:
        level = "alta"
    elif packets > 800:
        level = "moderada"
    summary_txt = (
        f"Resumen de red: {len(devices)} dispositivos activos, {packets} paquetes capturados "
        f"y {suspicious_events} eventos sospechosos en la ventana reciente. "
        f"Actividad {level}. Dominios dominantes: {top_domains}. "
        f"Categorías principales: {cat_text}."
    )
    meta = {
        "window_batches": len(history),
        "packets": packets,
        "devices": len(devices),
        "suspicious_events": suspicious_events,
        "top_domains": domain_stats.get("combined", [])[:6],
        "categories": cats,
    }
    return summary_txt, meta


def generate_and_store_summary():
    text, meta = _generate_summary_text(limit_batches=6)
    db_store_summary(text, meta=meta)
    return {"summary": text, "meta": meta}


def _generate_report_text() -> tuple[str, dict]:
    history = db_get_history(limit=120)
    alerts = db_get_alerts(limit=200)
    devices = db_get_device_profiles(limit=120)
    domain_stats = db_get_domain_stats(limit_batches=120, top_n=20)
    categories = domain_category_breakdown(limit_batches=120, top_n=8)
    total_packets = sum(int(x.get("packets") or 0) for x in history)
    suspicious = sum(int(x.get("suspicious_count") or 0) for x in history)
    top_domains = ", ".join(d["domain"] for d in domain_stats.get("combined", [])[:8]) or "N/D"
    cat_text = ", ".join(f"{c['category']} {c['pct']}%" for c in categories.get("categories", [])[:5]) or "N/D"

    report = (
        "Reporte de red\n"
        f"Dispositivos detectados: {len(devices)}\n"
        f"Dominios consultados (top): {top_domains}\n"
        f"Paquetes observados: {total_packets}\n"
        f"Eventos sospechosos: {suspicious}\n"
        f"Alertas automáticas: {len(alerts)}\n"
        f"Categorías de tráfico: {cat_text}\n"
        "Conclusión: no se confirma ataque activo sostenido, pero existen patrones que requieren monitoreo continuo."
    )
    meta = {
        "history_items": len(history),
        "alerts": len(alerts),
        "devices": len(devices),
        "total_packets": total_packets,
        "suspicious": suspicious,
        "categories": categories.get("categories", []),
    }
    return report, meta


def generate_and_store_report():
    text, meta = _generate_report_text()
    db_store_report(text, meta=meta)
    return {"report": text, "meta": meta}


# Fase 4.2 — Caché de contexto para chat (TTL 30 s, evita N round-trips a SQLite por sesión)
_CHAT_CONTEXT_TTL_S = 30
_chat_context_cache: dict | None = None
_chat_context_cache_ts: float = 0.0
_chat_context_cache_lock = threading.Lock()


def _latest_context_for_chat() -> dict:
    global _chat_context_cache, _chat_context_cache_ts
    now = time.time()
    with _chat_context_cache_lock:
        if _chat_context_cache is not None and (now - _chat_context_cache_ts) < _CHAT_CONTEXT_TTL_S:
            return _chat_context_cache

    summaries = db_get_summaries(limit=1)
    alerts = db_get_alerts(limit=12)
    categories = domain_category_breakdown(limit_batches=30, top_n=6)
    devices = db_get_device_profiles(limit=20)
    ctx = {
        "summary": summaries[-1]["summary"] if summaries else "",
        "alerts": alerts[-8:],
        "categories": categories.get("categories", []),
        "devices": devices[:10],
    }
    with _chat_context_cache_lock:
        _chat_context_cache = ctx
        _chat_context_cache_ts = now
    return ctx


def _chat_answer(question: str, session_id: str) -> tuple[str, str]:
    """Responde la pregunta del usuario usando Groq (si está habilitado) o llama.cpp.

    Returns:
        (answer_text, provider)  donde provider es "groq" o "llama".
    """
    if not FEATURE_CHAT:
        return "El chat está deshabilitado por configuración.", "llama"

    ctx = _latest_context_for_chat()
    history = db_get_chat_history(session_id, limit=12)

    # ── Ruta Groq (Qwen) ──────────────────────────────────────────────────────
    if GROQ_CHAT_ENABLED:
        system_msg = (
            "Eres TARS, un asistente SOC especializado en análisis de redes WiFi públicas. "
            "Respondes siempre en español claro y conciso. "
            "Solo usas datos del contexto provisto; nunca inventas información. "
            "Si se te pide un análisis, identifica riesgos, dispositivos sospechosos o "
            "dominios inusuales basándote únicamente en los datos de la red."
        )
        ctx_json = json.dumps(ctx, ensure_ascii=False, indent=2)
        messages: list[dict] = [{"role": "system", "content": system_msg}]

        # Inyectar contexto de red como primer mensaje de usuario oculto
        messages.append({
            "role": "user",
            "content": (
                f"[Contexto de red en tiempo real]\n{ctx_json}\n\n"
                "Usa estos datos para responder las preguntas que siguen."
            ),
        })
        messages.append({
            "role": "assistant",
            "content": "Entendido. Tengo el contexto de red cargado. ¿En qué puedo ayudarte?",
        })

        # Historial de conversación (últimos 8 turnos)
        for m in history[-8:]:
            role = m["role"] if m["role"] in ("user", "assistant") else "user"
            messages.append({"role": role, "content": m["content"]})

        # Pregunta actual
        messages.append({"role": "user", "content": question})

        ans = call_groq_chat(messages, temperature=0.7).strip()
        if ans and not ans.startswith("[Error"):
            return ans, "groq"
        log.warning("Groq falló, usando llama.cpp como fallback")

    # ── Ruta llama.cpp (fallback o único disponible) ──────────────────────────
    hist_txt = "\n".join([f"{m['role']}: {m['content']}" for m in history[-8:]])
    prompt = _wrap_prompt(
        user_body=(
            "Responde en español claro y breve como analista de red.\n"
            f"Contexto de red:\n{json.dumps(ctx, ensure_ascii=False, indent=2)}\n\n"
            f"Conversación reciente:\n{hist_txt}\n\n"
            f"Pregunta del usuario: {question}\n"
        ),
        system_text="Asistente SOC para PoC WiFi. No inventes datos fuera del contexto provisto.",
    )
    ans = call_llama(prompt, temperature=0.75, top_p=0.95).strip()
    if not ans or ans.startswith("[Error"):
        alerts = ctx.get("alerts") or []
        if alerts:
            a = alerts[-1]
            return f"Sí, hay una señal reciente: {a.get('message', 'evento sospechoso')}.", "llama"
        return "No observo alertas críticas recientes; la red parece estable en esta ventana.", "llama"
    return ans, "llama"


def build_portal_risk_message(client_ip: str) -> dict:
    if not FEATURE_PORTAL_RISK_MESSAGE:
        return {"enabled": False, "message": ""}
    alerts = db_get_alerts(limit=120)
    client_alerts = [a for a in alerts if a.get("source_ip") == client_ip]
    target = client_alerts[-1] if client_alerts else (alerts[-1] if alerts else None)
    if not target:
        return {
            "enabled": True,
            "message": "Estás conectado a una red pública. Usa HTTPS y evita iniciar sesión en servicios sensibles.",
            "severity": "info",
        }
    return {
        "enabled": True,
        "message": f"Aviso de seguridad: {target.get('message', 'actividad inusual detectada')}.",
        "severity": target.get("severity", "medium"),
        "alert_type": target.get("alert_type", "event"),
    }


def detect_social_traffic(summary: dict, whitelist: set[str] | None = None) -> dict:
    combined_counts = _combined_domain_counts(summary)
    whitelist = whitelist or set()

    per_network = {}
    matched_domains = {}
    total_hits = 0
    for domain, count in combined_counts.items():
        if _domain_in_roots(domain, whitelist):
            continue
        bucket = _social_bucket_for_domain(domain)
        if not bucket:
            continue
        per_network[bucket] = per_network.get(bucket, 0) + count
        matched_domains[domain] = matched_domains.get(domain, 0) + count
        total_hits += count

    return {
        "total_hits": total_hits,
        "per_network": per_network,
        "matched_domains": matched_domains,
    }


def detect_porn_traffic(summary: dict, whitelist: set[str] | None = None) -> dict:
    combined_counts = _combined_domain_counts(summary)
    whitelist = whitelist or set()
    matched_domains = {}
    total_hits = 0
    for domain, count in combined_counts.items():
        if _domain_in_roots(domain, whitelist):
            continue
        if not _domain_matches_roots(domain, PORN_DOMAIN_ROOTS):
            continue
        matched_domains[domain] = matched_domains.get(domain, 0) + count
        total_hits += count

    offenders = {}
    client_domain_counts = summary.get("client_domain_counts") or {}
    client_domain_dsts = summary.get("client_domain_destinations") or {}
    if isinstance(client_domain_counts, dict):
        for client_ip, dom_map in client_domain_counts.items():
            if not isinstance(dom_map, dict):
                continue
            for domain, count in dom_map.items():
                d = str(domain).lower().strip()
                if _domain_in_roots(d, whitelist):
                    continue
                if not _domain_matches_roots(d, PORN_DOMAIN_ROOTS):
                    continue
                try:
                    n = int(count)
                except Exception:
                    n = 1
                info = offenders.setdefault(client_ip, {"hits": 0, "domains": {}, "dest_ips": set()})
                info["hits"] += max(1, n)
                info["domains"][d] = info["domains"].get(d, 0) + max(1, n)
                dsts = (((client_domain_dsts.get(client_ip) or {}).get(domain)) or
                        ((client_domain_dsts.get(client_ip) or {}).get(d)) or [])
                for ip in dsts:
                    ip = str(ip).strip()
                    if re.match(r"^\d{1,3}(?:\.\d{1,3}){3}$", ip):
                        info["dest_ips"].add(ip)

    offenders_out = {}
    for ip, info in offenders.items():
        offenders_out[ip] = {
            "hits": info["hits"],
            "domains": dict(sorted(info["domains"].items(), key=lambda x: -x[1])[:20]),
            "dest_ips": sorted(info["dest_ips"]),
        }

    return {
        "total_hits": total_hits,
        "matched_domains": matched_domains,
        "offenders": offenders_out,
    }


def _extract_action_json(text: str) -> dict | None:
    if not text:
        return None
    m = re.search(r"\{.*\}", text, flags=re.S)
    if not m:
        return None
    try:
        obj = json.loads(m.group(0))
    except Exception:
        return None
    action = str(obj.get("action", "")).strip().lower()
    if action not in {"block", "unblock", "none"}:
        return None
    reason = str(obj.get("reason", "")).strip()
    return {"action": action, "reason": reason}


def evaluate_and_apply_social_policy(batch_id: int, summary: dict) -> dict:
    result = {
        "enabled": SOCIAL_BLOCK_ENABLED,
        "in_window": False,
        "should_block": False,
        "social_hits": 0,
        "action": "noop",
        "reason": "",
    }
    if not SOCIAL_BLOCK_ENABLED:
        result["reason"] = "disabled"
        return result
    if router_mcp is None:
        result["reason"] = "router_mcp_unavailable"
        return result

    try:
        local_hour = datetime.now(ZoneInfo(SOCIAL_POLICY_TZ)).hour
    except Exception:
        local_hour = datetime.now().hour
    in_window = SOCIAL_POLICY_START_HOUR <= local_hour < SOCIAL_POLICY_END_HOUR
    whitelist = db_get_whitelist_set()
    social = detect_social_traffic(summary, whitelist=whitelist)
    hits = social["total_hits"]
    should_block = in_window and hits >= SOCIAL_MIN_HITS
    base_action = "block" if should_block else ("unblock" if policy_state.get("social_block_active", False) else "none")

    # ── Short-circuit: fuera de ventana horaria la decisión es trivial ──────────
    # Si estamos fuera del horario de política Y el bloqueo no está activo →
    # nada que hacer, no vale la pena gastar tokens del LLM.
    # Si estamos fuera del horario Y el bloqueo SÍ está activo → desbloquear
    # inmediatamente sin consultar al LLM (la regla de horario es determinista).
    active_now = policy_state.get("social_block_active", False)
    if not in_window:
        result.update({
            "in_window": False,
            "should_block": False,
            "social_hits": hits,
            "social": social,
            "base_action": base_action,
            "llm_action": "skip",
            "llm_reason": "outside_time_window_short_circuit",
        })
        if active_now:
            ok, msg = router_mcp.remove_social_block()
            result["action"] = "block_off"
            result["reason"] = "outside_window_auto_unblock"
            result["router_ok"] = ok
            result["router_msg"] = msg
            if ok:
                policy_state["social_block_active"] = False
                db_store_policy_action("social_block_off", result["reason"], result)
            else:
                db_store_policy_action("social_block_off_error", result["reason"], result)
        else:
            result["action"] = "noop"
            result["reason"] = "outside_window_nothing_to_do"
        log.debug("social_policy short-circuit: fuera de ventana %d:00-%d:00, hora=%d",
                  SOCIAL_POLICY_START_HOUR, SOCIAL_POLICY_END_HOUR, local_hour)
        return result
    # ────────────────────────────────────────────────────────────────────────────

    policy_context = {
        "local_hour": local_hour,
        "timezone": SOCIAL_POLICY_TZ,
        "in_window": in_window,
        "social_hits": hits,
        "social_min_hits": SOCIAL_MIN_HITS,
        "social_per_network": social["per_network"],
        "social_domains": social["matched_domains"],
        "whitelist_domains": sorted(whitelist),
        "base_action": base_action,
        "block_active": active_now,
    }

    action_prompt = build_action_prompt(policy_context)
    action_response = call_llama(
        action_prompt,
        temperature=0.1,
        top_p=0.5,
    )
    db_log_prompt(
        prompt_type="action",
        prompt=action_prompt,
        response=action_response,
        batch_id=batch_id,
        meta={"policy_context": policy_context},
    )
    parsed = _extract_action_json(action_response)
    if parsed:
        llm_action = parsed["action"]
        llm_reason = parsed.get("reason", "")
    else:
        llm_action = base_action
        llm_reason = "fallback_base_action"

    result.update({
        "in_window": in_window,
        "should_block": should_block,
        "social_hits": hits,
        "social": social,
        "base_action": base_action,
        "llm_action": llm_action,
        "llm_reason": llm_reason,
    })

    # Refrescar estado tras la llamada al LLM (pudo cambiar en otro hilo)
    active_now = policy_state.get("social_block_active", False)
    if llm_action == "block":
        ok, msg = router_mcp.apply_social_block(SOCIAL_DOMAIN_SET)
        result["action"] = "block_refresh" if active_now else "block_on"
        result["reason"] = f"hits={hits} in_window={in_window} llm={llm_reason}"
        result["router_ok"] = ok
        result["router_msg"] = msg
        if ok:
            policy_state["social_block_active"] = True
            db_store_policy_action(
                "social_block_on" if not active_now else "social_block_refresh",
                result["reason"], result,
            )
        else:
            db_store_policy_action(
                "social_block_on_error" if not active_now else "social_block_refresh_error",
                result["reason"], result,
            )
        return result

    if llm_action == "unblock" and active_now:
        ok, msg = router_mcp.remove_social_block()
        result["action"] = "block_off"
        result["reason"] = f"hits={hits} in_window={in_window} llm={llm_reason}"
        result["router_ok"] = ok
        result["router_msg"] = msg
        if ok:
            policy_state["social_block_active"] = False
            db_store_policy_action("social_block_off", result["reason"], result)
        else:
            db_store_policy_action("social_block_off_error", result["reason"], result)
        return result

    result["action"] = "noop"
    result["reason"] = f"active={active_now} hits={hits} in_window={in_window}"
    return result


def evaluate_and_apply_porn_policy(batch_id: int, summary: dict) -> dict:
    result = {
        "enabled": PORN_BLOCK_ENABLED,
        "action": "noop",
        "reason": "",
        "porn_hits": 0,
        "domains": {},
        "offenders": {},
        "applied": [],
    }
    if not PORN_BLOCK_ENABLED:
        result["reason"] = "disabled"
        return result
    if router_mcp is None:
        result["reason"] = "router_mcp_unavailable"
        return result

    whitelist = db_get_whitelist_set()
    porn = detect_porn_traffic(summary, whitelist=whitelist)
    result["porn_hits"] = porn["total_hits"]
    result["domains"] = porn["matched_domains"]
    result["offenders"] = porn["offenders"]

    if porn["total_hits"] <= 0:
        result["reason"] = "no_porn_detected"
        return result

    global_ips = router_mcp.resolve_domains_to_ips(porn["matched_domains"].keys())
    for client_ip, info in porn["offenders"].items():
        # ── Protección de IPs de infraestructura (capa Python) ────────────────
        if client_ip in PROTECTED_IPS:
            log.warning(
                "porn_policy: IP protegida %s detectada como offender — "
                "se omite kick/warn para evitar auto-bloqueo de infraestructura.",
                client_ip,
            )
            continue
        # ─────────────────────────────────────────────────────────────────────
        ip_candidates = set(global_ips)
        for ip in info.get("dest_ips", []):
            ip_candidates.add(ip)
        ip_candidates = sorted(ip_candidates)

        block_ok, block_msg = router_mcp.block_porn_ips(ip_candidates) if ip_candidates else (False, "no_dest_ips")
        kick_ok, kick_msg = router_mcp.kick_client_from_allowed(client_ip)
        warn_ok, warn_msg = router_mcp.mark_client_warning(client_ip)
        action = {
            "client_ip": client_ip,
            "dest_ips": ip_candidates,
            "category": "porn",
            "trigger_domains": porn["matched_domains"],
            "block_ok": block_ok,
            "block_msg": block_msg,
            "kick_ok": kick_ok,
            "kick_msg": kick_msg,
            "warn_ok": warn_ok,
            "warn_msg": warn_msg,
        }
        result["applied"].append(action)
        db_store_policy_action("porn_enforcement", f"client={client_ip}", action)

    if not result["applied"] and global_ips:
        block_ok, block_msg = router_mcp.block_porn_ips(global_ips)
        action = {
            "client_ip": None,
            "dest_ips": global_ips,
            "category": "porn",
            "trigger_domains": porn["matched_domains"],
            "block_ok": block_ok,
            "block_msg": block_msg,
            "kick_ok": False,
            "kick_msg": "no_offender_client_detected",
            "warn_ok": False,
            "warn_msg": "no_offender_client_detected",
        }
        result["applied"].append(action)
        db_store_policy_action("porn_ip_block_only", "no_offender_client_detected", action)

    result["action"] = "enforced" if result["applied"] else "detected_only"
    result["reason"] = f"hits={porn['total_hits']} offenders={len(porn['offenders'])}"
    return result


# ─── Pipeline de análisis ─────────────────────────────────────────────────────
def analyze_and_store(batch_id: int, summary: dict):
    """Ejecuta prompt → llama → guarda en SQLite → broadcast SSE."""
    t0       = time.time()
    prompt   = build_analysis_prompt(summary)
    analysis = call_llama(
        prompt,
        temperature=0.4,
        top_p=0.85,
    )
    db_log_prompt(
        prompt_type="analysis",
        prompt=prompt,
        response=analysis,
        batch_id=batch_id,
        meta={"sensor_ip": summary.get("sensor_ip")},
    )
    elapsed  = round(time.time() - t0, 1)

    risk = "BAJO"
    au   = analysis.upper()
    if "ALTO" in au or "CRÍTICO" in au:
        risk = "ALTO"
    elif "MEDIO" in au or "MODERADO" in au:
        risk = "MEDIO"
    if summary.get("suspicious"):
        risk = "MEDIO" if risk == "BAJO" else risk
    policy_social = evaluate_and_apply_social_policy(batch_id, summary)
    policy_porn = evaluate_and_apply_porn_policy(batch_id, summary)
    human_explanation = build_human_explanation(summary, analysis, risk)
    behavior_alerts = detect_behavior_alerts(summary)
    infer_and_store_device_profiles(summary)
    db_store_human_explanation(
        batch_id=batch_id,
        text=human_explanation,
        meta={"risk": risk, "packets": summary.get("total_packets", 0)},
    )
    db_store_alerts(batch_id=batch_id, alerts=behavior_alerts)

    result = {
        "id":               stats["analyses_ok"] + 1,
        "batch_id":         batch_id,
        "timestamp":        datetime.now(timezone.utc).isoformat(),
        "elapsed_s":        elapsed,
        "risk":             risk,
        "analysis":         analysis,
        "suspicious_count": len(summary.get("suspicious", [])),
        "packets":          summary.get("total_packets", 0),
        "bytes_fmt":        summary.get("total_bytes_fmt", "0 B"),
        "summary":          summary,
        "suspicious":       summary.get("suspicious", []),
        "lan_devices":      summary.get("lan_devices", []),
        "dns_queries":      summary.get("dns_queries", [])[:20],
        "human_explanation": human_explanation,
        "alerts": behavior_alerts,
        "policy": {
            "social": policy_social,
            "porn": policy_porn,
        },
    }

    db_save_analysis(batch_id, result)
    stats["analyses_ok"] += 1

    _broadcast_sse(result)
    log.info(
        "Análisis batch #%d completado en %ss | riesgo=%s | policy=%s | queue=%d",
        batch_id, elapsed, risk,
        f"social:{policy_social.get('action')} porn:{policy_porn.get('action')}",
        work_queue.qsize(),
    )


# ─── Worker thread ────────────────────────────────────────────────────────────
def worker_thread():
    """Consume batch IDs de la cola y los procesa de uno en uno."""
    log.info("Worker iniciado — esperando batches en cola...")
    while True:
        batch_id = work_queue.get()
        log.info("Worker tomó batch #%d (queue restante: %d)", batch_id, work_queue.qsize())
        try:
            db_set_status(batch_id, "processing")
            conn = db_connect()
            row  = conn.execute(
                "SELECT payload FROM batches WHERE id=?", (batch_id,)
            ).fetchone()
            conn.close()

            if row:
                summary = json.loads(row["payload"])
                analyze_and_store(batch_id, summary)
            else:
                log.error("Batch #%d no encontrado en SQLite", batch_id)
                db_set_status(batch_id, "error")
        except Exception as e:
            log.error("Worker error en batch #%d: %s", batch_id, e)
            db_set_status(batch_id, "error")
            stats["analyses_error"] += 1
        finally:
            work_queue.task_done()


def _adaptive_batch_limit() -> int:
    """Fase 4.4 — Calcula cuántos batches usar en el resumen según la cola de trabajo.

    Si la cola está vacía (sistema idle) tomamos una ventana más amplia para
    que el resumen capture tendencias de mayor duración.  Si hay backlog
    (sistema ocupado) reducimos la ventana para no duplicar trabajo ya resumido.
    """
    q_size = work_queue.qsize()
    if q_size == 0:
        return 10   # idle → ventana amplia (≈ 5 min a 30 s/batch)
    elif q_size <= 3:
        return 6    # carga normal → ventana media
    elif q_size <= 8:
        return 4    # carga alta → ventana corta
    else:
        return 2    # backlog severo → solo últimos batches


def summary_worker_thread():
    if not FEATURE_AUTO_REPORTS:
        log.info("Summary worker deshabilitado")
        return
    log.info("Summary worker iniciado (intervalo_base=%ss, ventana adaptativa)", SUMMARY_INTERVAL_S)
    while True:
        try:
            limit = _adaptive_batch_limit()
            out = generate_and_store_summary()
            log.info(
                "Resumen generado (ventana=%d batches, cola=%d): %s",
                limit, work_queue.qsize(), out.get("summary", "")[:120],
            )
        except Exception as e:
            log.warning("Summary worker error: %s", e)
        # Intervalo también adaptativo: más frecuente con backlog, más lento en idle
        q_now = work_queue.qsize()
        sleep_s = max(20, SUMMARY_INTERVAL_S // 2) if q_now > 5 else max(20, SUMMARY_INTERVAL_S)
        time.sleep(sleep_s)


def enqueue_batch(summary: dict) -> int:
    """Guarda batch en SQLite y lo encola para análisis."""
    stats["batches_received"] += 1
    batch_id = db_store_batch(summary)
    work_queue.put(batch_id)
    log.info(
        "Batch #%d en cola | sensor=%s | paquetes=%d | queue=%d",
        batch_id,
        summary.get("sensor_ip", "?"),
        summary.get("total_packets", 0),
        work_queue.qsize(),
    )
    return batch_id


# ─── SSE broadcast ────────────────────────────────────────────────────────────
def _broadcast_sse(result: dict):
    data = json.dumps(result, ensure_ascii=False)
    with sse_lock:
        dead = []
        for q in sse_queues:
            try:
                q.put_nowait(data)
            except queue.Full:
                dead.append(q)
        for q in dead:
            sse_queues.remove(q)


# ─── MQTT subscriber ──────────────────────────────────────────────────────────
def on_mqtt_connect(client, userdata, flags, rc):
    if rc == 0:
        stats["mqtt_connected"] = True
        log.info("MQTT conectado a %s:%d", MQTT_HOST, MQTT_PORT)
        client.subscribe(MQTT_TOPIC, qos=1)
        log.info("Suscrito a topic: %s", MQTT_TOPIC)
    else:
        log.warning("MQTT connection failed rc=%d", rc)


def on_mqtt_disconnect(client, userdata, rc):
    stats["mqtt_connected"] = False
    log.warning("MQTT desconectado (rc=%d) — reconectando...", rc)


def on_mqtt_message(client, userdata, msg):
    try:
        summary = json.loads(msg.payload.decode())
        enqueue_batch(summary)
    except json.JSONDecodeError as e:
        log.error("MQTT mensaje JSON inválido: %s", e)
    except Exception as e:
        log.error("MQTT on_message error: %s", e)


def init_mqtt() -> mqtt.Client:
    client = mqtt.Client(client_id="raspi4b-analyzer", clean_session=True)
    client.on_connect    = on_mqtt_connect
    client.on_disconnect = on_mqtt_disconnect
    client.on_message    = on_mqtt_message
    client.reconnect_delay_set(min_delay=2, max_delay=30)
    try:
        client.connect(MQTT_HOST, MQTT_PORT, keepalive=60)
    except Exception as e:
        log.warning("MQTT inicial no disponible: %s — reintentando en background", e)
    client.loop_start()
    return client


# ─── HTTP Server ──────────────────────────────────────────────────────────────
class AnalyzerHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        log.debug("HTTP %s", fmt % args)

    def send_json(self, data, status=200):
        body = json.dumps(data, ensure_ascii=False, indent=2).encode()
        self.send_response(status)
        self.send_header("Content-Type",   "application/json")
        self.send_header("Content-Length", len(body))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def send_error_json(self, status, msg):
        self.send_json({"error": msg}, status)

    def _serve_html(self, filename: str):
        filepath = STATIC_DIR / filename
        try:
            body = filepath.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type",   "text/html; charset=utf-8")
            self.send_header("Content-Length", len(body))
            self.send_header("Cache-Control",  "no-cache")
            self.end_headers()
            self.wfile.write(body)
        except FileNotFoundError:
            self.send_error_json(404, f"Archivo no encontrado: {filename}")

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin",  "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def do_GET(self):
        parsed = urlparse(self.path)
        path   = parsed.path
        params = parse_qs(parsed.query)

        if path in ("/dashboard", "/dashboard/"):
            self._serve_html("dashboard.html"); return

        if path in ("/terminal", "/terminal/"):
            self._serve_html("terminal.html"); return

        if path in ("/rulez", "/rulez/"):
            self._serve_html("rulez.html"); return

        if path in ("/chat", "/chat/"):
            self._serve_html("chat.html"); return

        if path in ("/reports", "/reports/"):
            self._serve_html("reports.html"); return

        if path == "/health":
            llama_ok = False
            try:
                r = requests.get(f"{LLAMA_URL}/health", timeout=3)
                llama_ok = r.status_code == 200
            except Exception:
                pass
            chat_provider = "groq" if GROQ_CHAT_ENABLED else "llama"
            self.send_json({
                "status":        "ok",
                "llama_url":     LLAMA_URL,
                "llama_ok":      llama_ok,
                "model_format":  MODEL_FORMAT,
                "n_predict":     N_PREDICT,
                "mqtt_host":     MQTT_HOST,
                "mqtt_connected": stats["mqtt_connected"],
                "db_path":       DB_PATH,
                "queue":         db_queue_stats(),
                "stats":         stats,
                "groq_enabled":  GROQ_CHAT_ENABLED,
                "groq_model":    GROQ_MODEL if GROQ_CHAT_ENABLED else None,
                "chat_provider": chat_provider,
                "policy": {
                    "social_block_enabled": SOCIAL_BLOCK_ENABLED,
                    "social_block_active": policy_state.get("social_block_active", False),
                    "porn_block_enabled": PORN_BLOCK_ENABLED,
                    "window": {
                        "start_hour": SOCIAL_POLICY_START_HOUR,
                        "end_hour": SOCIAL_POLICY_END_HOUR,
                        "timezone": SOCIAL_POLICY_TZ,
                    },
                    "min_hits": SOCIAL_MIN_HITS,
                },
                "features": {
                    "human_explain": FEATURE_HUMAN_EXPLAIN,
                    "domain_classifier": FEATURE_DOMAIN_CLASSIFIER,
                    "domain_classifier_llm": FEATURE_DOMAIN_CLASSIFIER_LLM,
                    "domain_classifier_llm_max_new_per_request": DOMAIN_CLASSIFIER_LLM_MAX_NEW_PER_REQUEST,
                    "domain_classifier_llm_timeout_s": DOMAIN_CLASSIFIER_LLM_TIMEOUT_S,
                    "domain_classifier_llm_n_predict": DOMAIN_CLASSIFIER_LLM_N_PREDICT,
                    "domain_classifier_llm_max_queue_size": DOMAIN_CLASSIFIER_LLM_MAX_QUEUE_SIZE,
                    "portal_risk_message": FEATURE_PORTAL_RISK_MESSAGE,
                    "chat": FEATURE_CHAT,
                    "device_profiling": FEATURE_DEVICE_PROFILING,
                    "auto_reports": FEATURE_AUTO_REPORTS,
                },
            })

        elif path == "/api/history":
            limit = int(params.get("limit", ["50"])[0])
            items = db_get_history(limit)
            self.send_json({"count": len(items), "items": items})

        elif path == "/api/queue":
            self.send_json(db_queue_stats())

        elif path == "/api/stats":
            self.send_json({**stats, "queue": db_queue_stats()})

        elif path == "/api/explanations/latest":
            limit = int(params.get("limit", ["20"])[0])
            items = db_get_human_explanations(limit=limit)
            self.send_json({"count": len(items), "items": items})

        elif path == "/api/alerts":
            limit = int(params.get("limit", ["80"])[0])
            items = db_get_alerts(limit=limit)
            self.send_json({"count": len(items), "items": items})

        elif path == "/api/domain-categories/top":
            limit_batches = int(params.get("limit_batches", ["50"])[0])
            top = int(params.get("top", ["25"])[0])
            self.send_json(domain_category_breakdown(limit_batches=limit_batches, top_n=top))

        elif path == "/api/devices/profile":
            limit = int(params.get("limit", ["100"])[0])
            items = db_get_device_profiles(limit=limit)
            self.send_json({"count": len(items), "items": items})

        elif path == "/api/summaries/latest":
            limit = int(params.get("limit", ["20"])[0])
            items = db_get_summaries(limit=limit)
            self.send_json({"count": len(items), "items": items})

        elif path == "/api/reports/latest":
            limit = int(params.get("limit", ["10"])[0])
            items = db_get_reports(limit=limit)
            self.send_json({"count": len(items), "items": items})

        elif path == "/api/portal/risk-message":
            ip = str(params.get("ip", [""])[0]).strip()
            self.send_json(build_portal_risk_message(ip))

        elif path == "/api/chat/history":
            session_id = str(params.get("session_id", [""])[0]).strip()
            if not session_id:
                self.send_error_json(400, "session_id requerido")
                return
            limit = int(params.get("limit", ["40"])[0])
            items = db_get_chat_history(session_id, limit=limit)
            self.send_json({"session_id": session_id, "count": len(items), "items": items})

        elif path == "/api/policy":
            limit = int(params.get("limit", ["50"])[0])
            self.send_json({
                "state": policy_state,
                "config": {
                    "enabled": SOCIAL_BLOCK_ENABLED,
                    "porn_enabled": PORN_BLOCK_ENABLED,
                    "start_hour": SOCIAL_POLICY_START_HOUR,
                    "end_hour": SOCIAL_POLICY_END_HOUR,
                    "timezone": SOCIAL_POLICY_TZ,
                    "min_hits": SOCIAL_MIN_HITS,
                },
                "actions": db_get_policy_actions(limit),
            })

        elif path == "/api/policy/blocked-sites":
            limit = int(params.get("limit", ["80"])[0])
            self.send_json({
                "count": limit,
                "items": db_get_blocked_site_events(limit=limit),
            })

        elif path == "/api/domain-stats":
            limit_batches = int(params.get("limit_batches", ["50"])[0])
            top_n = int(params.get("top", ["20"])[0])
            self.send_json(db_get_domain_stats(limit_batches=limit_batches, top_n=top_n))

        elif path == "/api/rulez":
            self.send_json({"rules": db_get_rules()})

        elif path == "/api/mcp/whitelist":
            items = db_get_whitelist()
            self.send_json({"items": items, "count": len(items)})

        elif path == "/api/mcp/capabilities":
            if router_mcp is None:
                self.send_json({"error": "router_mcp_unavailable"}, status=503)
            else:
                self.send_json(router_mcp.mcp_capabilities())

        elif path == "/api/mcp/resources":
            if router_mcp is None:
                self.send_json({"error": "router_mcp_unavailable"}, status=503)
            else:
                resources = router_mcp.mcp_resources()
                resources["whitelist"] = db_get_whitelist()
                self.send_json(resources)

        elif path == "/api/prompt-logs":
            limit = int(params.get("limit", ["50"])[0])
            ptype = params.get("type", [None])[0]
            self.send_json({
                "count": limit,
                "type": ptype,
                "items": db_get_prompt_logs(limit=limit, prompt_type=ptype),
            })

        elif path == "/api/stream":
            q = queue.Queue(maxsize=50)
            with sse_lock:
                sse_queues.append(q)

            self.send_response(200)
            self.send_header("Content-Type",                "text/event-stream")
            self.send_header("Cache-Control",               "no-cache")
            self.send_header("Connection",                  "keep-alive")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()

            # Contexto inicial: últimos 5 análisis
            try:
                for item in db_get_history(5):
                    self.wfile.write(
                        f"data: {json.dumps(item, ensure_ascii=False)}\n\n".encode()
                    )
                self.wfile.flush()
            except Exception:
                pass

            try:
                while True:
                    try:
                        data = q.get(timeout=30)
                        self.wfile.write(f"data: {data}\n\n".encode())
                        self.wfile.flush()
                    except queue.Empty:
                        self.wfile.write(b": keepalive\n\n")
                        self.wfile.flush()
            except Exception:
                pass
            finally:
                with sse_lock:
                    if q in sse_queues:
                        sse_queues.remove(q)

        else:
            self.send_error_json(404, f"Ruta no encontrada: {path}")

    def do_POST(self):
        parsed = urlparse(self.path)
        path   = parsed.path

        if path == "/api/rulez":
            length = int(self.headers.get("Content-Length", 0))
            if length == 0:
                self.send_error_json(400, "Body vacío"); return
            try:
                payload = json.loads(self.rfile.read(length))
            except json.JSONDecodeError as e:
                self.send_error_json(400, f"JSON inválido: {e}"); return

            key = str(payload.get("key", "")).strip()
            value = str(payload.get("value", "")).strip()
            if key not in {RULE_ANALYSIS_KEY, RULE_ACTION_KEY, RULE_HUMAN_EXPLAIN_KEY}:
                self.send_error_json(400, "key inválida"); return
            if not value:
                self.send_error_json(400, "value vacío"); return
            db_set_rule(key, value)
            self.send_json({"ok": True, "rules": db_get_rules()})
            return

        if path == "/api/mcp/whitelist":
            length = int(self.headers.get("Content-Length", 0))
            if length == 0:
                self.send_error_json(400, "Body vacío"); return
            try:
                payload = json.loads(self.rfile.read(length))
            except json.JSONDecodeError as e:
                self.send_error_json(400, f"JSON inválido: {e}"); return
            op = str(payload.get("op", "")).strip().lower()
            domain = str(payload.get("domain", "")).strip()
            reason = str(payload.get("reason", "")).strip()
            if op not in {"add", "remove"}:
                self.send_error_json(400, "op inválido (add|remove)"); return
            if not domain:
                self.send_error_json(400, "domain requerido"); return
            if op == "add":
                db_whitelist_add(domain, reason=reason or "manual")
            else:
                db_whitelist_remove(domain)
            items = db_get_whitelist()
            self.send_json({"ok": True, "count": len(items), "items": items})
            return

        if path == "/api/reports/generate":
            out = generate_and_store_report()
            self.send_json({"ok": True, **out})
            return

        if path == "/api/chat":
            if not FEATURE_CHAT:
                self.send_error_json(503, "chat deshabilitado")
                return
            length = int(self.headers.get("Content-Length", 0))
            if length == 0:
                self.send_error_json(400, "Body vacío"); return
            try:
                payload = json.loads(self.rfile.read(length))
            except json.JSONDecodeError as e:
                self.send_error_json(400, f"JSON inválido: {e}"); return
            question = str(payload.get("question", "")).strip()
            session_id = str(payload.get("session_id", "")).strip() or f"chat-{uuid4().hex[:12]}"
            if not question:
                self.send_error_json(400, "question requerida"); return
            db_store_chat_message(session_id, "user", question)
            answer, chat_provider = _chat_answer(question, session_id)
            db_store_chat_message(session_id, "assistant", answer,
                                  meta={"provider": chat_provider})
            self.send_json({
                "ok":        True,
                "session_id": session_id,
                "answer":    answer,
                "provider":  chat_provider,
                "history":   db_get_chat_history(session_id, limit=20),
            })
            return

        if path == "/api/ingest":
            length = int(self.headers.get("Content-Length", 0))
            if length == 0:
                self.send_error_json(400, "Body vacío"); return
            try:
                summary = json.loads(self.rfile.read(length))
            except json.JSONDecodeError as e:
                self.send_error_json(400, f"JSON inválido: {e}"); return

            batch_id = enqueue_batch(summary)
            self.send_json({
                "status":    "accepted",
                "batch_id":  batch_id,
                "queue_pos": work_queue.qsize(),
            })
        else:
            self.send_error_json(404, f"Ruta no encontrada: {path}")


# ─── Main ─────────────────────────────────────────────────────────────────────
def main():
    global router_mcp
    log.info("=" * 60)
    log.info("AI Analyzer — Raspi 4B")
    log.info("  Puerto HTTP  : %d", PORT)
    log.info("  MQTT broker  : %s:%d  topic=%s", MQTT_HOST, MQTT_PORT, MQTT_TOPIC)
    log.info("  SQLite DB    : %s", DB_PATH)
    log.info("  llama.cpp    : %s", LLAMA_URL)
    log.info(
        "  Social policy: enabled=%s window=%02d-%02d tz=%s min_hits=%d",
        SOCIAL_BLOCK_ENABLED,
        SOCIAL_POLICY_START_HOUR,
        SOCIAL_POLICY_END_HOUR,
        SOCIAL_POLICY_TZ,
        SOCIAL_MIN_HITS,
    )
    log.info("  Porn policy  : enabled=%s", PORN_BLOCK_ENABLED)
    log.info("=" * 60)

    init_db()

    try:
        router_mcp = RouterMCP(
            router_ip=ROUTER_IP,
            router_user=ROUTER_USER,
            ssh_key=SSH_KEY,
            portal_ip=PORTAL_IP,
            bypass_ips=[ADMIN_IP, RASPI4B_IP, RASPI3B_IP, PORTAL_NODE_IP, AP_EXTENDER_IP],
            logger=log,
        )
        ok, msg = router_mcp.ensure_policy_objects()
        if not ok:
            log.warning("Router MCP: no se pudieron asegurar sets/rules de policy: %s", msg)
        policy_state["social_block_active"] = router_mcp.is_social_block_active()
        log.info(
            "Router MCP listo | social_block_active=%s",
            policy_state["social_block_active"],
        )
    except Exception as e:
        log.warning("No se pudo iniciar Router MCP: %s", e)
        router_mcp = None

    # Reencolar batches pending de reinicios anteriores
    conn   = db_connect()
    orphan = conn.execute(
        "SELECT id FROM batches WHERE status IN ('pending','processing') ORDER BY id"
    ).fetchall()
    conn.close()
    if orphan:
        log.info("Reencolando %d batches pendientes de sesión anterior...", len(orphan))
        for row in orphan:
            work_queue.put(row["id"])

    # Verificar llama.cpp
    try:
        r = requests.get(f"{LLAMA_URL}/health", timeout=5)
        log.info("llama.cpp: OK") if r.status_code == 200 \
            else log.warning("llama.cpp: HTTP %d", r.status_code)
    except Exception as e:
        log.warning("llama.cpp no disponible: %s", e)

    # Iniciar worker (un solo hilo — procesa de uno en uno)
    t = threading.Thread(target=worker_thread, daemon=True, name="worker")
    t.start()

    # Worker de resúmenes automáticos (cada 60s por defecto)
    ts = threading.Thread(target=summary_worker_thread, daemon=True, name="summary-worker")
    ts.start()

    # Iniciar MQTT subscriber
    init_mqtt()

    # Iniciar servidor HTTP
    server = HTTPServer(("0.0.0.0", PORT), AnalyzerHandler)
    log.info("HTTP listo en 0.0.0.0:%d", PORT)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("Deteniendo analyzer...")
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
