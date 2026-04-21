cat > /opt/repository/poc-openwrt-dietpi-raspi3b-raspi4b/k8s/captive-portal.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: captive-portal
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: captive-portal
  template:
    metadata:
      labels:
        app: captive-portal
    spec:
      containers:
      - name: portal
        image: nginx:alpine
        ports:
        - containerPort: 80
        volumeMounts:
        - name: portal-html
          mountPath: /usr/share/nginx/html
      volumes:
      - name: portal-html
        configMap:
          name: captive-portal-html
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: captive-portal-html
  namespace: default
data:
  index.html: |
    <!DOCTYPE html>
    <html>
    <head><title>Portal RafexPi</title></head>
    <body>
      <h1>Bienvenido a la red WiFi demo</h1>
      <p>Esta red es una demostración educativa de seguridad.</p>
    </body>
    </html>
---
apiVersion: v1
kind: Service
metadata:
  name: captive-portal
  namespace: default
spec:
  selector:
    app: captive-portal
  ports:
  - port: 80
    targetPort: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: captive-portal
  namespace: default
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: web
spec:
  rules:
  - http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: captive-portal
            port:
              number: 80
EOF

kubectl apply -f /opt/repository/poc-openwrt-dietpi-raspi3b-raspi4b/k8s/captive-portal.yaml
kubectl get pods -w

---

cat > /opt/repository/poc-openwrt-dietpi-raspi3b-raspi4b/k8s/captive-portal-update.yaml << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: captive-portal-nginx-conf
  namespace: default
data:
  default.conf: |
    server {
        listen 80 default_server;
        server_name _;

        # iOS detection
        location /hotspot-detect.html {
            return 302 http://192.168.1.167/portal;
        }

        # Android detection
        location /generate_204 {
            return 302 http://192.168.1.167/portal;
        }

        # Windows detection
        location /connecttest.txt {
            return 302 http://192.168.1.167/portal;
        }

        # Firefox detection
        location /success.txt {
            return 302 http://192.168.1.167/portal;
        }

        # Portal principal
        location /portal {
            default_type text/html;
            root /usr/share/nginx/html;
            try_files /index.html =404;
        }

        # Redirect todo lo demás al portal
        location / {
            return 302 http://192.168.1.167/portal;
        }
    }
  index.html: |
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="UTF-8">
      <title>Portal RafexPi - Demo Seguridad</title>
    </head>
    <body>
      <h1>Bienvenido a la red WiFi demo</h1>
      <p>Esta red es una demostración educativa de seguridad con IA.</p>
      <button onclick="window.location.href='http://192.168.1.167/accept'">
        Entendido, quiero navegar
      </button>
    </body>
    </html>
EOF

kubectl apply -f /opt/repository/poc-openwrt-dietpi-raspi3b-raspi4b/k8s/captive-portal-update.yaml

---

cat > /opt/repository/poc-openwrt-dietpi-raspi3b-raspi4b/k8s/captive-portal-deployment.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: captive-portal
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: captive-portal
  template:
    metadata:
      labels:
        app: captive-portal
    spec:
      containers:
      - name: portal
        image: nginx:alpine
        ports:
        - containerPort: 80
        volumeMounts:
        - name: nginx-conf
          mountPath: /etc/nginx/conf.d/default.conf
          subPath: default.conf
        - name: nginx-conf
          mountPath: /usr/share/nginx/html/index.html
          subPath: index.html
      volumes:
      - name: nginx-conf
        configMap:
          name: captive-portal-nginx-conf
EOF

kubectl apply -f /opt/repository/poc-openwrt-dietpi-raspi3b-raspi4b/k8s/captive-portal-deployment.yaml
kubectl rollout restart deployment/captive-portal
kubectl rollout status deployment/captive-portal

---

cat > /opt/repository/poc-openwrt-dietpi-raspi3b-raspi4b/k8s/captive-portal-v2.yaml << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: captive-portal-nginx-conf
  namespace: default
data:
  default.conf: |
    server {
        listen 80 default_server;
        server_name _;

        location /hotspot-detect.html {
            return 302 http://192.168.1.167/portal;
        }
        location /generate_204 {
            return 302 http://192.168.1.167/portal;
        }
        location /connecttest.txt {
            return 302 http://192.168.1.167/portal;
        }
        location /success.txt {
            return 302 http://192.168.1.167/portal;
        }
        location /portal {
            default_type text/html;
            root /usr/share/nginx/html;
            try_files /index.html =404;
        }
        location /accepted {
            default_type text/html;
            root /usr/share/nginx/html;
            try_files /accepted.html =404;
        }
        location / {
            return 302 http://192.168.1.167/portal;
        }
    }
  index.html: |
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Portal RafexPi - Demo Seguridad</title>
      <style>
        body { font-family: sans-serif; max-width: 400px; margin: 40px auto; padding: 20px; text-align: center; }
        button { background: #2563eb; color: white; border: none; padding: 14px 28px; font-size: 16px; border-radius: 8px; cursor: pointer; margin-top: 20px; width: 100%; }
        button:hover { background: #1d4ed8; }
        .warning { background: #fef3c7; border: 1px solid #f59e0b; padding: 12px; border-radius: 8px; margin: 16px 0; font-size: 14px; }
      </style>
    </head>
    <body>
      <h1>🔒 Red WiFi Demo</h1>
      <p>Esta es una demostración educativa de seguridad en redes públicas con IA.</p>
      <div class="warning">
        ⚠️ Esta red monitorea metadatos de tráfico con fines educativos.
      </div>
      <p>Al continuar, aceptas participar en la demo.</p>
      <button onclick="accept()">Entendido, quiero navegar</button>
      <script>
        function accept() {
          fetch('/accept', { method: 'POST' })
            .then(() => window.location.href = '/accepted')
            .catch(() => window.location.href = '/accepted');
        }
      </script>
    </body>
    </html>
  accepted.html: |
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Conectado</title>
      <style>
        body { font-family: sans-serif; max-width: 400px; margin: 40px auto; padding: 20px; text-align: center; }
        .ok { color: #16a34a; font-size: 48px; }
      </style>
    </head>
    <body>
      <div class="ok">✓</div>
      <h2>¡Conectado!</h2>
      <p>Ya puedes navegar libremente.</p>
      <p><a href="https://google.com">Ir a internet</a></p>
    </body>
    </html>
EOF

kubectl apply -f /opt/repository/poc-openwrt-dietpi-raspi3b-raspi4b/k8s/captive-portal-v2.yaml
kubectl rollout restart deployment/captive-portal
kubectl rollout status deployment/captive-portal

---

cat > /opt/repository/poc-openwrt-dietpi-raspi3b-raspi4b/k8s/captive-portal-deployment.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: captive-portal
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: captive-portal
  template:
    metadata:
      labels:
        app: captive-portal
    spec:
      containers:
      - name: portal
        image: nginx:alpine
        ports:
        - containerPort: 80
        volumeMounts:
        - name: nginx-conf
          mountPath: /etc/nginx/conf.d/default.conf
          subPath: default.conf
        - name: nginx-conf
          mountPath: /usr/share/nginx/html/index.html
          subPath: index.html
        - name: nginx-conf
          mountPath: /usr/share/nginx/html/accepted.html
          subPath: accepted.html
      volumes:
      - name: nginx-conf
        configMap:
          name: captive-portal-nginx-conf
EOF

kubectl apply -f /opt/repository/poc-openwrt-dietpi-raspi3b-raspi4b/k8s/captive-portal-deployment.yaml
kubectl rollout restart deployment/captive-portal
kubectl rollout status deployment/captive-portal

---

cat > /tmp/captive-portal-deployment.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: captive-portal
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: captive-portal
  template:
    metadata:
      labels:
        app: captive-portal
    spec:
      containers:
      - name: portal
        image: nginx:alpine
        ports:
        - containerPort: 80
        volumeMounts:
        - name: nginx-conf
          mountPath: /etc/nginx/conf.d/default.conf
          subPath: default.conf
        - name: nginx-conf
          mountPath: /usr/share/nginx/html/index.html
          subPath: index.html
        - name: nginx-conf
          mountPath: /usr/share/nginx/html/accepted.html
          subPath: accepted.html
        - name: ssh-keys
          mountPath: /opt/keys
          readOnly: true
      volumes:
      - name: nginx-conf
        configMap:
          name: captive-portal-nginx-conf
      - name: ssh-keys
        hostPath:
          path: /opt/keys
          type: Directory
EOF

kubectl apply -f /tmp/captive-portal-deployment.yaml
kubectl rollout restart deployment/captive-portal
kubectl rollout status deployment/captive-portal

---

mkdir -p /opt/repository/poc-openwrt-dietpi-raspi3b-raspi4b/backend/captive-portal

cat > /opt/repository/poc-openwrt-dietpi-raspi3b-raspi4b/backend/captive-portal/backend.py << 'EOF'
import http.server
import subprocess
import json
import logging

logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s')
log = logging.getLogger(__name__)

ROUTER_IP = "192.168.1.1"
ROUTER_USER = "root"
SSH_KEY = "/opt/keys/captive-portal"
NFT_SET = "ip captive_fw allowed_clients"

def authorize_client(client_ip: str) -> bool:
    cmd = [
        "ssh",
        "-i", SSH_KEY,
        "-o", "StrictHostKeyChecking=no",
        "-o", "ConnectTimeout=5",
        f"{ROUTER_USER}@{ROUTER_IP}",
        f"nft add element {NFT_SET} {{ {client_ip} }}"
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
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
            client_ip = self.headers.get("X-Forwarded-For") or self.client_address[0]
            client_ip = client_ip.split(",")[0].strip()
            log.info(f"Solicitud de autorización para IP: {client_ip}")
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
EOF

---

cat > /opt/repository/poc-openwrt-dietpi-raspi3b-raspi4b/backend/captive-portal/Dockerfile << 'EOF'
FROM python:3.12-alpine
RUN apk add --no-cache openssh-client
WORKDIR /app
COPY backend.py .
CMD ["python", "backend.py"]
EOF

---

cat > /opt/repository/poc-openwrt-dietpi-raspi3b-raspi4b/backend/captive-portal/Dockerfile << 'EOF'
FROM python:3.13-alpine3.23
RUN apk add --no-cache openssh-client
WORKDIR /app
COPY backend.py .
CMD ["python", "backend.py"]
EOF

---

cat > /tmp/captive-portal-deployment.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: captive-portal
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: captive-portal
  template:
    metadata:
      labels:
        app: captive-portal
    spec:
      containers:
      - name: portal
        image: nginx:alpine
        ports:
        - containerPort: 80
        volumeMounts:
        - name: nginx-conf
          mountPath: /etc/nginx/conf.d/default.conf
          subPath: default.conf
        - name: nginx-conf
          mountPath: /usr/share/nginx/html/index.html
          subPath: index.html
        - name: nginx-conf
          mountPath: /usr/share/nginx/html/accepted.html
          subPath: accepted.html
        - name: ssh-keys
          mountPath: /opt/keys
          readOnly: true
      - name: backend
        image: captive-backend:latest
        imagePullPolicy: Never
        ports:
        - containerPort: 8080
        volumeMounts:
        - name: ssh-keys
          mountPath: /opt/keys
          readOnly: true
      volumes:
      - name: nginx-conf
        configMap:
          name: captive-portal-nginx-conf
      - name: ssh-keys
        hostPath:
          path: /opt/keys
          type: Directory
EOF

kubectl apply -f /tmp/captive-portal-deployment.yaml
kubectl rollout restart deployment/captive-portal
kubectl rollout status deployment/captive-portal

---

cat > /tmp/captive-portal-deployment.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: captive-portal
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: captive-portal
  template:
    metadata:
      labels:
        app: captive-portal
    spec:
      containers:
      - name: portal
        image: nginx:alpine
        ports:
        - containerPort: 80
        volumeMounts:
        - name: nginx-conf
          mountPath: /etc/nginx/conf.d/default.conf
          subPath: default.conf
        - name: nginx-conf
          mountPath: /usr/share/nginx/html/index.html
          subPath: index.html
        - name: nginx-conf
          mountPath: /usr/share/nginx/html/accepted.html
          subPath: accepted.html
        - name: ssh-keys
          mountPath: /opt/keys
          readOnly: true
      - name: backend
        image: localhost/captive-backend:latest
        imagePullPolicy: Never
        ports:
        - containerPort: 8080
        volumeMounts:
        - name: ssh-keys
          mountPath: /opt/keys
          readOnly: true
      volumes:
      - name: nginx-conf
        configMap:
          name: captive-portal-nginx-conf
      - name: ssh-keys
        hostPath:
          path: /opt/keys
          type: Directory
EOF

kubectl apply -f /tmp/captive-portal-deployment.yaml
kubectl rollout restart deployment/captive-portal
kubectl rollout status deployment/captive-portal

---

# Probar desde dentro del pod
kubectl exec -it $(kubectl get pod -l app=captive-portal -o jsonpath='{.items[0].metadata.name}') -c backend -- wget -qO- http://localhost:8080/health

cat > /tmp/captive-portal-svc.yaml << 'EOF'
apiVersion: v1
kind: Service
metadata:
  name: captive-portal
  namespace: default
spec:
  selector:
    app: captive-portal
  ports:
  - name: http
    port: 80
    targetPort: 80
  - name: backend
    port: 8080
    targetPort: 8080
EOF

kubectl apply -f /tmp/captive-portal-svc.yaml

---

cd /opt/captive-portal
podman build --runtime=runc --network=host -t captive-backend:latest .
podman save captive-backend:latest | k3s ctr images import -
kubectl rollout restart deployment/captive-portal
kubectl rollout status deployment/captive-portal

kubectl logs -f -l app=captive-portal -c backend

---

cat > /opt/repository/poc-openwrt-dietpi-raspi3b-raspi4b/backend/captive-portal/backend.py << 'EOF'
import http.server
import subprocess
import json
import logging

logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s')
log = logging.getLogger(__name__)

ROUTER_IP = "192.168.1.1"
ROUTER_USER = "root"
SSH_KEY = "/opt/keys/captive-portal"
NFT_SET = "ip captive_fw allowed_clients"

def get_client_ip_from_router() -> str:
    cmd = [
        "ssh",
        "-i", SSH_KEY,
        "-o", "StrictHostKeyChecking=no",
        "-o", "ConnectTimeout=5",
        f"{ROUTER_USER}@{ROUTER_IP}",
        "cat /proc/net/nf_conntrack | grep 'dport=80' | grep 'ESTABLISHED' | grep -oP 'src=\\K[0-9.]+' | grep -v '192.168.1.167' | grep -v '10.42.' | head -1"
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        ip = result.stdout.strip()
        log.info(f"IP detectada desde conntrack: {ip}")
        return ip
    except Exception as e:
        log.error(f"Error obteniendo IP desde router: {e}")
        return ""

def authorize_client(client_ip: str) -> bool:
    cmd = [
        "ssh",
        "-i", SSH_KEY,
        "-o", "StrictHostKeyChecking=no",
        "-o", "ConnectTimeout=5",
        f"{ROUTER_USER}@{ROUTER_IP}",
        f"nft add element {NFT_SET} {{ {client_ip} }}"
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
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
EOF

---

cd /opt/repository/poc-openwrt-dietpi-raspi3b-raspi4b/backend/captive-portal
podman build --runtime=runc --network=host -t captive-backend:latest .
podman save captive-backend:latest | k3s ctr images import -
kubectl rollout restart deployment/captive-portal
kubectl rollout status deployment/captive-portal

---

ssh -i /opt/keys/captive-portal root@192.168.1.1 \
  "cat /proc/net/nf_conntrack | grep dport=80 | grep ESTABLISHED | awk '{print \$7}' | sed 's/src=//' | grep '192.168.1.' | grep -v '192.168.1.167' | head -1"

---

cat > /opt/repository/poc-openwrt-dietpi-raspi3b-raspi4b/backend/captive-portal/backend.py << 'EOF'
import http.server
import subprocess
import json
import logging

logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s')
log = logging.getLogger(__name__)

ROUTER_IP = "192.168.1.1"
ROUTER_USER = "root"
SSH_KEY = "/opt/keys/captive-portal"
NFT_SET = "ip captive_fw allowed_clients"

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
EOF

---

nft list table ip captive_fw

nft delete element ip captive_fw allowed_clients { 10.42.0.10, 10.42.0.29, 10.42.0.33 }

nft add element ip captive_fw allowed_clients { 192.168.1.100 }

---

# Limpiar el set y dejar solo 192.168.1.128
nft flush set ip captive_fw allowed_clients
nft add element ip captive_fw allowed_clients { 192.168.1.128 }

# Verificar
nft list set ip captive_fw allowed_clients

---

nft list table ip captive_fw

nft -a list table ip captive_fw

---

# Eliminar la cadena actual y recrearla con prioridad mayor
nft delete chain ip captive_fw forward

nft add chain ip captive_fw forward '{ type filter hook forward priority 100; policy accept; }'
nft add rule ip captive_fw forward ip daddr 192.168.1.167 counter accept
nft add rule ip captive_fw forward ip saddr @allowed_clients counter accept
nft add rule ip captive_fw forward iifname "phy0-ap0" counter drop

---

# Insertar regla de bloqueo WiFi al inicio de forward_lan
nft insert rule inet fw4 forward_lan iifname "phy0-ap0" ip saddr != 192.168.1.128 ip daddr != 192.168.1.167 drop

---
Lo veo. El tráfico pasa por `fw4 forward` que tiene:

```
ct state vmap { established : accept, related : accept }
```

**Esa línea acepta todas las conexiones ya establecidas antes de llegar a `forward_lan`.** Como el celular ya tenía conexiones establecidas, el conntrack las acepta directamente sin evaluar tus reglas.

Necesitas limpiar el conntrack del celular para forzar que todas sus conexiones pasen por las reglas nuevas:

```bash
# Eliminar entradas de conntrack del celular (192.168.1.224)
conntrack -D -s 192.168.1.224 2>/dev/null || \
cat /proc/net/nf_conntrack | grep "src=192.168.1.224" | wc -l
```

Si `conntrack` no está disponible en OpenWrt:

```bash
# Forzar limpieza reiniciando el seguimiento
echo 1 > /proc/sys/net/netfilter/nf_conntrack_max
echo 1 > /proc/sys/net/netfilter/nf_conntrack_max
```

O más directo, desconecta y reconecta el celular del WiFi — eso debería crear conexiones nuevas que sí pasen por tus reglas.

¿Al reconectar el celular se bloquea?
---

