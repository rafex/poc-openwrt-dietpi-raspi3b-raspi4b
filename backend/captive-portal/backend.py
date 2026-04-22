import http.server
import subprocess
import json
import logging
import time
import os

# =============================================================================
# Logging — formato detallado con contexto de cada operación
# =============================================================================
LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO").upper()
logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format="%(asctime)s %(levelname)-8s [%(funcName)s] %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
)
log = logging.getLogger("captive-backend")

# =============================================================================
# Configuración
# =============================================================================
ROUTER_IP   = os.environ.get("ROUTER_IP", "192.168.1.1")
ROUTER_USER = os.environ.get("ROUTER_USER", "root")
SSH_KEY     = os.environ.get("SSH_KEY", "/opt/keys/captive-portal")
PORTAL_IP   = os.environ.get("PORTAL_IP", "192.168.1.167")
NFT_SET     = "ip captive allowed_clients"
NFT_BLOCKED_SET = "ip captive blocked_macs"

log.info("=== Backend captive portal iniciando ===")
log.info(f"ROUTER_IP={ROUTER_IP}  PORTAL_IP={PORTAL_IP}  SSH_KEY={SSH_KEY}  LOG_LEVEL={LOG_LEVEL}")

# =============================================================================
# SSH helper con logging completo
# =============================================================================
def _router_ssh(description: str, remote_cmd: str, timeout: int = 10) -> tuple[int, str, str]:
    """Ejecuta un comando SSH en el router y retorna (returncode, stdout, stderr)."""
    cmd = [
        "ssh",
        "-i", SSH_KEY,
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        "-o", "ConnectTimeout=5",
        "-o", "LogLevel=ERROR",
        f"{ROUTER_USER}@{ROUTER_IP}",
        remote_cmd,
    ]
    t0 = time.monotonic()
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        elapsed = (time.monotonic() - t0) * 1000
        log.debug(f"SSH [{description}] rc={result.returncode}  elapsed={elapsed:.0f}ms")
        if result.stdout.strip():
            log.debug(f"SSH [{description}] stdout: {result.stdout.strip()!r}")
        if result.stderr.strip():
            log.warning(f"SSH [{description}] stderr: {result.stderr.strip()!r}")
        return result.returncode, result.stdout.strip(), result.stderr.strip()
    except subprocess.TimeoutExpired:
        elapsed = (time.monotonic() - t0) * 1000
        log.error(f"SSH [{description}] TIMEOUT tras {elapsed:.0f}ms")
        return -1, "", "timeout"
    except Exception as exc:
        log.error(f"SSH [{description}] excepción: {exc}")
        return -1, "", str(exc)

# =============================================================================
# Obtener IP del cliente
# Estrategia 1: header X-Real-IP enviado por nginx (preferido — más fiable)
# Estrategia 2: conntrack en el router (fallback si el header llega vacío)
# =============================================================================
def get_client_ip(handler) -> str:
    """Devuelve la IP real del cliente. Prioriza el header X-Real-IP."""

    # --- Estrategia 1: header HTTP (nginx realip → X-Real-IP) ---
    x_real_ip = handler.headers.get("X-Real-IP", "").strip()
    x_forwarded = handler.headers.get("X-Forwarded-For", "").strip()
    peer_ip = handler.client_address[0]

    log.info(f"Headers de IP recibidos — X-Real-IP={x_real_ip!r}  "
             f"X-Forwarded-For={x_forwarded!r}  peer={peer_ip}")

    # Tomar la primera IP de X-Real-IP si es una IP de la LAN real
    if x_real_ip and x_real_ip.startswith("192.168.") and x_real_ip != PORTAL_IP:
        log.info(f"IP del cliente via X-Real-IP: {x_real_ip}")
        return x_real_ip

    # X-Forwarded-For puede ser "192.168.1.X, 10.42.0.Y" — queremos la primera
    if x_forwarded:
        first_ip = x_forwarded.split(",")[0].strip()
        if first_ip.startswith("192.168.") and first_ip != PORTAL_IP:
            log.info(f"IP del cliente via X-Forwarded-For (primera): {first_ip}")
            return first_ip

    # --- Estrategia 2: conntrack en el router (fallback) ---
    log.warning("Headers de IP no contienen IP LAN válida — fallback a conntrack en router")
    remote_cmd = (
        "cat /proc/net/nf_conntrack"
        " | grep dport=80"
        " | grep ESTABLISHED"
        " | awk '{print $7}'"
        " | sed 's/src=//'"
        f" | grep '192.168.1.'"
        f" | grep -v '{PORTAL_IP}'"
        " | head -1"
    )
    rc, stdout, stderr = _router_ssh("conntrack-get-ip", remote_cmd)
    if rc == 0 and stdout:
        log.info(f"IP del cliente via conntrack: {stdout}")
        return stdout

    log.error(f"No se pudo detectar IP del cliente — rc={rc}  stdout={stdout!r}  stderr={stderr!r}")
    return ""

# =============================================================================
# Autorizar cliente en nftables
# =============================================================================
def authorize_client(client_ip: str) -> bool:
    """Agrega client_ip al set allowed_clients del router vía nft."""
    if not client_ip:
        log.error("authorize_client() llamado con IP vacía")
        return False

    rc, stdout, stderr = _router_ssh(
        f"nft-add-{client_ip}",
        f"nft add element {NFT_SET} {{ {client_ip} }}"
    )
    if rc == 0:
        log.info(f"✔ Cliente AUTORIZADO: {client_ip} agregado a {NFT_SET}")
        _unblock_mac_for_ip(client_ip)
        return True
    else:
        log.error(f"✘ FALLÓ autorizar {client_ip} — rc={rc}  stderr={stderr!r}")
        return False


def _is_mac(value: str) -> bool:
    parts = value.lower().split(":")
    if len(parts) != 6:
        return False
    hexchars = set("0123456789abcdef")
    return all(len(p) == 2 and all(c in hexchars for c in p) for p in parts)


def _mac_for_ip(client_ip: str) -> str:
    # Primero ARP/neighbor cache; fallback a leases de dnsmasq.
    rc, stdout, _ = _router_ssh(
        f"mac-for-{client_ip}",
        (
            f"(ip neigh show {client_ip} 2>/dev/null | awk '{{print $5}}' | head -1; "
            f"awk '$3==\"{client_ip}\" {{print tolower($2)}}' /tmp/dhcp.leases 2>/dev/null | head -1) "
            "| grep -m1 -E '^[0-9a-f]{2}(:[0-9a-f]{2}){5}$'"
        ),
    )
    if rc == 0 and stdout and _is_mac(stdout):
        return stdout.lower()
    return ""


def _unblock_mac_for_ip(client_ip: str):
    mac = _mac_for_ip(client_ip)
    if not mac:
        return
    # Si existe blocked_macs y la MAC está ahí, quitarla.
    rc, _, _ = _router_ssh(
        f"unblock-mac-{mac}",
        (
            f"nft list set {NFT_BLOCKED_SET} >/dev/null 2>&1 || exit 0; "
            f"nft delete element {NFT_BLOCKED_SET} {{ {mac} }} >/dev/null 2>&1 || true"
        ),
    )
    if rc == 0:
        log.info(f"MAC {mac} des-bloqueada de blocked_macs para IP {client_ip}")

# =============================================================================
# Handler HTTP
# =============================================================================
class Handler(http.server.BaseHTTPRequestHandler):

    def _dump_request(self):
        """Log completo de la petición entrante."""
        log.info(f">>> {self.command} {self.path}  peer={self.client_address[0]}")
        for name, value in self.headers.items():
            log.debug(f"    header: {name}: {value}")

    def do_POST(self):
        self._dump_request()

        if self.path == "/accept":
            t0 = time.monotonic()
            log.info("--- POST /accept: inicio de flujo de autorización ---")

            client_ip = get_client_ip(self)

            if not client_ip:
                elapsed = (time.monotonic() - t0) * 1000
                log.error(f"POST /accept FALLIDO — no se pudo detectar IP  elapsed={elapsed:.0f}ms")
                self._respond(500, {"ok": False, "error": "no se pudo detectar IP del cliente"})
                return

            success = authorize_client(client_ip)
            elapsed = (time.monotonic() - t0) * 1000
            status = "OK" if success else "FALLO"
            log.info(f"--- POST /accept {status} — ip={client_ip}  elapsed={elapsed:.0f}ms ---")

            self._respond(
                200 if success else 500,
                {"ok": success, "ip": client_ip}
            )

        else:
            log.warning(f"POST {self.path} — ruta no encontrada")
            self._respond(404, {"error": "not found"})

    def do_GET(self):
        self._dump_request()

        if self.path == "/health":
            # Verificar SSH al router como parte del health check
            rc, stdout, _ = _router_ssh("health-check", "echo pong")
            router_ok = (rc == 0 and stdout == "pong")
            status = {
                "status": "ok",
                "router_ssh": "ok" if router_ok else "error",
                "router_ip": ROUTER_IP,
            }
            log.info(f"GET /health — router_ssh={'ok' if router_ok else 'ERROR'}")
            self._respond(200 if router_ok else 503, status)

        else:
            log.warning(f"GET {self.path} — ruta no encontrada")
            self._respond(404, {"error": "not found"})

    def _respond(self, code: int, body: dict):
        payload = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, fmt, *args):
        # Silenciar el log por defecto de BaseHTTPRequestHandler — usamos el nuestro
        pass

# =============================================================================
# Main
# =============================================================================
if __name__ == "__main__":
    addr = ("0.0.0.0", 8080)
    server = http.server.HTTPServer(addr, Handler)
    log.info(f"Escuchando en {addr[0]}:{addr[1]}")
    log.info(f"SSH key: {SSH_KEY}  →  {ROUTER_USER}@{ROUTER_IP}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("Servidor detenido por señal")
