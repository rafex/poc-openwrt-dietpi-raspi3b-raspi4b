# Troubleshooting

## El portal no responde en http://192.168.1.167

```bash
# 1. Verificar que k3s está corriendo
ps aux | grep k3s

# 2. Verificar que el pod está 2/2 Running
k3s kubectl get pods -n default

# 3. Verificar que Traefik expone el puerto 80
k3s kubectl get svc -n kube-system | grep traefik
ss -tlnp | grep ':80'

# 4. Ver logs del pod
bash scripts/raspi-logs.sh
```

---

## nginx error: "connect() failed (111: Connection refused) upstream [::1]:8080"

**Causa:** nginx resuelve `localhost` a IPv6 `::1` en Alpine, pero el backend
Python solo escucha en IPv4 (`0.0.0.0`).

**Fix:** El ConfigMap nginx debe usar `127.0.0.1` explícito:
```nginx
proxy_pass http://127.0.0.1:8080/accept;   # ✅ correcto
# proxy_pass http://localhost:8080/accept;  # ❌ puede resolver a ::1
```

Verificar la versión activa:
```bash
k3s kubectl get configmap captive-portal-nginx-conf -o yaml | grep proxy_pass
```

Aplicar fix:
```bash
bash scripts/raspi-deploy.sh --no-build
```

---

## Backend devuelve `{"ok": false, "error": "no se pudo detectar IP"}`

Causas posibles en orden de probabilidad:

**1. El cliente no pasó por nftables (prueba directa)**
Si haces `curl -X POST http://192.168.1.167/accept` desde la laptop,
conntrack no tiene entrada — el request no fue redirigido por OpenWrt.
Esto es **normal** para pruebas directas. Solo funciona con clientes WiFi reales.

**2. nftables no está configurado en el router**
```bash
bash scripts/raspi-logs.sh --test   # Test 4 verifica la tabla
bash scripts/setup-openwrt.sh       # Configura el router
```

**3. SSH al router falla**
```bash
bash scripts/raspi-logs.sh --test   # Test 3 verifica SSH
# Si falla: la llave pública no está en el router
bash scripts/setup-openwrt.sh
```

**4. conntrack no tiene entradas de puerto 80**
El cliente puede ya tener una conexión `ESTABLISHED` que bypasea el forward.
Esperar a que expire o hacer `conntrack -F` en el router.

---

## SSH al router falla (Authentication failed)

La llave pública no está registrada en el router (puede haberse perdido con un reset).

```bash
# Verificar llave pública actual
cat /opt/keys/captive-portal.pub

# Re-registrar en el router (requiere contraseña root del router)
ssh-copy-id -i /opt/keys/captive-portal.pub root@192.168.1.1
# O manualmente:
ssh root@192.168.1.1   # con contraseña
# En el router:
cat >> /etc/dropbear/authorized_keys << 'EOF'
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL238prLPDMktu1deXGAFjQ5npVX1bQm+9Jugeiv9Uep captive-portal@rafexpi
EOF
```

---

## Me quedé bloqueado del router

El hook `forward` bloquea el tráfico WiFi → internet, pero el hook `input`
(acceso directo al router) no está afectado. Siempre puedes hacer SSH:

```bash
# Desde la laptop admin (192.168.1.128) — siempre funciona
ssh root@192.168.1.1

# En el router — eliminar tabla captive
nft delete table ip captive

# O ejecutar el script de emergencia desde la Pi
bash scripts/openwrt-reset-firewall.sh
```

---

## k3s no está corriendo (DietPi sin systemd)

```bash
# Verificar
ps aux | grep k3s

# Arrancar manualmente
/usr/local/bin/k3s server --write-kubeconfig-mode=644 &

# El script de status lo arranca automáticamente
bash scripts/raspi-k8s-status.sh
```

Para que arranque al inicio en DietPi (sin systemd como PID 1):
```bash
# Agregar al rc.local o al servicio de DietPi
echo '/usr/local/bin/k3s server --write-kubeconfig-mode=644 &' >> /etc/rc.local
```

---

## Pod en ImagePullBackOff (localhost/captive-backend:latest)

La imagen no está en containerd. Hay que importarla desde podman:

```bash
# Verificar si está en podman
podman images | grep captive-backend

# Si está, importar a containerd
podman save localhost/captive-backend:latest | k3s ctr images import -

# Si no está, reconstruir
bash scripts/raspi-deploy.sh
```

---

## nftables: "table already exists" al ejecutar setup-openwrt.sh

El script usa `add table` + `flush table` para ser idempotente. Si el error persiste:

```bash
# En el router
ssh root@192.168.1.1
nft delete table ip captive
# Luego volver a ejecutar setup-openwrt.sh
```

---

## dnsmasq no redirige los dominios de detección

```bash
# Verificar en el router
ssh root@192.168.1.1
nslookup connectivitycheck.gstatic.com 127.0.0.1

# Si no resuelve a 192.168.1.167:
cat /etc/dnsmasq.d/captive-portal.conf   # verificar que existe
/etc/init.d/dnsmasq reload
```

---

## Clientes conectados pero no redirigidos al portal

Posibles causas:
1. **conntrack tiene conexiones ESTABLISHED previas** → `conntrack -F` en el router
2. **El cliente tiene caché DNS** → el cliente debe renovar DNS o esperar TTL
3. **El cliente usa HTTPS directamente** → nftables solo redirige puerto 80
4. **La interfaz AP tiene nombre diferente a `phy0-ap0`** → verificar con `ip link show` en el router y actualizar `AP_IFACE` en `scripts/lib/common.sh`
