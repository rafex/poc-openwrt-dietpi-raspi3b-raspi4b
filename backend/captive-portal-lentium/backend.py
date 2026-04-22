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
NFT_BLOCKED_SET = "ip captive blocked_macs"
REDIRECT_URL = os.environ.get("REDIRECT_URL", "https://theworldofrafex.blog/")
ADMIN_IP    = os.environ.get("ADMIN_IP", "192.168.1.113")
SENSOR_IP   = os.environ.get("SENSOR_IP", "192.168.1.181")

log.info("=== Lentium Portal Backend iniciando ===")
log.info(f"ROUTER_IP={ROUTER_IP}  PORTAL_IP={PORTAL_IP}  DB_PATH={DB_PATH}  PORT={PORT}")

# =============================================================================
# SQLite — schema
# =============================================================================
def _db_connect() -> sqlite3.Connection:
    Path(DB_PATH).parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(DB_PATH, check_same_thread=False, timeout=10)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL;")
    conn.execute("PRAGMA synchronous=NORMAL;")
    conn.execute("PRAGMA busy_timeout=5000;")
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
        _unblock_mac_for_ip(client_ip)
        return True
    log.error(f"✘ Falló autorizar {client_ip} — stderr={stderr!r}")
    return False


def _is_mac(value: str) -> bool:
    parts = value.lower().split(":")
    if len(parts) != 6:
        return False
    hexchars = set("0123456789abcdef")
    return all(len(p) == 2 and all(c in hexchars for c in p) for p in parts)


def _mac_for_ip(client_ip: str) -> str:
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
# Validaciones mínimas
# =============================================================================
def _require_fields(data: dict, fields: list[str]) -> str | None:
    for f in fields:
        if not data.get(f, "").strip() if isinstance(data.get(f), str) else not data.get(f):
            return f"Campo requerido: {f}"
    return None


def _safe_json_loads(raw: str, fallback):
    try:
        return json.loads(raw)
    except Exception:
        return fallback


def _get_connected_clients() -> list[dict]:
    # IPs autorizadas actualmente en nftables.
    rc_set, set_stdout, _ = _router_ssh(
        "nft-allowed-list",
        "nft list set ip captive allowed_clients 2>/dev/null"
        " | grep -oE '([0-9]{1,3}\\.){3}[0-9]{1,3}' | sort -u"
    )
    if rc_set != 0:
        return []

    ips = [line.strip() for line in set_stdout.splitlines() if line.strip()]
    reserved = {ADMIN_IP, PORTAL_IP, SENSOR_IP}
    ips = [ip for ip in ips if ip not in reserved]
    if not ips:
        return []

    # Metadata por IP desde leases DHCP.
    rc_leases, leases_stdout, _ = _router_ssh("dhcp-leases", "cat /tmp/dhcp.leases 2>/dev/null")
    lease_by_ip = {}
    if rc_leases == 0 and leases_stdout:
        for line in leases_stdout.splitlines():
            parts = line.strip().split()
            if len(parts) < 4:
                continue
            lease_by_ip[parts[2]] = {
                "lease_expiry": parts[0],
                "mac": parts[1].lower(),
                "hostname": parts[3] if parts[3] != "*" else "",
            }

    connected = []
    for ip in ips:
        meta = lease_by_ip.get(ip, {})
        connected.append({
            "ip": ip,
            "mac": meta.get("mac", ""),
            "hostname": meta.get("hostname", ""),
            "lease_expiry": meta.get("lease_expiry", ""),
        })
    return connected


def _build_demo_dashboard_payload() -> dict:
    with _db_connect() as conn:
        clientes_rows = conn.execute(
            "SELECT id,telefono,pwd_plano,pwd_hash,ip,registrado_en,ultima_sesion FROM clientes ORDER BY id DESC"
        ).fetchall()
        invitados_rows = conn.execute(
            """SELECT id,nombre,apellido_paterno,apellido_materno,telefono,direccion_texto,
                      direccion_geo,pwd_plano,pwd_hash,redes_sociales,ip,registrado_en,ultima_sesion
               FROM invitados ORDER BY id DESC"""
        ).fetchall()

    clientes = [dict(r) for r in clientes_rows]
    invitados = []
    for row in invitados_rows:
        d = dict(row)
        d["redes_sociales"] = _safe_json_loads(d.get("redes_sociales") or "[]", [])
        d["direccion_geo"] = _safe_json_loads(d.get("direccion_geo") or "null", None)
        invitados.append(d)

    connected = _get_connected_clients()
    connected_ips = {c["ip"] for c in connected}
    for c in clientes:
        c["conectado"] = bool(c.get("ip") and c["ip"] in connected_ips)
    for g in invitados:
        g["conectado"] = bool(g.get("ip") and g["ip"] in connected_ips)

    return {
        "meta": {
            "generated_at": int(time.time()),
            "redirect_url": REDIRECT_URL,
        },
        "stats": {
            "clientes_registrados": len(clientes),
            "invitados_registrados": len(invitados),
            "conectados": len(connected),
        },
        "conectados": connected,
        "clientes": clientes,
        "invitados": invitados,
    }


def _demo_dashboard_html() -> bytes:
    html = """<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>demoDashboard · Lentium</title>
  <style>
    body { font-family: system-ui, -apple-system, Segoe UI, Roboto, sans-serif; margin: 0; background: #0b1f33; color: #e8f0f8; }
    .wrap { max-width: 1200px; margin: 0 auto; padding: 18px; }
    h1 { margin: 0 0 6px; font-size: 1.4rem; }
    .sub { opacity: .85; margin-bottom: 14px; }
    .cards { display: grid; grid-template-columns: repeat(auto-fit,minmax(170px,1fr)); gap: 10px; margin-bottom: 14px; }
    .card { background: #15324f; border: 1px solid #284a6b; border-radius: 12px; padding: 12px; }
    .n { font-size: 1.4rem; font-weight: 700; }
    .label { opacity: .9; font-size: .86rem; }
    .panel { background: #102941; border: 1px solid #27496b; border-radius: 12px; padding: 12px; margin-bottom: 12px; overflow: auto; }
    table { border-collapse: collapse; width: 100%; font-size: .86rem; }
    th, td { border-bottom: 1px solid #2a4d70; padding: 8px; text-align: left; vertical-align: top; }
    th { color: #b8d2ea; font-weight: 600; position: sticky; top: 0; background: #13314d; }
    .ok { color: #6fe39a; font-weight: 700; }
    .off { color: #ffb4b4; font-weight: 700; }
    .muted { opacity: .8; font-size: .8rem; }
  </style>
</head>
<body>
  <div class="wrap">
    <h1>demoDashboard · Lentium</h1>
    <div class="sub">Registros y clientes conectados en tiempo real (auto-refresh 5s)</div>
    <div class="cards">
      <div class="card"><div class="n" id="nClientes">0</div><div class="label">Clientes registrados</div></div>
      <div class="card"><div class="n" id="nInvitados">0</div><div class="label">Invitados registrados</div></div>
      <div class="card"><div class="n" id="nConectados">0</div><div class="label">Conectados ahora</div></div>
      <div class="card"><div class="n" id="ts">-</div><div class="label">Última actualización</div></div>
    </div>
    <div class="panel">
      <h3>Conectados</h3>
      <table id="tblConectados"></table>
    </div>
    <div class="panel">
      <h3>Clientes</h3>
      <table id="tblClientes"></table>
    </div>
    <div class="panel">
      <h3>Invitados</h3>
      <table id="tblInvitados"></table>
    </div>
  </div>
<script>
function esc(v){ return (v===null||v===undefined)?'':String(v).replace(/[&<>\"']/g,m=>({ '&':'&amp;','<':'&lt;','>':'&gt;','\"':'&quot;',\"'\":'&#39;'}[m])); }
function table(el, cols, rows){
  const head = '<tr>' + cols.map(c => '<th>'+esc(c.label)+'</th>').join('') + '</tr>';
  const body = rows.map(r => '<tr>' + cols.map(c => '<td>'+esc(c.get(r))+'</td>').join('') + '</tr>').join('');
  el.innerHTML = head + body;
}
function connectedBadge(v){ return v ? 'SI' : 'NO'; }
function ts(v){ if(!v) return '-'; return new Date(v*1000).toLocaleTimeString(); }
async function refresh(){
  const resp = await fetch('/api/demo/dashboard', { cache: 'no-store' });
  const data = await resp.json();
  document.getElementById('nClientes').textContent = data.stats.clientes_registrados;
  document.getElementById('nInvitados').textContent = data.stats.invitados_registrados;
  document.getElementById('nConectados').textContent = data.stats.conectados;
  document.getElementById('ts').textContent = ts(data.meta.generated_at);
  table(document.getElementById('tblConectados'), [
    {label:'IP', get:r=>r.ip},{label:'MAC', get:r=>r.mac},{label:'Hostname', get:r=>r.hostname},{label:'Lease', get:r=>r.lease_expiry}
  ], data.conectados || []);
  table(document.getElementById('tblClientes'), [
    {label:'ID', get:r=>r.id},{label:'Teléfono', get:r=>r.telefono},{label:'IP', get:r=>r.ip},
    {label:'Conectado', get:r=>connectedBadge(r.conectado)},{label:'Registrado', get:r=>r.registrado_en},{label:'Última sesión', get:r=>r.ultima_sesion}
  ], data.clientes || []);
  table(document.getElementById('tblInvitados'), [
    {label:'ID', get:r=>r.id},{label:'Nombre', get:r=>[r.nombre,r.apellido_paterno,r.apellido_materno].filter(Boolean).join(' ')},
    {label:'Teléfono', get:r=>r.telefono},{label:'IP', get:r=>r.ip},{label:'Conectado', get:r=>connectedBadge(r.conectado)},
    {label:'Registrado', get:r=>r.registrado_en}
  ], data.invitados || []);
}
refresh().catch(()=>{});
setInterval(() => refresh().catch(()=>{}), 5000);
</script>
</body>
</html>"""
    return html.encode("utf-8")

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

        if self.path in ("/demoDashboard", "/demoDashboard/"):
            html = _demo_dashboard_html()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(html)))
            self.end_headers()
            self.wfile.write(html)
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

        if self.path == "/api/demo/dashboard":
            self._respond(200, _build_demo_dashboard_payload())
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
        if self.path in ("/api/register/guest", "/api/register/quest"):
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
