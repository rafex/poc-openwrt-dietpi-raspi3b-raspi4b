#!/usr/bin/env python3
"""
Network Sensor — Raspi 3B (192.168.1.181)

Captura tráfico visible en eth0 (modo promiscuo) + metadatos del router
vía SSH (conntrack, DHCP leases). Agrega en ventanas de BATCH_INTERVAL
segundos y envía el resumen al analizador IA en la Raspi 4B.

Uso:
    python3 sensor.py

Variables de entorno:
    SENSOR_IFACE       Interfaz de captura           (default: eth0)
    SENSOR_IP          IP de esta Pi                 (default: 192.168.1.181)
    ANALYZER_URL       URL del endpoint de ingesta   (default: http://192.168.1.167/api/ingest)
    BATCH_INTERVAL     Segundos por ventana          (default: 30)
    ROUTER_IP          IP del router OpenWrt         (default: 192.168.1.1)
    ROUTER_USER        Usuario SSH del router        (default: root)
    SSH_KEY            Llave SSH para el router      (default: /opt/keys/sensor)
    USE_ROUTER_SSH     Enriquecer con datos router   (default: true)
    LOG_LEVEL          Nivel de log                  (default: INFO)
"""

import json
import logging
import os
import subprocess
import threading
import time
from collections import Counter, defaultdict
from datetime import datetime, timezone

import paho.mqtt.client as mqtt
import requests

# ─── Configuración ────────────────────────────────────────────────────────────
INTERFACE      = os.environ.get("SENSOR_IFACE",    "eth0")
SENSOR_IP      = os.environ.get("SENSOR_IP",       "192.168.1.181")
MQTT_HOST      = os.environ.get("MQTT_HOST",       "192.168.1.167")
MQTT_PORT      = int(os.environ.get("MQTT_PORT",   "1883"))
MQTT_TOPIC     = os.environ.get("MQTT_TOPIC",      "rafexpi/sensor/batch")
ANALYZER_URL   = os.environ.get("ANALYZER_URL",    "http://192.168.1.167/api/ingest")
BATCH_INTERVAL = int(os.environ.get("BATCH_INTERVAL", "30"))
ROUTER_IP      = os.environ.get("ROUTER_IP",       "192.168.1.1")
ROUTER_USER    = os.environ.get("ROUTER_USER",     "root")
SSH_KEY        = os.environ.get("SSH_KEY",         "/opt/keys/sensor")
USE_ROUTER_SSH = os.environ.get("USE_ROUTER_SSH",  "true").lower() == "true"
LOG_LEVEL      = os.environ.get("LOG_LEVEL",       "INFO")

logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format="%(asctime)s %(levelname)-5s [%(funcName)s] %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
)
log = logging.getLogger("sensor")

# Campos tshark capturados (orden importante — índices usados en parser)
TSHARK_FIELDS = [
    "frame.time_epoch",        # 0
    "ip.src",                  # 1
    "ip.dst",                  # 2
    "ip.proto",                # 3
    "tcp.srcport",             # 4
    "tcp.dstport",             # 5
    "udp.srcport",             # 6
    "udp.dstport",             # 7
    "frame.len",               # 8
    "tcp.flags",               # 9
    "dns.qry.name",            # 10
    "http.host",               # 11
    "http.request.method",     # 12
    "http.request.uri",        # 13
    "arp.src.proto_ipv4",      # 14
    "arp.dst.proto_ipv4",      # 15
    "icmp.type",               # 16
    "eth.src",                 # 17
    "eth.dst",                 # 18
    "tls.handshake.extensions_server_name",  # 19
]

PROTO_NAMES = {1: "ICMP", 6: "TCP", 17: "UDP", 2: "IGMP", 58: "ICMPv6"}
LAN_PREFIX  = "192.168.1."

# ─── Utilidades ──────────────────────────────────────────────────────────────
def fmt_bytes(n: int) -> str:
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024:
            return f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} GB"


def router_ssh(cmd: str) -> str:
    """Ejecuta un comando en el router OpenWrt vía SSH."""
    try:
        result = subprocess.run(
            [
                "ssh", "-i", SSH_KEY,
                "-o", "StrictHostKeyChecking=no",
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=5",
                f"{ROUTER_USER}@{ROUTER_IP}",
                cmd,
            ],
            capture_output=True, text=True, timeout=10,
        )
        return result.stdout.strip()
    except Exception as e:
        log.debug("router_ssh error: %s", e)
        return ""


# ─── Agregador de tráfico ─────────────────────────────────────────────────────
class TrafficAggregator:
    """Acumula paquetes capturados por tshark en una ventana de tiempo."""

    def __init__(self):
        self._lock = threading.Lock()
        self.reset()

    def reset(self):
        with self._lock:
            self.start_ts    = time.time()
            self.packets     = 0
            self.total_bytes = 0
            self.src_bytes   = defaultdict(int)
            self.dst_bytes   = defaultdict(int)
            self.protocols   = defaultdict(int)
            self.dst_ports   = defaultdict(int)
            self.src_ports   = defaultdict(set)   # src_ip → set de puertos destino
            self.src_dsts    = defaultdict(set)   # src_ip → set de IPs destino
            self.tcp_flags   = defaultdict(int)
            self.dns_queries = []
            self.http_hosts  = []
            self.tls_sni_hosts = []
            self.http_uris   = []
            self.arps        = []
            self.client_domain_counts = defaultdict(lambda: defaultdict(int))
            self.client_domain_dsts = defaultdict(lambda: defaultdict(set))

    def add(self, line: str):
        """Parsea una línea de tshark y acumula sus datos."""
        parts = (line + "\t" * len(TSHARK_FIELDS)).split("\t")
        if len(parts) < 9:
            return
        try:
            ts         = parts[0]
            src        = parts[1].split(",")[0]  # tshark puede dar múltiples valores
            dst        = parts[2].split(",")[0]
            proto_raw  = parts[3].split(",")[0]
            tcp_sp     = parts[4].split(",")[0]
            tcp_dp     = parts[5].split(",")[0]
            udp_sp     = parts[6].split(",")[0]
            udp_dp     = parts[7].split(",")[0]
            length_raw = parts[8].split(",")[0]
            tcp_flags  = parts[9]
            dns        = parts[10]
            http_host  = parts[11]
            http_method = parts[12]
            http_uri   = parts[13]
            arp_src    = parts[14]
            arp_dst    = parts[15]
            tls_sni    = parts[19]

            plen = int(length_raw) if length_raw.isdigit() else 0
            dport = tcp_dp or udp_dp

            with self._lock:
                self.packets     += 1
                self.total_bytes += plen

                if src:
                    self.src_bytes[src] += plen
                if dst:
                    self.dst_bytes[dst] += plen

                proto_num  = int(proto_raw) if proto_raw.isdigit() else 0
                proto_name = PROTO_NAMES.get(proto_num, str(proto_num) if proto_raw else "Otro")
                self.protocols[proto_name] += 1

                if dport and dport.isdigit():
                    dp = int(dport)
                    self.dst_ports[dp] += 1
                    if src:
                        self.src_ports[src].add(dp)

                if src and dst:
                    self.src_dsts[src].add(dst)

                if tcp_flags:
                    self.tcp_flags[tcp_flags] += 1

                if dns:
                    for q in dns.split(","):
                        q = q.strip()
                        if q and q not in self.dns_queries[-200:]:
                            self.dns_queries.append(q)
                        if q and src.startswith(LAN_PREFIX):
                            self.client_domain_counts[src][q.lower()] += 1

                if http_host:
                    for h in http_host.split(","):
                        h = h.strip()
                        if h:
                            self.http_hosts.append(h)
                            if src.startswith(LAN_PREFIX):
                                host = h.lower()
                                self.client_domain_counts[src][host] += 1
                                if dst and not dst.startswith(LAN_PREFIX):
                                    self.client_domain_dsts[src][host].add(dst)

                if tls_sni:
                    for s in tls_sni.split(","):
                        s = s.strip()
                        if s:
                            self.tls_sni_hosts.append(s)
                            if src.startswith(LAN_PREFIX):
                                host = s.lower()
                                self.client_domain_counts[src][host] += 1
                                if dst and not dst.startswith(LAN_PREFIX):
                                    self.client_domain_dsts[src][host].add(dst)

                if http_uri and http_host:
                    self.http_uris.append(f"{http_method} http://{http_host}{http_uri}")

                if arp_src and arp_dst:
                    self.arps.append({"src": arp_src, "dst": arp_dst})

        except Exception as e:
            log.debug("parse error: %s — %r", e, line[:100])

    def summarize(self) -> dict:
        """Genera resumen del batch actual para enviar al analizador."""
        with self._lock:
            duration = max(1, time.time() - self.start_ts)

            top_src   = sorted(self.src_bytes.items(),  key=lambda x: -x[1])[:10]
            top_dst   = sorted(self.dst_bytes.items(),  key=lambda x: -x[1])[:10]
            top_ports = sorted(self.dst_ports.items(),  key=lambda x: -x[1])[:15]
            dns_counts = Counter(q for q in self.dns_queries if q)
            http_counts = Counter(h for h in self.http_hosts if h)
            sni_counts = Counter(h for h in self.tls_sni_hosts if h)

            suspicious = []

            # Detección de escaneo de puertos
            for src, ports in self.src_ports.items():
                if len(ports) >= 15 and not src.startswith(LAN_PREFIX + "1."):
                    suspicious.append({
                        "type":   "port_scan",
                        "src":    src,
                        "detail": f"contactó {len(ports)} puertos distintos",
                        "ports":  sorted(ports)[:20],
                    })

            # Detección de escaneo de hosts
            for src, dsts in self.src_dsts.items():
                if len(dsts) >= 20:
                    suspicious.append({
                        "type":   "host_scan",
                        "src":    src,
                        "detail": f"contactó {len(dsts)} hosts distintos",
                    })

            # Alto volumen de tráfico
            for src, byt in self.src_bytes.items():
                mbps = (byt * 8) / duration / 1_000_000
                if mbps > 5:
                    suspicious.append({
                        "type":   "high_bandwidth",
                        "src":    src,
                        "detail": f"{mbps:.1f} Mbps enviados",
                    })

            # Puertos sospechosos contactados
            risky_ports = {22, 23, 3389, 5900, 445, 139, 1433, 3306, 5432}
            for port, count in self.dst_ports.items():
                if port in risky_ports and count > 5:
                    suspicious.append({
                        "type":   "risky_port",
                        "port":   port,
                        "detail": f"puerto {port} contactado {count} veces",
                    })

            lan_devices = sorted(set(
                ip for ip in list(self.src_bytes) + list(self.dst_bytes)
                if ip.startswith(LAN_PREFIX)
            ))

            return {
                "timestamp":        datetime.now(timezone.utc).isoformat(),
                "duration_seconds": round(duration),
                "sensor_ip":        SENSOR_IP,
                "interface":        INTERFACE,
                "total_packets":    self.packets,
                "total_bytes":      self.total_bytes,
                "total_bytes_fmt":  fmt_bytes(self.total_bytes),
                "pps":              round(self.packets / duration, 1),
                "bps":              round(self.total_bytes * 8 / duration),
                "active_src_ips":   len(self.src_bytes),
                "active_dst_ips":   len(self.dst_bytes),
                "top_talkers":      [
                    {"ip": ip, "bytes": b, "label": fmt_bytes(b)} for ip, b in top_src
                ],
                "top_destinations": [
                    {"ip": ip, "bytes": b, "label": fmt_bytes(b)} for ip, b in top_dst
                ],
                "top_dst_ports":    [{"port": p, "count": c} for p, c in top_ports],
                "protocols":        dict(self.protocols),
                "dns_queries":      list(dict.fromkeys(self.dns_queries))[:60],
                "dns_query_counts": dict(dns_counts.most_common(120)),
                "http_hosts":       list(dict.fromkeys(self.http_hosts))[:25],
                "http_host_counts": dict(http_counts.most_common(120)),
                "tls_sni_hosts":    list(dict.fromkeys(self.tls_sni_hosts))[:40],
                "tls_sni_counts":   dict(sni_counts.most_common(120)),
                "http_requests":    list(dict.fromkeys(self.http_uris))[:15],
                "client_domain_counts": {
                    client: dict(sorted(domains.items(), key=lambda x: -x[1])[:60])
                    for client, domains in self.client_domain_counts.items()
                },
                "client_domain_destinations": {
                    client: {domain: sorted(list(ips))[:20] for domain, ips in domain_map.items()}
                    for client, domain_map in self.client_domain_dsts.items()
                },
                "suspicious":       suspicious,
                "arp_events":       self.arps[:30],
                "lan_devices":      lan_devices[:30],
            }


# ─── Hilo de captura tshark ───────────────────────────────────────────────────
def capture_thread(aggregator: TrafficAggregator, stop_event: threading.Event):
    """Lee líneas de tshark y las alimenta al agregador."""
    field_args = []
    for f in TSHARK_FIELDS:
        field_args += ["-e", f]

    cmd = [
        "tshark", "-i", INTERFACE,
        "-l",                           # flush inmediato por línea
        # sin -p: tshark queda en modo promiscuo (default)
        "-T", "fields",
        "-E", "separator=\t",
        "-E", "quote=n",
        "-E", "header=n",
    ] + field_args

    log.info("Iniciando captura en %s: %s", INTERFACE, " ".join(cmd))

    while not stop_event.is_set():
        try:
            proc = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                bufsize=1,
            )
            for line in proc.stdout:
                if stop_event.is_set():
                    break
                line = line.rstrip("\n")
                if line:
                    aggregator.add(line)
            proc.wait()
        except FileNotFoundError:
            log.error("tshark no encontrado. Instala con: apt-get install -y tshark")
            stop_event.wait(30)
        except Exception as e:
            log.error("Error en captura: %s — reintentando en 5s", e)
            stop_event.wait(5)


# ─── Enriquecimiento con datos del router ────────────────────────────────────
def enrich_with_router(summary: dict) -> dict:
    """Agrega datos de conntrack y DHCP del router via SSH."""
    if not USE_ROUTER_SSH:
        return summary

    # Conexiones activas (conntrack)
    conntrack_raw = router_ssh("conntrack -L 2>/dev/null | head -200")
    if conntrack_raw:
        connections = []
        for line in conntrack_raw.splitlines():
            parts = line.split()
            entry = {}
            for p in parts:
                if "=" in p:
                    k, v = p.split("=", 1)
                    if k in ("src", "dst", "sport", "dport", "proto"):
                        entry.setdefault(k, v)
            if "src" in entry and "dst" in entry:
                connections.append(entry)
        summary["router_connections"] = connections[:80]
        summary["router_connection_count"] = len(connections)
    else:
        summary["router_connections"] = []
        summary["router_connection_count"] = 0

    # DHCP leases (dispositivos conocidos)
    leases_raw = router_ssh("cat /tmp/dhcp.leases 2>/dev/null")
    devices = []
    if leases_raw:
        for line in leases_raw.splitlines():
            parts = line.split()
            if len(parts) >= 4:
                devices.append({
                    "mac":      parts[1],
                    "ip":       parts[2],
                    "hostname": parts[3] if parts[3] != "*" else "desconocido",
                })
    summary["dhcp_devices"] = devices

    # Clientes autorizados en el portal cautivo
    allowed_raw = router_ssh("nft list set ip captive allowed_clients 2>/dev/null")
    if allowed_raw:
        allowed = [
            w.strip(" \t{},")
            for w in allowed_raw.split()
            if w[0:1].isdigit()
        ]
        summary["captive_allowed"] = allowed
    else:
        summary["captive_allowed"] = []

    log.debug(
        "Router: %d conexiones, %d devices DHCP, %d autorizados portal",
        summary["router_connection_count"],
        len(devices),
        len(summary.get("captive_allowed", [])),
    )
    return summary


# ─── MQTT client ─────────────────────────────────────────────────────────────
_mqtt_client: mqtt.Client = None
_mqtt_ready  = threading.Event()


def _on_mqtt_connect(client, userdata, flags, rc):
    if rc == 0:
        log.info("MQTT conectado a %s:%d", MQTT_HOST, MQTT_PORT)
        _mqtt_ready.set()
    else:
        log.warning("MQTT connect falló rc=%d", rc)


def _on_mqtt_disconnect(client, userdata, rc):
    _mqtt_ready.clear()
    log.warning("MQTT desconectado (rc=%d) — reconectando...", rc)


def init_mqtt():
    global _mqtt_client
    client = mqtt.Client(client_id=f"raspi3b-sensor-{SENSOR_IP}", clean_session=True)
    client.on_connect    = _on_mqtt_connect
    client.on_disconnect = _on_mqtt_disconnect
    client.reconnect_delay_set(min_delay=2, max_delay=30)
    try:
        client.connect(MQTT_HOST, MQTT_PORT, keepalive=60)
        log.info("MQTT conectando a %s:%d topic=%s", MQTT_HOST, MQTT_PORT, MQTT_TOPIC)
    except Exception as e:
        log.warning("MQTT no disponible al inicio: %s — se usará HTTP fallback", e)
    client.loop_start()
    _mqtt_client = client


# ─── Envío al analizador ─────────────────────────────────────────────────────
def send_batch(summary: dict):
    """Publica el batch vía MQTT (preferido) con fallback a HTTP POST."""
    payload = json.dumps(summary, ensure_ascii=False)
    pkts    = summary["total_packets"]
    bfmt    = summary["total_bytes_fmt"]
    susp    = len(summary.get("suspicious", []))

    # ── Intento 1: MQTT ──────────────────────────────────────────────────────
    if _mqtt_client is not None and _mqtt_ready.is_set():
        try:
            result = _mqtt_client.publish(MQTT_TOPIC, payload, qos=1)
            if result.rc == mqtt.MQTT_ERR_SUCCESS:
                log.info(
                    "MQTT publicado: %d paquetes, %s, %d sospechosos → %s",
                    pkts, bfmt, susp, MQTT_TOPIC,
                )
                return
            log.warning("MQTT publish rc=%d — intentando HTTP fallback", result.rc)
        except Exception as e:
            log.warning("MQTT publish error: %s — intentando HTTP fallback", e)

    # ── Fallback: HTTP POST ───────────────────────────────────────────────────
    try:
        resp = requests.post(
            ANALYZER_URL,
            data=payload,
            timeout=15,
            headers={"Content-Type": "application/json"},
        )
        if resp.status_code == 200:
            log.info(
                "HTTP enviado: %d paquetes, %s, %d sospechosos — respuesta: %s",
                pkts, bfmt, susp, resp.json().get("status", "?"),
            )
        else:
            log.warning("HTTP respuesta inesperada: %d", resp.status_code)
    except requests.exceptions.ConnectionError:
        log.warning("No se pudo conectar: MQTT ni HTTP disponibles")
    except Exception as e:
        log.error("Error enviando batch: %s", e)


# ─── Hilo de batch ────────────────────────────────────────────────────────────
def batch_thread(aggregator: TrafficAggregator, stop_event: threading.Event):
    """Cada BATCH_INTERVAL segundos, genera y envía el resumen del batch."""
    log.info("Batch interval: %ds → %s", BATCH_INTERVAL, ANALYZER_URL)
    while not stop_event.is_set():
        stop_event.wait(BATCH_INTERVAL)
        if stop_event.is_set():
            break
        try:
            summary = aggregator.summarize()
            aggregator.reset()
            summary = enrich_with_router(summary)
            log.info(
                "Batch [%ds]: %d paquetes | %s | %d src IPs | %d DNS | %d sospechosos",
                summary["duration_seconds"],
                summary["total_packets"],
                summary["total_bytes_fmt"],
                summary["active_src_ips"],
                len(summary["dns_queries"]),
                len(summary["suspicious"]),
            )
            if summary["total_packets"] > 0 or summary.get("router_connection_count", 0) > 0:
                send_batch(summary)
            else:
                log.debug("Batch vacío — no se envía")
        except Exception as e:
            log.error("Error en batch_thread: %s", e)


# ─── Main ─────────────────────────────────────────────────────────────────────
def main():
    log.info("=" * 60)
    log.info("Network Sensor — Raspi 3B")
    log.info("  Interfaz : %s", INTERFACE)
    log.info("  Sensor IP: %s", SENSOR_IP)
    log.info("  Analyzer : %s", ANALYZER_URL)
    log.info("  Intervalo: %ds", BATCH_INTERVAL)
    log.info("  Router SSH: %s (%s@%s)", "activo" if USE_ROUTER_SSH else "desactivado", ROUTER_USER, ROUTER_IP)
    log.info("  MQTT      : %s:%d  topic=%s", MQTT_HOST, MQTT_PORT, MQTT_TOPIC)
    log.info("  HTTP fallback: %s", ANALYZER_URL)
    log.info("=" * 60)

    init_mqtt()
    _mqtt_ready.wait(timeout=5)  # esperar conexión inicial (no bloquea si falla)

    if USE_ROUTER_SSH:
        test = router_ssh("echo pong")
        if test == "pong":
            log.info("SSH al router: OK")
        else:
            log.warning("SSH al router: NO disponible — se usarán solo datos locales")

    aggregator = TrafficAggregator()
    stop_event = threading.Event()

    t_cap   = threading.Thread(target=capture_thread, args=(aggregator, stop_event), daemon=True)
    t_batch = threading.Thread(target=batch_thread,   args=(aggregator, stop_event), daemon=True)

    t_cap.start()
    t_batch.start()

    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        log.info("Deteniendo sensor...")
        stop_event.set()
        t_cap.join(timeout=5)
        t_batch.join(timeout=5)
        log.info("Sensor detenido.")


if __name__ == "__main__":
    main()
