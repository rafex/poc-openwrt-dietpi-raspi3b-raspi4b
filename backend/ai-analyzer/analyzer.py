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
    N_PREDICT       Tokens máximos respuesta  (default: 384)
    PORT            Puerto HTTP               (default: 5000)
    LOG_LEVEL       Nivel de log              (default: INFO)
"""

import json
import logging
import os
import pathlib
import queue
import sqlite3
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

import paho.mqtt.client as mqtt
import requests

# ─── Configuración ────────────────────────────────────────────────────────────
MQTT_HOST  = os.environ.get("MQTT_HOST",  "192.168.1.167")
MQTT_PORT  = int(os.environ.get("MQTT_PORT",  "1883"))
MQTT_TOPIC = os.environ.get("MQTT_TOPIC", "rafexpi/sensor/batch")
DB_PATH    = os.environ.get("DB_PATH",    "/data/sensor.db")
LLAMA_URL  = os.environ.get("LLAMA_URL",  "http://192.168.1.167:8081")
N_PREDICT  = int(os.environ.get("N_PREDICT",  "384"))
PORT       = int(os.environ.get("PORT",       "5000"))
LOG_LEVEL  = os.environ.get("LOG_LEVEL",  "INFO")

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

        CREATE INDEX IF NOT EXISTS idx_batches_status   ON batches(status);
        CREATE INDEX IF NOT EXISTS idx_analyses_batch   ON analyses(batch_id);
        CREATE INDEX IF NOT EXISTS idx_analyses_created ON analyses(timestamp DESC);
    """)
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


# ─── Prompt builder ───────────────────────────────────────────────────────────
def build_prompt(summary: dict) -> str:
    """Prompt compacto (~350 tokens) para TinyLlama (ctx-size=4096, parallel=1)."""
    duration = summary.get("duration_seconds", 30)
    packets  = summary.get("total_packets", 0)
    bfmt     = summary.get("total_bytes_fmt", "0 B")
    pps      = summary.get("pps", 0)

    protos    = summary.get("protocols", {})
    proto_str = ", ".join(
        f"{k}:{v}" for k, v in sorted(protos.items(), key=lambda x: -x[1])[:3]
    ) or "N/A"

    talkers_str = ", ".join(
        f"{t['ip']}({t['label']})"
        for t in summary.get("top_talkers", [])[:4]
    ) or "N/A"

    ports_str = ", ".join(
        f"{p['port']}:{p['count']}"
        for p in summary.get("top_dst_ports", [])[:5]
    ) or "N/A"

    dns_str = ", ".join(summary.get("dns_queries", [])[:8]) or "ninguna"

    suspicious = summary.get("suspicious", [])[:3]
    susp_str = "; ".join(
        f"[{s['type'].upper()}] {s.get('src', s.get('port','?'))}: {s['detail']}"
        for s in suspicious
    ) if suspicious else "ninguna"

    lan_str = ", ".join(summary.get("lan_devices", [])[:6]) or "N/A"

    user_msg = (
        f"Red WiFi — ultimos {duration}s:\n"
        f"Paquetes:{packets} ({pps}pps) Trafico:{bfmt}\n"
        f"Protocolos: {proto_str}\n"
        f"Top emisores: {talkers_str}\n"
        f"Top puertos dst: {ports_str}\n"
        f"Dispositivos LAN: {lan_str}\n"
        f"DNS: {dns_str}\n"
        f"Alertas: {susp_str}\n\n"
        "Da un analisis de seguridad en 3 puntos breves e indica el riesgo (BAJO/MEDIO/ALTO)."
    )
    return (
        "<|system|>\n"
        "Eres un analista de seguridad de redes. Responde en espanol, de forma concisa.\n"
        "</s>\n"
        f"<|user|>\n{user_msg}\n</s>\n"
        "<|assistant|>\n"
    )


# ─── llama.cpp ───────────────────────────────────────────────────────────────
def call_llama(prompt: str) -> str:
    stats["llama_calls"] += 1
    try:
        t0   = time.time()
        resp = requests.post(
            f"{LLAMA_URL}/completion",
            json={
                "prompt":      prompt,
                "n_predict":   N_PREDICT,
                "temperature": 0.7,
                "top_p":       0.9,
                "stop":        ["</s>", "<|user|>", "<|system|>"],
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


# ─── Pipeline de análisis ─────────────────────────────────────────────────────
def analyze_and_store(batch_id: int, summary: dict):
    """Ejecuta prompt → llama → guarda en SQLite → broadcast SSE."""
    t0       = time.time()
    prompt   = build_prompt(summary)
    analysis = call_llama(prompt)
    elapsed  = round(time.time() - t0, 1)

    risk = "BAJO"
    au   = analysis.upper()
    if "ALTO" in au or "CRÍTICO" in au:
        risk = "ALTO"
    elif "MEDIO" in au or "MODERADO" in au:
        risk = "MEDIO"
    if summary.get("suspicious"):
        risk = "MEDIO" if risk == "BAJO" else risk

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
    }

    db_save_analysis(batch_id, result)
    stats["analyses_ok"] += 1

    _broadcast_sse(result)
    log.info(
        "Análisis batch #%d completado en %ss | riesgo=%s | queue restante=%d",
        batch_id, elapsed, risk, work_queue.qsize(),
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

        if path == "/health":
            llama_ok = False
            try:
                r = requests.get(f"{LLAMA_URL}/health", timeout=3)
                llama_ok = r.status_code == 200
            except Exception:
                pass
            self.send_json({
                "status":      "ok",
                "llama_url":   LLAMA_URL,
                "llama_ok":    llama_ok,
                "mqtt_host":   MQTT_HOST,
                "mqtt_connected": stats["mqtt_connected"],
                "db_path":     DB_PATH,
                "queue":       db_queue_stats(),
                "stats":       stats,
            })

        elif path == "/api/history":
            limit = int(params.get("limit", ["50"])[0])
            items = db_get_history(limit)
            self.send_json({"count": len(items), "items": items})

        elif path == "/api/queue":
            self.send_json(db_queue_stats())

        elif path == "/api/stats":
            self.send_json({**stats, "queue": db_queue_stats()})

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
    log.info("=" * 60)
    log.info("AI Analyzer — Raspi 4B")
    log.info("  Puerto HTTP  : %d", PORT)
    log.info("  MQTT broker  : %s:%d  topic=%s", MQTT_HOST, MQTT_PORT, MQTT_TOPIC)
    log.info("  SQLite DB    : %s", DB_PATH)
    log.info("  llama.cpp    : %s", LLAMA_URL)
    log.info("=" * 60)

    init_db()

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
