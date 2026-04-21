#!/usr/bin/env python3
"""
AI Analyzer — Raspi 4B (k8s pod)

Recibe batches de metadatos de red del sensor (Raspi 3B),
construye un prompt para TinyLlama vía llama.cpp server,
y expone los resultados por REST + SSE para los dashboards.

Endpoints:
    POST /api/ingest        — recibe batch del sensor
    GET  /api/history       — últimos N análisis (JSON)
    GET  /api/stream        — SSE stream de análisis en tiempo real
    GET  /api/stats         — estadísticas del analizador
    GET  /health            — health check

Variables de entorno:
    LLAMA_URL       URL del servidor llama.cpp   (default: http://192.168.1.167:8081)
    LLAMA_MODEL     Nombre del modelo            (default: tinyllama)
    HISTORY_SIZE    Análisis en memoria          (default: 100)
    PORT            Puerto de escucha            (default: 5000)
    LOG_LEVEL       Nivel de log                 (default: INFO)
    N_PREDICT       Tokens máximos en respuesta  (default: 384)
"""

import json
import logging
import os
import queue
import threading
import time
from collections import deque
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs

import requests

# ─── Configuración ────────────────────────────────────────────────────────────
LLAMA_URL    = os.environ.get("LLAMA_URL",    "http://192.168.1.167:8081")
LLAMA_MODEL  = os.environ.get("LLAMA_MODEL",  "tinyllama")
HISTORY_SIZE = int(os.environ.get("HISTORY_SIZE", "100"))
PORT         = int(os.environ.get("PORT",         "5000"))
LOG_LEVEL    = os.environ.get("LOG_LEVEL",        "INFO")
N_PREDICT    = int(os.environ.get("N_PREDICT",    "384"))

logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format="%(asctime)s %(levelname)-5s [%(funcName)s] %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
)
log = logging.getLogger("analyzer")

# ─── Estado global ────────────────────────────────────────────────────────────
history      = deque(maxlen=HISTORY_SIZE)   # análisis completos
sse_queues   = []                           # colas SSE por cliente conectado
sse_lock     = threading.Lock()
stats        = {
    "batches_received":  0,
    "analyses_ok":       0,
    "analyses_error":    0,
    "llama_calls":       0,
    "llama_errors":      0,
    "started_at":        datetime.now(timezone.utc).isoformat(),
}


# ─── Prompt builder ───────────────────────────────────────────────────────────
def build_prompt(summary: dict) -> str:
    """Construye el prompt para TinyLlama en formato ChatML."""

    def fmt_list(lst, max_items=8, key=None):
        items = lst[:max_items]
        if key:
            return ", ".join(str(i.get(key, i)) for i in items) or "ninguno"
        return ", ".join(str(i) for i in items) or "ninguno"

    duration    = summary.get("duration_seconds", 30)
    packets     = summary.get("total_packets", 0)
    total_bytes = summary.get("total_bytes_fmt", "0 B")
    pps         = summary.get("pps", 0)
    src_ips     = summary.get("active_src_ips", 0)
    dst_ips     = summary.get("active_dst_ips", 0)

    # Protocolos
    protos = summary.get("protocols", {})
    proto_str = ", ".join(f"{k}:{v}" for k, v in sorted(protos.items(), key=lambda x: -x[1]))

    # Top talkers
    talkers_str = ", ".join(
        f"{t['ip']} ({t['label']})"
        for t in summary.get("top_talkers", [])[:6]
    ) or "ninguno"

    # Top destinos
    dests_str = ", ".join(
        t["ip"] for t in summary.get("top_destinations", [])[:6]
    ) or "ninguno"

    # Top puertos destino
    ports_str = ", ".join(
        f"{p['port']}/{p['count']}"
        for p in summary.get("top_dst_ports", [])[:8]
    ) or "ninguno"

    # DNS
    dns_str = fmt_list(summary.get("dns_queries", []), 20)

    # HTTP
    http_str = fmt_list(summary.get("http_hosts", []), 10)

    # Dispositivos LAN detectados
    lan_str = fmt_list(summary.get("lan_devices", []), 12)

    # DHCP (del router)
    dhcp = summary.get("dhcp_devices", [])
    dhcp_str = ", ".join(
        f"{d['ip']} ({d['hostname']})" for d in dhcp[:8]
    ) or "sin datos"

    # Conexiones router (conntrack count)
    conn_count = summary.get("router_connection_count", 0)

    # Actividad sospechosa
    suspicious = summary.get("suspicious", [])
    if suspicious:
        suspicious_str = "; ".join(
            f"[{s['type'].upper()}] {s.get('src', s.get('port', '?'))} — {s['detail']}"
            for s in suspicious[:5]
        )
    else:
        suspicious_str = "ninguna detectada"

    # ARP
    arp_events = summary.get("arp_events", [])
    arp_str = f"{len(arp_events)} eventos ARP" if arp_events else "sin actividad ARP"

    user_msg = f"""Analiza el siguiente resumen de tráfico de red capturado en los últimos {duration} segundos:

ESTADÍSTICAS GENERALES:
- Paquetes: {packets} ({pps} pps) | Tráfico: {total_bytes}
- IPs origen: {src_ips} | IPs destino: {dst_ips}
- Conexiones activas (router): {conn_count}

PROTOCOLOS: {proto_str}
PRINCIPALES EMISORES: {talkers_str}
PRINCIPALES DESTINOS: {dests_str}
PUERTOS DESTINO MÁS USADOS (puerto/peticiones): {ports_str}

DISPOSITIVOS LAN DETECTADOS: {lan_str}
DISPOSITIVOS DHCP ROUTER: {dhcp_str}

CONSULTAS DNS: {dns_str}
HOSTS HTTP: {http_str}
EVENTOS ARP: {arp_str}

ACTIVIDAD SOSPECHOSA: {suspicious_str}

Proporciona un análisis de seguridad en 4-6 puntos concisos. Identifica:
1. Dispositivos activos y su comportamiento
2. Patrones de tráfico anómalos o riesgosos
3. Consultas DNS o HTTP destacables
4. Nivel de riesgo general (BAJO/MEDIO/ALTO)
5. Recomendaciones específicas si hay alertas"""

    # Formato ChatML de TinyLlama
    prompt = (
        "<|system|>\n"
        "Eres un analista de ciberseguridad experto en redes. "
        "Analizas tráfico de redes WiFi y proporcionas informes concisos en español. "
        "Sé directo y técnico. Usa listas numeradas.\n"
        "</s>\n"
        f"<|user|>\n{user_msg}\n</s>\n"
        "<|assistant|>\n"
    )
    return prompt


# ─── Llamada a llama.cpp ──────────────────────────────────────────────────────
def call_llama(prompt: str) -> str:
    """Envía el prompt al servidor llama.cpp y devuelve el texto generado."""
    stats["llama_calls"] += 1
    payload = {
        "prompt":      prompt,
        "n_predict":   N_PREDICT,
        "temperature": 0.7,
        "top_p":       0.9,
        "stop":        ["</s>", "<|user|>", "<|system|>"],
        "stream":      False,
    }
    try:
        t0 = time.time()
        resp = requests.post(
            f"{LLAMA_URL}/completion",
            json=payload,
            timeout=120,
            headers={"Content-Type": "application/json"},
        )
        elapsed = round(time.time() - t0, 1)
        if resp.status_code == 200:
            text = resp.json().get("content", "").strip()
            log.info("llama.cpp respondió en %ss (%d chars)", elapsed, len(text))
            return text
        else:
            log.warning("llama.cpp HTTP %d: %s", resp.status_code, resp.text[:200])
            stats["llama_errors"] += 1
            return f"[Error llama.cpp: HTTP {resp.status_code}]"
    except requests.exceptions.Timeout:
        log.error("llama.cpp timeout (>120s)")
        stats["llama_errors"] += 1
        return "[Error: timeout al esperar respuesta del modelo]"
    except Exception as e:
        log.error("llama.cpp error: %s", e)
        stats["llama_errors"] += 1
        return f"[Error conectando con llama.cpp: {e}]"


# ─── Pipeline de análisis ─────────────────────────────────────────────────────
def analyze_batch(summary: dict) -> dict:
    """Ejecuta el pipeline completo: prompt → llama.cpp → resultado."""
    stats["batches_received"] += 1
    t0 = time.time()

    prompt   = build_prompt(summary)
    analysis = call_llama(prompt)
    elapsed  = round(time.time() - t0, 1)

    # Determinar nivel de riesgo del texto
    risk = "BAJO"
    analysis_upper = analysis.upper()
    if "ALTO" in analysis_upper or "CRÍTICO" in analysis_upper or "CRÍTICA" in analysis_upper:
        risk = "ALTO"
    elif "MEDIO" in analysis_upper or "MODERADO" in analysis_upper:
        risk = "MEDIO"
    if summary.get("suspicious"):
        risk = max(risk, "MEDIO", key=lambda x: {"BAJO": 0, "MEDIO": 1, "ALTO": 2}[x])

    result = {
        "id":             stats["batches_received"],
        "timestamp":      datetime.now(timezone.utc).isoformat(),
        "elapsed_s":      elapsed,
        "risk":           risk,
        "analysis":       analysis,
        "summary":        summary,
        "suspicious_count": len(summary.get("suspicious", [])),
        "packets":        summary.get("total_packets", 0),
        "bytes_fmt":      summary.get("total_bytes_fmt", "0 B"),
        "lan_devices":    summary.get("lan_devices", []),
        "dns_queries":    summary.get("dns_queries", [])[:20],
        "suspicious":     summary.get("suspicious", []),
    }

    stats["analyses_ok"] += 1
    history.append(result)
    _broadcast_sse(result)

    log.info(
        "Análisis #%d completado en %ss | riesgo=%s | suspicious=%d",
        result["id"], elapsed, risk, result["suspicious_count"],
    )
    return result


# ─── SSE broadcast ────────────────────────────────────────────────────────────
def _broadcast_sse(result: dict):
    """Envía el resultado a todos los clientes SSE conectados."""
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


# ─── HTTP Server ──────────────────────────────────────────────────────────────
class AnalyzerHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        log.debug("HTTP %s", fmt % args)

    def send_json(self, data, status=200):
        body = json.dumps(data, ensure_ascii=False, indent=2).encode()
        self.send_response(status)
        self.send_header("Content-Type",  "application/json")
        self.send_header("Content-Length", len(body))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def send_error_json(self, status, msg):
        self.send_json({"error": msg}, status)

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def do_GET(self):
        parsed = urlparse(self.path)
        path   = parsed.path
        params = parse_qs(parsed.query)

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
                "history_len": len(history),
                "stats":       stats,
            })

        elif path == "/api/history":
            limit = int(params.get("limit", [str(HISTORY_SIZE)])[0])
            items = list(history)[-limit:]
            self.send_json({"count": len(items), "items": items})

        elif path == "/api/stats":
            self.send_json(stats)

        elif path == "/api/stream":
            # SSE: text/event-stream
            q = queue.Queue(maxsize=50)
            with sse_lock:
                sse_queues.append(q)

            self.send_response(200)
            self.send_header("Content-Type",                "text/event-stream")
            self.send_header("Cache-Control",               "no-cache")
            self.send_header("Connection",                  "keep-alive")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()

            # Enviar últimos 5 análisis como contexto inicial
            try:
                for item in list(history)[-5:]:
                    data = json.dumps(item, ensure_ascii=False)
                    self.wfile.write(f"data: {data}\n\n".encode())
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
                        # keepalive
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
                self.send_error_json(400, "Body vacío")
                return
            try:
                body    = self.rfile.read(length)
                summary = json.loads(body)
            except json.JSONDecodeError as e:
                self.send_error_json(400, f"JSON inválido: {e}")
                return

            log.info(
                "Batch recibido del sensor %s: %d paquetes, %s",
                summary.get("sensor_ip", "?"),
                summary.get("total_packets", 0),
                summary.get("total_bytes_fmt", "?"),
            )

            # Analizar en hilo separado para no bloquear la respuesta HTTP
            threading.Thread(target=analyze_batch, args=(summary,), daemon=True).start()

            self.send_json({"status": "accepted", "batch_id": stats["batches_received"] + 1})

        else:
            self.send_error_json(404, f"Ruta no encontrada: {path}")


# ─── Main ─────────────────────────────────────────────────────────────────────
def main():
    log.info("=" * 60)
    log.info("AI Analyzer — Raspi 4B")
    log.info("  Escuchando en :%d", PORT)
    log.info("  llama.cpp URL : %s", LLAMA_URL)
    log.info("  Modelo        : %s", LLAMA_MODEL)
    log.info("  Historial     : %d análisis max", HISTORY_SIZE)
    log.info("=" * 60)

    # Verificar llama.cpp al arrancar
    try:
        r = requests.get(f"{LLAMA_URL}/health", timeout=5)
        if r.status_code == 200:
            log.info("llama.cpp server: OK (%s)", LLAMA_URL)
        else:
            log.warning("llama.cpp server respondió HTTP %d", r.status_code)
    except Exception as e:
        log.warning("llama.cpp server no disponible: %s — se reintentará en cada análisis", e)

    server = HTTPServer(("0.0.0.0", PORT), AnalyzerHandler)
    log.info("Servidor HTTP iniciado en 0.0.0.0:%d", PORT)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("Deteniendo analyzer...")
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
