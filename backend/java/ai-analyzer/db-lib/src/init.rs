//! Inicialización del esquema SQLite.
//!
//! Crea las 14 tablas y 12 índices exactamente igual que el `init_db()` de
//! `analyzer.py`, habilitando WAL para lecturas concurrentes.

use rusqlite::{Connection, Result};

/// DDL completo del esquema — ejecutado con `execute_batch` (== executescript).
const SCHEMA_SQL: &str = r#"
PRAGMA journal_mode = WAL;

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
"#;

/// Aplica el esquema completo a la conexión abierta.
pub(crate) fn apply_schema(conn: &Connection) -> Result<()> {
    conn.execute_batch(SCHEMA_SQL)
}
