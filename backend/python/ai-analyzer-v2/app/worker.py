"""
worker.py — Worker thread: análisis LLM, detección de alertas, perfilado de dispositivos.

Un único thread lee la cola de batch_ids, procesa uno a la vez:
  payload → alertas deterministas → LLM (análisis SOC) → guardar → SSE broadcast

Alertas detectadas sin LLM (reglas deterministas):
  many_distinct_domains     >25 dominios únicos en el batch
  repeated_domain_queries   un dominio >12 queries, >45% del total
  rare_domain_pattern       TLD inusual o patrón DGA
  dga_suspicious_client     DGA desde IP no autorizada en portal
  suspicious_http_request   URI con patrón de inyección / traversal
  sensor_port_scan          >15 puertos distintos desde una IP
  sensor_high_bandwidth     >5 Mbps desde una IP
  sensor_risky_port         puerto riesgoso con >5 hits
"""
from __future__ import annotations

import json
import logging
import queue
import re
import threading
import time
from collections import Counter, deque
from datetime import datetime, timezone
from typing import Any

from . import database as db
from .config import RISKY_PORTS, PROTECTED_IPS, FEATURE_HUMAN_EXPLAIN, FEATURE_DEVICE_PROFILING
from .llm import analyze_traffic, explain_human, extract_risk
from .sse import broadcast_sync

log = logging.getLogger("worker")

# Cola de batch IDs pendientes
work_queue: queue.Queue = queue.Queue()

# ── Estadísticas globales (en memoria) ───────────────────────────────────────
stats = {
    "batches_received": 0,
    "analyses_ok":      0,
    "analyses_error":   0,
    "llm_calls":        0,
    "llm_errors":       0,
    "started_at":       datetime.now(timezone.utc).isoformat(),
}

# ── Anomaly detector en memoria (historial de bytes/s por IP) ─────────────────
_anomaly_history: dict[str, deque] = {}
_HISTORY_MAX = 1440  # 24h × 60 batches/hora → máx puntos en historial
_ANOMALY_ZSCORE = 2.5


def _detect_anomaly(device_ip: str, bytes_per_sec: float) -> tuple[bool, float, float, float]:
    """Retorna (is_anomaly, z_score, mean, stddev)."""
    hist = _anomaly_history.setdefault(device_ip, deque(maxlen=_HISTORY_MAX))
    hist.append(bytes_per_sec)
    if len(hist) < 10:
        return False, 0.0, 0.0, 0.0
    mean = sum(hist) / len(hist)
    variance = sum((x - mean) ** 2 for x in hist) / len(hist)
    stddev = variance ** 0.5
    if stddev < 1:
        return False, 0.0, mean, stddev
    z = abs(bytes_per_sec - mean) / stddev
    return z > _ANOMALY_ZSCORE, z, mean, stddev


# ── Device profiler (heurístico) ──────────────────────────────────────────────

_DEVICE_PATTERNS = {
    "ios":      (["apple.com", "icloud.com", "apple-dns.net", "mzstatic.com"], 0.8),
    "android":  (["googleapis.com", "gstatic.com", "android.com", "play.google.com"], 0.75),
    "smart_tv": (["netflix.com", "nflxvideo.net", "roku.com", "fire.tv", "samsungcloudsolution.com"], 0.8),
    "iot":      (["mqtt.", "arduino.cc", "esp32.", "esp8266.", "nodemcu.", "iot."], 0.7),
    "laptop":   (["github.com", "stackoverflow.com", "npmjs.com", "pypi.org", "microsoft.com"], 0.6),
}

def _profile_device(ip: str, domains: list[str]) -> tuple[str, float, list[str]]:
    domain_set = {d.lower() for d in domains}
    best_type, best_conf, best_reasons = "unknown", 0.3, []
    for dev_type, (patterns, base_conf) in _DEVICE_PATTERNS.items():
        matched = [p for p in patterns if any(p in d for d in domain_set)]
        if matched:
            conf = min(1.0, base_conf + 0.05 * (len(matched) - 1))
            if conf > best_conf:
                best_type, best_conf, best_reasons = dev_type, conf, matched
    return best_type, best_conf, best_reasons


# ── Extracción de indicadores del payload ─────────────────────────────────────

_DGA_RE = re.compile(r"^[a-z0-9]{6,12}\.(ru|cc|tk|xyz|biz|top|click|online|site|win|loan)$")
_SUSPICIOUS_URI_RE = re.compile(
    r"(\.\.\/|\.\.\\|\/etc\/passwd|\/wp-login|wp-admin|phpMyAdmin|"
    r"\.env|\.git\/|cmd=|exec=|eval\(|base64_decode|UNION.SELECT|"
    r"<script|javascript:|shell_exec)",
    re.IGNORECASE,
)
_RISKY_TLDS = {".ru", ".cc", ".tk", ".xyz", ".top", ".win", ".loan",
               ".click", ".online", ".biz", ".gq", ".ml", ".cf", ".ga"}


def _extract_payload_data(payload: str) -> dict[str, Any]:
    """Extrae campos relevantes del JSON del sensor."""
    try:
        data = json.loads(payload)
    except Exception:
        data = {}

    dns_queries   = data.get("dns_queries", [])
    dns_counts    = data.get("dns_query_counts", {})
    tls_sni       = data.get("tls_sni_hosts", [])
    http_reqs     = data.get("http_requests", data.get("http_hosts", []))
    top_talkers   = data.get("top_talkers", [])
    top_ports     = data.get("top_dst_ports", [])
    suspicious    = data.get("suspicious", [])
    susp_http     = data.get("suspicious_http_requests", [])
    client_domains = data.get("client_domain_counts", {})
    total_bytes   = data.get("total_bytes", 0)
    duration      = data.get("duration_seconds", 30)
    packets       = data.get("total_packets", 0)
    bytes_fmt     = data.get("total_bytes_fmt", "0 B")
    sensor_ip     = data.get("sensor_ip", "")

    all_domains = list({
        *dns_queries, *tls_sni,
        *(dns_counts.keys()),
    })

    bytes_per_sec = total_bytes / max(duration, 1)

    return {
        "sensor_ip":     sensor_ip,
        "all_domains":   all_domains,
        "dns_queries":   dns_queries,
        "dns_counts":    dns_counts,
        "http_reqs":     http_reqs,
        "top_talkers":   top_talkers,
        "top_ports":     top_ports,
        "suspicious":    suspicious,
        "susp_http":     susp_http,
        "client_domains":client_domains,
        "total_bytes":   total_bytes,
        "bytes_per_sec": bytes_per_sec,
        "duration":      duration,
        "packets":       packets,
        "bytes_fmt":     bytes_fmt,
        "raw":           data,
    }


def _build_traffic_summary(p: dict, anomaly_ctx: str = "") -> str:
    """Construye el resumen de tráfico para el LLM."""
    top_domains = sorted(p["dns_counts"].items(), key=lambda x: -x[1])[:10]
    top_talker_str = ", ".join(
        f"{t['ip']}({t.get('label', '')})" for t in p["top_talkers"][:3]
    )
    top_port_str = ", ".join(
        f"{t['port']}×{t['count']}" for t in p["top_ports"][:5]
    )
    susp_str = "; ".join(
        s if isinstance(s, str) else json.dumps(s)
        for s in p["suspicious"][:5]
    )
    http_str = "; ".join(
        r if isinstance(r, str) else json.dumps(r)
        for r in (p["susp_http"] or p["http_reqs"])[:5]
    )

    lines = [
        f"WiFi {p['duration']}s: pkt={p['packets']} bytes={p['bytes_fmt']}",
        f"BPS={p['bytes_per_sec']:.0f}",
        f"Dominios top: {', '.join(f'{d}×{c}' for d,c in top_domains)}",
        f"Top talkers: {top_talker_str}",
        f"Puertos: {top_port_str}",
    ]
    if susp_str:
        lines.append(f"Sospechosos: {susp_str}")
    if http_str:
        lines.append(f"HTTP: {http_str}")
    if anomaly_ctx:
        lines.append(f"\n{anomaly_ctx}")

    # Contexto de clientes
    for ip, domains in list(p["client_domains"].items())[:3]:
        top = sorted(domains.items(), key=lambda x: -x[1])[:5]
        lines.append(f"Cliente {ip}: {', '.join(f'{d}×{c}' for d,c in top)}")

    return "\n".join(lines)


# ── Detección de alertas (reglas deterministas) ───────────────────────────────

def _detect_alerts(batch_id: int, p: dict):
    all_domains  = p["all_domains"]
    dns_counts   = p["dns_counts"]
    top_talkers  = p["top_talkers"]
    top_ports    = p["top_ports"]
    susp_http    = p["susp_http"]
    suspicious   = p["suspicious"]

    total_dns = sum(dns_counts.values()) or 1

    # 1. Muchos dominios distintos
    if len(all_domains) > 25:
        sev = "high" if len(all_domains) > 50 else "medium"
        db.alert_insert(batch_id, sev, "many_distinct_domains",
                        f"{len(all_domains)} dominios distintos en {p['duration']}s",
                        source_ip=p["sensor_ip"])
        _sse_alert(batch_id, sev, "many_distinct_domains", len(all_domains))

    # 2. Dominio repetido (posible DGA C2)
    for domain, count in dns_counts.items():
        if count > 12 and count / total_dns > 0.45:
            db.alert_insert(batch_id, "medium", "repeated_domain_queries",
                            f"{domain} → {count} queries ({count/total_dns:.0%})",
                            domain=domain)
            _sse_alert(batch_id, "medium", "repeated_domain_queries", domain)

    # 3. TLD sospechoso / patrón DGA
    for domain in all_domains:
        parts = domain.split(".")
        if len(parts) >= 2:
            tld = "." + parts[-1]
            if tld in _RISKY_TLDS or _DGA_RE.match(domain):
                sev = "critical" if domain.lower() not in {d.lower() for d in p.get("whitelist", [])} else "low"
                db.alert_insert(batch_id, sev, "rare_domain_pattern",
                                f"Dominio sospechoso: {domain}",
                                domain=domain)
                _sse_alert(batch_id, sev, "rare_domain_pattern", domain)

    # 4. HTTP sospechoso
    for req in susp_http:
        uri = req if isinstance(req, str) else req.get("uri", str(req))
        if _SUSPICIOUS_URI_RE.search(uri):
            db.alert_insert(batch_id, "high", "suspicious_http_request",
                            f"URI sospechosa: {uri[:200]}")
            _sse_alert(batch_id, "high", "suspicious_http_request", uri[:80])

    # 5. Port scan / alto ancho de banda / puertos riesgosos
    port_map: dict[str, set] = {}
    for pt in top_ports:
        port = pt.get("port", 0)
        if int(port) in RISKY_PORTS and pt.get("count", 0) > 5:
            db.alert_insert(batch_id, "medium", "sensor_risky_port",
                            f"Puerto riesgoso {port} con {pt['count']} hits")
            _sse_alert(batch_id, "medium", "sensor_risky_port", port)

    # 6. Alto ancho de banda por talker
    for talker in top_talkers:
        ip    = talker.get("ip", "")
        bytes_ = talker.get("bytes", 0)
        bps   = bytes_ / max(p["duration"], 1) * 8
        if bps > 5_000_000 and ip not in PROTECTED_IPS:  # > 5 Mbps
            db.alert_insert(batch_id, "medium", "sensor_high_bandwidth",
                            f"{ip} → {bps/1e6:.1f} Mbps",
                            source_ip=ip)
            _sse_alert(batch_id, "medium", "sensor_high_bandwidth", ip)

    # 7. Alertas ya procesadas por el sensor
    for s in suspicious:
        if isinstance(s, dict):
            stype = s.get("type", "")
            sip   = s.get("ip", "")
            if stype == "port_scan":
                db.alert_insert(batch_id, "medium", "sensor_port_scan",
                                f"Escaneo de puertos desde {sip}", source_ip=sip)
            elif stype == "host_scan":
                db.alert_insert(batch_id, "medium", "sensor_host_scan",
                                f"Escaneo de hosts desde {sip}", source_ip=sip)


def _sse_alert(batch_id: int, severity: str, alert_type: str, detail: Any):
    broadcast_sync({
        "event":      "alert_detected",
        "batch_id":   batch_id,
        "severity":   severity,
        "alert_type": alert_type,
        "detail":     str(detail),
    })


# ── Worker principal ──────────────────────────────────────────────────────────

def process_one(batch_id: int):
    t0 = time.time()
    log.info(f"[Worker] Procesando batch #{batch_id}")

    payload_str = db.batch_get_payload(batch_id)
    if not payload_str:
        log.warning(f"Batch #{batch_id} sin payload")
        return

    try:
        p = _extract_payload_data(payload_str)

        # ── Detección de anomalía de ancho de banda ───────────────────────────
        sensor_ip = p["sensor_ip"]
        is_anomaly, z_score, mean, stddev = _detect_anomaly(sensor_ip, p["bytes_per_sec"])
        anomaly_ctx = ""
        if is_anomaly:
            anomaly_ctx = (
                f"⚠️ ANOMALÍA DETECTADA: {p['bytes_per_sec']:.0f} B/s "
                f"(normal: {mean:.0f}±{stddev:.0f}, z={z_score:.1f})"
            )
            db.anomaly_insert(
                batch_id, sensor_ip, p["bytes_per_sec"],
                mean, stddev, z_score, anomaly_ctx,
            )
            broadcast_sync({
                "event":     "anomaly_detected",
                "batch_id":  batch_id,
                "device_ip": sensor_ip,
                "z_score":   round(z_score, 2),
            })

        # ── Alertas deterministas ─────────────────────────────────────────────
        _detect_alerts(batch_id, p)

        # ── Análisis LLM ──────────────────────────────────────────────────────
        traffic_summary = _build_traffic_summary(p, anomaly_ctx)
        stats["llm_calls"] += 1

        analysis = analyze_traffic(traffic_summary)
        if analysis.startswith("[Error"):
            stats["llm_errors"] += 1

        risk     = extract_risk(analysis)
        elapsed  = time.time() - t0

        db.analysis_insert(
            batch_id, risk, analysis, elapsed,
            suspicious_count=len(p["suspicious"]),
            packets=p["packets"],
            bytes_fmt=p["bytes_fmt"],
        )
        db.batch_set_status(batch_id, "done")
        stats["analyses_ok"] += 1

        broadcast_sync({
            "event":    "analysis_done",
            "batch_id": batch_id,
            "risk":     risk,
            "elapsed":  round(elapsed, 1),
        })

        log.info(f"[Worker] Batch #{batch_id} → {risk} en {elapsed:.1f}s")

        # ── Explicación humana ────────────────────────────────────────────────
        if FEATURE_HUMAN_EXPLAIN:
            try:
                explanation = explain_human(traffic_summary)
                db.human_explanation_insert(batch_id, explanation)
            except Exception as exc:
                log.warning(f"human_explain error: {exc}")

        # ── Perfilado de dispositivos ─────────────────────────────────────────
        if FEATURE_DEVICE_PROFILING:
            for ip, domains in p["client_domains"].items():
                if ip in PROTECTED_IPS:
                    continue
                dev_type, conf, reasons = _profile_device(ip, list(domains.keys()))
                db.device_profile_upsert(ip, dev_type, conf, reasons)

    except Exception as exc:
        log.error(f"[Worker] Error en batch #{batch_id}: {exc}", exc_info=True)
        db.batch_set_status(batch_id, "error")
        stats["analyses_error"] += 1


def worker_loop():
    log.info("[Worker] Thread iniciado")
    while True:
        try:
            batch_id = work_queue.get(timeout=5)
            process_one(batch_id)
        except queue.Empty:
            continue
        except Exception as exc:
            log.error(f"[Worker] Error inesperado: {exc}", exc_info=True)


def start_worker() -> threading.Thread:
    t = threading.Thread(target=worker_loop, name="worker", daemon=True)
    t.start()
    return t
