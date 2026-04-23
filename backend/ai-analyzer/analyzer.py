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

        CREATE INDEX IF NOT EXISTS idx_batches_status   ON batches(status);
        CREATE INDEX IF NOT EXISTS idx_analyses_batch   ON analyses(batch_id);
        CREATE INDEX IF NOT EXISTS idx_analyses_created ON analyses(timestamp DESC);
        CREATE INDEX IF NOT EXISTS idx_policy_created   ON policy_actions(timestamp DESC);
        CREATE INDEX IF NOT EXISTS idx_prompt_type      ON model_prompt_logs(prompt_type, id DESC);
    """)
    now = datetime.now(timezone.utc).isoformat()
    conn.execute(
        "INSERT OR IGNORE INTO ai_rules (key,value,updated_at) VALUES (?,?,?)",
        (RULE_ANALYSIS_KEY, DEFAULT_ANALYSIS_PROMPT_TEMPLATE, now),
    )
    conn.execute(
        "INSERT OR IGNORE INTO ai_rules (key,value,updated_at) VALUES (?,?,?)",
        (RULE_ACTION_KEY, DEFAULT_ACTION_PROMPT_TEMPLATE, now),
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
    """Cuerpo del prompt — formato compacto ~120 tokens, válido para cualquier modelo."""
    duration = summary.get("duration_seconds", 30)
    packets  = summary.get("total_packets", 0)
    bfmt     = summary.get("total_bytes_fmt", "0B")
    pps      = summary.get("pps", 0)

    proto_str = ",".join(
        f"{k}:{v}" for k, v in sorted(
            summary.get("protocols", {}).items(), key=lambda x: -x[1]
        )[:3]
    ) or "-"

    talkers_str = ",".join(
        t["ip"] for t in summary.get("top_talkers", [])[:3]
    ) or "-"

    ports_str = ",".join(
        str(p["port"]) for p in summary.get("top_dst_ports", [])[:4]
    ) or "-"

    dns_str = ",".join(summary.get("dns_queries", [])[:4]) or "-"

    suspicious = summary.get("suspicious", [])[:3]
    susp_str = "; ".join(
        f"[{s['type'].upper()}]{s.get('src', s.get('port','?'))}"
        for s in suspicious
    ) if suspicious else "-"

    return (
        f"WiFi {duration}s: pkt={packets} pps={pps} bytes={bfmt}\n"
        f"Proto:{proto_str}\n"
        f"IPs:{talkers_str}\n"
        f"Ports:{ports_str}\n"
        f"DNS:{dns_str}\n"
        f"Alertas:{susp_str}\n"
    )


def build_analysis_prompt(summary: dict) -> str:
    traffic = _prompt_body(summary)
    tpl = db_get_rule(RULE_ANALYSIS_KEY, DEFAULT_ANALYSIS_PROMPT_TEMPLATE)
    user_body = _safe_format(tpl, {"traffic": traffic})
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
    }
    user_body = _safe_format(tpl, ctx)
    return _wrap_prompt(
        user_body=user_body,
        system_text="Motor de decisión de políticas de red. Entrega salida en JSON estricto.",
    )


# ─── llama.cpp ───────────────────────────────────────────────────────────────
def call_llama(prompt: str) -> str:
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
                "n_predict":   N_PREDICT,
                "temperature": 0.7,
                "top_p":       0.9,
                "stop":        stop_tokens,
                "stream":      False,
            },
            timeout=120,
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
        "block_active": policy_state.get("social_block_active", False),
    }

    action_prompt = build_action_prompt(policy_context)
    action_response = call_llama(action_prompt)
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

    active = policy_state.get("social_block_active", False)
    if llm_action == "block":
        ok, msg = router_mcp.apply_social_block(SOCIAL_DOMAIN_SET)
        result["action"] = "block_refresh" if active else "block_on"
        result["reason"] = f"hits={hits} in_window={in_window} llm={llm_reason}"
        result["router_ok"] = ok
        result["router_msg"] = msg
        if ok:
            policy_state["social_block_active"] = True
            db_store_policy_action("social_block_on" if not active else "social_block_refresh", result["reason"], result)
        else:
            db_store_policy_action("social_block_on_error" if not active else "social_block_refresh_error", result["reason"], result)
        return result

    if llm_action == "unblock" and active:
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
    result["reason"] = f"active={active} hits={hits} in_window={in_window}"
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
    analysis = call_llama(prompt)
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

        if path == "/health":
            llama_ok = False
            try:
                r = requests.get(f"{LLAMA_URL}/health", timeout=3)
                llama_ok = r.status_code == 200
            except Exception:
                pass
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
            })

        elif path == "/api/history":
            limit = int(params.get("limit", ["50"])[0])
            items = db_get_history(limit)
            self.send_json({"count": len(items), "items": items})

        elif path == "/api/queue":
            self.send_json(db_queue_stats())

        elif path == "/api/stats":
            self.send_json({**stats, "queue": db_queue_stats()})

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
            if key not in {RULE_ANALYSIS_KEY, RULE_ACTION_KEY}:
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
