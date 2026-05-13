"""
database.py — SQLite: esquema, conexión y todas las operaciones CRUD.
Usa WAL mode para permitir lecturas concurrentes con escrituras del worker.
"""
from __future__ import annotations

import json
import pathlib
import sqlite3
from contextlib import contextmanager
from datetime import datetime, timezone
from typing import Any

from .config import DB_PATH

# ── Schema SQL ────────────────────────────────────────────────────────────────
_SCHEMA = """
PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;

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

CREATE TABLE IF NOT EXISTS network_alerts (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    batch_id    INTEGER NOT NULL REFERENCES batches(id),
    timestamp   TEXT    NOT NULL,
    severity    TEXT    NOT NULL,
    alert_type  TEXT    NOT NULL,
    message     TEXT    NOT NULL,
    source_ip   TEXT,
    domain      TEXT,
    details     TEXT
);

CREATE TABLE IF NOT EXISTS policy_actions (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp   TEXT NOT NULL,
    action      TEXT NOT NULL,
    reason      TEXT,
    details     TEXT
);

CREATE TABLE IF NOT EXISTS domain_whitelist (
    domain      TEXT PRIMARY KEY,
    reason      TEXT,
    created_at  TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS domain_categories (
    domain      TEXT PRIMARY KEY,
    category    TEXT NOT NULL,
    confidence  REAL NOT NULL DEFAULT 0.5,
    source      TEXT NOT NULL DEFAULT 'rule',
    updated_at  TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS device_profiles (
    ip          TEXT PRIMARY KEY,
    device_type TEXT NOT NULL,
    confidence  REAL NOT NULL DEFAULT 0.5,
    reasons     TEXT,
    updated_at  TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS human_explanations (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    batch_id   INTEGER NOT NULL REFERENCES batches(id),
    timestamp  TEXT NOT NULL,
    text       TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS chat_sessions (
    session_id TEXT PRIMARY KEY,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS chat_messages (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL,
    timestamp  TEXT NOT NULL,
    role       TEXT NOT NULL,
    content    TEXT NOT NULL,
    meta       TEXT
);

CREATE TABLE IF NOT EXISTS network_summaries (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TEXT NOT NULL,
    summary   TEXT NOT NULL,
    meta      TEXT
);

CREATE TABLE IF NOT EXISTS network_reports (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TEXT NOT NULL,
    report    TEXT NOT NULL,
    meta      TEXT
);

CREATE TABLE IF NOT EXISTS anomalies_detected (
    id                   INTEGER PRIMARY KEY AUTOINCREMENT,
    batch_id             INTEGER NOT NULL,
    device_ip            TEXT    NOT NULL,
    timestamp            TEXT    NOT NULL,
    bytes_per_sec        REAL    NOT NULL DEFAULT 0,
    typical_bytes_per_sec REAL   NOT NULL DEFAULT 0,
    stddev               REAL    NOT NULL DEFAULT 0,
    z_score              REAL    NOT NULL DEFAULT 0,
    description          TEXT
);

CREATE INDEX IF NOT EXISTS idx_batches_status   ON batches(status);
CREATE INDEX IF NOT EXISTS idx_analyses_batch   ON analyses(batch_id);
CREATE INDEX IF NOT EXISTS idx_alerts_batch     ON network_alerts(batch_id);
CREATE INDEX IF NOT EXISTS idx_alerts_severity  ON network_alerts(severity, timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_chat_session     ON chat_messages(session_id, timestamp);
"""

# ── Conexión ──────────────────────────────────────────────────────────────────

def _connect() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH, check_same_thread=False, timeout=10)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    return conn

@contextmanager
def get_db():
    conn = _connect()
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()

def init_db():
    pathlib.Path(DB_PATH).parent.mkdir(parents=True, exist_ok=True)
    with get_db() as conn:
        conn.executescript(_SCHEMA)

def now() -> str:
    return datetime.now(timezone.utc).isoformat()

def _rows(rows) -> list[dict]:
    return [dict(r) for r in rows]

# ── Batches ───────────────────────────────────────────────────────────────────

def batch_insert(sensor_ip: str, payload: str) -> int:
    with get_db() as conn:
        cur = conn.execute(
            "INSERT INTO batches (received_at, sensor_ip, status, payload) VALUES (?,?,?,?)",
            (now(), sensor_ip, "pending", payload),
        )
        return cur.lastrowid

def batch_set_status(batch_id: int, status: str):
    with get_db() as conn:
        conn.execute("UPDATE batches SET status=? WHERE id=?", (status, batch_id))

def batch_count() -> int:
    with get_db() as conn:
        return conn.execute("SELECT COUNT(*) FROM batches").fetchone()[0]

def batch_count_pending() -> int:
    with get_db() as conn:
        return conn.execute(
            "SELECT COUNT(*) FROM batches WHERE status='pending'"
        ).fetchone()[0]

def batch_get_payload(batch_id: int) -> str | None:
    with get_db() as conn:
        row = conn.execute(
            "SELECT payload FROM batches WHERE id=?", (batch_id,)
        ).fetchone()
        return row[0] if row else None

# ── Analyses ──────────────────────────────────────────────────────────────────

def analysis_insert(batch_id: int, risk: str, analysis: str, elapsed_s: float,
                    suspicious_count: int = 0, packets: int = 0, bytes_fmt: str = "0 B"):
    with get_db() as conn:
        conn.execute(
            """INSERT INTO analyses
               (batch_id, timestamp, risk, analysis, elapsed_s, suspicious_count, packets, bytes_fmt)
               VALUES (?,?,?,?,?,?,?,?)""",
            (batch_id, now(), risk, analysis, elapsed_s, suspicious_count, packets, bytes_fmt),
        )

def analysis_list_recent(limit: int = 20) -> list[dict]:
    with get_db() as conn:
        rows = conn.execute(
            "SELECT * FROM analyses ORDER BY id DESC LIMIT ?", (limit,)
        ).fetchall()
        return _rows(rows)

def analysis_count() -> int:
    with get_db() as conn:
        return conn.execute("SELECT COUNT(*) FROM analyses").fetchone()[0]

def analysis_count_by_risk() -> dict:
    with get_db() as conn:
        rows = conn.execute(
            "SELECT risk, COUNT(*) as cnt FROM analyses GROUP BY risk"
        ).fetchall()
        return {r["risk"]: r["cnt"] for r in rows}

# ── Alerts ────────────────────────────────────────────────────────────────────

def alert_insert(batch_id: int, severity: str, alert_type: str, message: str,
                 source_ip: str = "", domain: str = "", details: Any = None):
    det = json.dumps(details, ensure_ascii=False) if details else None
    with get_db() as conn:
        conn.execute(
            """INSERT INTO network_alerts
               (batch_id, timestamp, severity, alert_type, message, source_ip, domain, details)
               VALUES (?,?,?,?,?,?,?,?)""",
            (batch_id, now(), severity, alert_type, message, source_ip, domain, det),
        )

def alert_list_recent(limit: int = 50) -> list[dict]:
    with get_db() as conn:
        rows = conn.execute(
            "SELECT * FROM network_alerts ORDER BY id DESC LIMIT ?", (limit,)
        ).fetchall()
        return _rows(rows)

def alert_count_by_severity() -> dict:
    with get_db() as conn:
        rows = conn.execute(
            "SELECT severity, COUNT(*) as cnt FROM network_alerts GROUP BY severity"
        ).fetchall()
        return {r["severity"]: r["cnt"] for r in rows}

# ── Policy actions ────────────────────────────────────────────────────────────

def action_insert(action: str, reason: str, details: Any = None):
    det = json.dumps(details, ensure_ascii=False) if details else None
    with get_db() as conn:
        conn.execute(
            "INSERT INTO policy_actions (timestamp, action, reason, details) VALUES (?,?,?,?)",
            (now(), action, reason, det),
        )

def action_list_recent(limit: int = 50) -> list[dict]:
    with get_db() as conn:
        rows = conn.execute(
            "SELECT * FROM policy_actions ORDER BY id DESC LIMIT ?", (limit,)
        ).fetchall()
        return _rows(rows)

# ── Whitelist ─────────────────────────────────────────────────────────────────

def whitelist_add(domain: str, reason: str = ""):
    with get_db() as conn:
        conn.execute(
            "INSERT OR IGNORE INTO domain_whitelist (domain, reason, created_at) VALUES (?,?,?)",
            (domain, reason, now()),
        )

def whitelist_remove(domain: str):
    with get_db() as conn:
        conn.execute("DELETE FROM domain_whitelist WHERE domain=?", (domain,))

def whitelist_list() -> list[dict]:
    with get_db() as conn:
        rows = conn.execute(
            "SELECT * FROM domain_whitelist ORDER BY domain"
        ).fetchall()
        return _rows(rows)

def whitelist_set() -> set[str]:
    with get_db() as conn:
        rows = conn.execute("SELECT domain FROM domain_whitelist").fetchall()
        return {r[0] for r in rows}

# ── Domain categories ─────────────────────────────────────────────────────────

def domain_category_upsert(domain: str, category: str, confidence: float, source: str):
    with get_db() as conn:
        conn.execute(
            """INSERT INTO domain_categories (domain, category, confidence, source, updated_at)
               VALUES (?,?,?,?,?)
               ON CONFLICT(domain) DO UPDATE SET
                 category=excluded.category,
                 confidence=excluded.confidence,
                 source=excluded.source,
                 updated_at=excluded.updated_at""",
            (domain, category, confidence, source, now()),
        )

def domain_category_get(domain: str) -> str | None:
    with get_db() as conn:
        row = conn.execute(
            "SELECT category FROM domain_categories WHERE domain=?", (domain,)
        ).fetchone()
        return row[0] if row else None

# ── Device profiles ───────────────────────────────────────────────────────────

def device_profile_upsert(ip: str, device_type: str, confidence: float, reasons: list[str]):
    with get_db() as conn:
        conn.execute(
            """INSERT INTO device_profiles (ip, device_type, confidence, reasons, updated_at)
               VALUES (?,?,?,?,?)
               ON CONFLICT(ip) DO UPDATE SET
                 device_type=excluded.device_type,
                 confidence=excluded.confidence,
                 reasons=excluded.reasons,
                 updated_at=excluded.updated_at""",
            (ip, device_type, confidence, json.dumps(reasons), now()),
        )

def device_profile_list() -> list[dict]:
    with get_db() as conn:
        rows = conn.execute(
            "SELECT * FROM device_profiles ORDER BY updated_at DESC"
        ).fetchall()
        result = []
        for r in rows:
            d = dict(r)
            try:
                d["reasons"] = json.loads(d["reasons"] or "[]")
            except Exception:
                d["reasons"] = []
            result.append(d)
        return result

# ── Human explanations ────────────────────────────────────────────────────────

def human_explanation_insert(batch_id: int, text: str):
    with get_db() as conn:
        conn.execute(
            "INSERT INTO human_explanations (batch_id, timestamp, text) VALUES (?,?,?)",
            (batch_id, now(), text),
        )

# ── Chat ──────────────────────────────────────────────────────────────────────

def chat_session_upsert(session_id: str):
    ts = now()
    with get_db() as conn:
        conn.execute(
            """INSERT INTO chat_sessions (session_id, created_at, updated_at) VALUES (?,?,?)
               ON CONFLICT(session_id) DO UPDATE SET updated_at=excluded.updated_at""",
            (session_id, ts, ts),
        )

def chat_message_insert(session_id: str, role: str, content: str, meta: Any = None):
    with get_db() as conn:
        conn.execute(
            """INSERT INTO chat_messages (session_id, timestamp, role, content, meta)
               VALUES (?,?,?,?,?)""",
            (session_id, now(), role, content,
             json.dumps(meta, ensure_ascii=False) if meta else None),
        )

def chat_history(session_id: str, limit: int = 20) -> list[dict]:
    with get_db() as conn:
        rows = conn.execute(
            """SELECT role, content, timestamp FROM chat_messages
               WHERE session_id=? ORDER BY id DESC LIMIT ?""",
            (session_id, limit),
        ).fetchall()
        return list(reversed(_rows(rows)))

def chat_session_clear(session_id: str):
    with get_db() as conn:
        conn.execute("DELETE FROM chat_messages WHERE session_id=?", (session_id,))
        conn.execute("DELETE FROM chat_sessions WHERE session_id=?", (session_id,))

# ── Summaries / Reports ───────────────────────────────────────────────────────

def summary_insert(summary: str, meta: Any = None):
    with get_db() as conn:
        conn.execute(
            "INSERT INTO network_summaries (timestamp, summary, meta) VALUES (?,?,?)",
            (now(), summary, json.dumps(meta) if meta else None),
        )

def summary_list_recent(limit: int = 10) -> list[dict]:
    with get_db() as conn:
        rows = conn.execute(
            "SELECT * FROM network_summaries ORDER BY id DESC LIMIT ?", (limit,)
        ).fetchall()
        return _rows(rows)

def report_list_recent(limit: int = 10) -> list[dict]:
    with get_db() as conn:
        rows = conn.execute(
            "SELECT * FROM network_reports ORDER BY id DESC LIMIT ?", (limit,)
        ).fetchall()
        return _rows(rows)

# ── Anomalías ─────────────────────────────────────────────────────────────────

def anomaly_insert(batch_id: int, device_ip: str, bytes_per_sec: float,
                   typical: float, stddev: float, z_score: float, description: str):
    with get_db() as conn:
        conn.execute(
            """INSERT INTO anomalies_detected
               (batch_id, device_ip, timestamp, bytes_per_sec,
                typical_bytes_per_sec, stddev, z_score, description)
               VALUES (?,?,?,?,?,?,?,?)""",
            (batch_id, device_ip, now(), bytes_per_sec,
             typical, stddev, z_score, description),
        )

def anomaly_list_recent(limit: int = 50) -> list[dict]:
    with get_db() as conn:
        rows = conn.execute(
            "SELECT * FROM anomalies_detected ORDER BY id DESC LIMIT ?", (limit,)
        ).fetchall()
        return _rows(rows)

def anomaly_list_by_device(device_ip: str, limit: int = 50) -> list[dict]:
    with get_db() as conn:
        rows = conn.execute(
            """SELECT * FROM anomalies_detected
               WHERE device_ip=? ORDER BY id DESC LIMIT ?""",
            (device_ip, limit),
        ).fetchall()
        return _rows(rows)
