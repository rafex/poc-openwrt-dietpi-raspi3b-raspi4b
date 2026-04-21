import http.server
import subprocess
import json
import logging

logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s')
log = logging.getLogger(__name__)

ROUTER_IP = "192.168.1.1"
ROUTER_USER = "root"
SSH_KEY = "/opt/keys/captive-portal"
NFT_SET = "ip captive allowed_clients"

def get_client_ip_from_router() -> str:
    ssh_cmd = "cat /proc/net/nf_conntrack | grep dport=80 | grep ESTABLISHED | awk '{print $7}' | sed 's/src=//' | grep '192.168.1.' | grep -v '192.168.1.167' | head -1"
    cmd = [
        "ssh",
        "-i", SSH_KEY,
        "-o", "StrictHostKeyChecking=no",
        "-o", "ConnectTimeout=5",
        f"{ROUTER_USER}@{ROUTER_IP}",
        ssh_cmd
    ]
    try:
        log.info(f"Ejecutando SSH: {' '.join(cmd)}")
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        log.info(f"SSH stdout: [{result.stdout}]")
        log.info(f"SSH stderr: [{result.stderr}]")
        log.info(f"SSH returncode: {result.returncode}")
        ip = result.stdout.strip()
        log.info(f"IP detectada desde conntrack: [{ip}]")
        return ip
    except Exception as e:
        log.error(f"Error obteniendo IP desde router: {e}")
        return ""

def authorize_client(client_ip: str) -> bool:
    ssh_cmd = f"nft add element {NFT_SET} {{ {client_ip} }}"
    cmd = [
        "ssh",
        "-i", SSH_KEY,
        "-o", "StrictHostKeyChecking=no",
        "-o", "ConnectTimeout=5",
        f"{ROUTER_USER}@{ROUTER_IP}",
        ssh_cmd
    ]
    try:
        log.info(f"Autorizando IP: {client_ip}")
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        log.info(f"SSH stdout: [{result.stdout}]")
        log.info(f"SSH stderr: [{result.stderr}]")
        log.info(f"SSH returncode: {result.returncode}")
        if result.returncode == 0:
            log.info(f"Cliente autorizado: {client_ip}")
            return True
        else:
            log.error(f"Error autorizando {client_ip}: {result.stderr}")
            return False
    except Exception as e:
        log.error(f"Excepción autorizando {client_ip}: {e}")
        return False

class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path == "/accept":
            client_ip = get_client_ip_from_router()
            if not client_ip:
                log.error("No se pudo detectar IP del cliente")
                self.send_response(500)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps({"ok": False, "error": "no se pudo detectar IP"}).encode())
                return

            success = authorize_client(client_ip)
            self.send_response(200 if success else 500)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(json.dumps({"ok": success, "ip": client_ip}).encode())
        else:
            self.send_response(404)
            self.end_headers()

    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"status":"ok"}')
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        log.info(f"{self.client_address[0]} - {format % args}")

if __name__ == "__main__":
    server = http.server.HTTPServer(("0.0.0.0", 8080), Handler)
    log.info("Backend captive portal escuchando en :8080")
    server.serve_forever()
