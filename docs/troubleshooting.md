# Troubleshooting

## El portal no responde en http://192.168.1.167

```bash
# 1. Verificar que k3s está corriendo
ps aux | grep k3s

# 2. Verificar que el pod está 2/2 Running
kubectl get pods -n default

# 3. Verificar que Traefik expone el puerto 80
kubectl get svc -n kube-system | grep traefik
ss -tlnp | grep ':80'

# 4. Ver logs del pod
bash scripts/raspi-logs.sh
```

---

## nginx error: "connect() failed (111: Connection refused) upstream [::1]:8080"

**Causa:** nginx resuelve `localhost` a IPv6 `::1` en Alpine, pero el backend
Python solo escucha en IPv4 (`0.0.0.0`).

**Fix:** El ConfigMap nginx usa `127.0.0.1` explícito:
```nginx
proxy_pass http://127.0.0.1:8080/accept;   # ✅ correcto
# proxy_pass http://localhost:8080/accept;  # ❌ resuelve a ::1
```

Verificar:
```bash
kubectl get configmap captive-portal-nginx-conf -o yaml | grep proxy_pass
bash scripts/raspi-deploy.sh --no-build
```

---

## Backend devuelve `{"ok": false, "error": "no se pudo detectar IP del cliente"}`

Causas posibles en orden de probabilidad:

**1. IP que llega al backend no es de la LAN (192.168.1.X)**

Ver logs del backend:
```bash
bash scripts/raspi-logs.sh --backend --lines=50
```

Si aparece `X-Real-IP='10.42.0.1'`:
→ El problema es en Traefik o nginx. Ver secciones abajo.

**2. nftables no está configurado en el router**
```bash
bash scripts/raspi-logs.sh --test   # Test 4 verifica la tabla
bash scripts/setup-openwrt.sh
```

**3. SSH al router falla**
```bash
bash scripts/raspi-logs.sh --test   # Test 3 verifica SSH
bash scripts/setup-openwrt.sh
```

**4. Prueba directa desde laptop (curl)**
Si haces `curl -X POST http://192.168.1.167/accept` directamente,
conntrack no tiene entrada — no pasó por el DNAT del router.
Esto es normal. Solo funciona con clientes WiFi reales.

---

## IP del cliente aparece como 10.42.0.1 en los logs

El tráfico pasa por kube-proxy que hace SNAT, borrando la IP real del cliente.

**Verificar Traefik:**
```bash
kubectl get svc traefik -n kube-system -o jsonpath='{.spec.externalTrafficPolicy}'
# Debe responder: Local
```

**Si dice `Cluster`:**
```bash
kubectl apply -f k8s/traefik-helmchartconfig.yaml
kubectl rollout status deployment/traefik -n kube-system --timeout=120s
```

El archivo debe contener:
```yaml
service:
  spec:
    externalTrafficPolicy: Local
```

**Verificar nginx realip:**
```bash
kubectl get configmap captive-portal-nginx-conf -o yaml | grep -A3 "set_real_ip_from"
```

Debe contener:
```nginx
set_real_ip_from 10.42.0.0/16;
real_ip_header X-Forwarded-For;
real_ip_recursive on;
```

---

## Clientes se conectan al WiFi pero navegan sin pasar por el portal

**Causa más probable:** las reglas nftables usan `iifname "phy0-ap0"` pero el
tráfico viaja por el bridge `br-lan` — ninguna regla hace match y todo pasa.

**Verificar:**
```bash
ssh -i /opt/keys/captive-portal root@192.168.1.1 "nft list table ip captive"
```

Las reglas correctas deben usar `ip saddr 192.168.1.0/24`, NO `iifname "phy0-ap0"`:
```
ip saddr 192.168.1.0/24 drop   # al final de forward_captive
```

**Fix:**
```bash
bash scripts/setup-openwrt.sh  # recarga con las reglas correctas
```

---

## nftables: "File exists" / "Could not process rule" al ejecutar setup-openwrt.sh

**Causa:** `nft -c -f` (dry-run) falla porque la tabla ya existe en el kernel
y el archivo intenta redeclararla. `flush table` solo vacía las cadenas, no el set.

**El script ya maneja esto** eliminando la tabla antes del dry-run:
```sh
nft delete table ip captive 2>/dev/null || true
nft -c -f /tmp/captive-portal.nft
```

Si persiste, eliminar manualmente y volver a ejecutar:
```bash
ssh -i /opt/keys/captive-portal root@192.168.1.1 "nft delete table ip captive"
bash scripts/setup-openwrt.sh
```

---

## nftables: "syntax error, unexpected number" en `timeout 0`

**Causa:** Esta versión de nftables en OpenWrt requiere unidad en todos los timeouts.

**Fix:** Usar `timeout 0s` (con `s`) en lugar de `timeout 0`.

Este fix ya está aplicado en todos los scripts. Si ves el error, el script
tiene una versión vieja — hacer `git pull` en la Pi.

---

## Admin/Raspis aparecen con `expires 118m` (no son permanentes)

**Causa:** `router_add_ip` fue llamado sin `timeout 0s` explícito y heredó
el timeout por defecto del set (120m).

**Fix:** La función `router_add_ip` en `common.sh` ya aplica `timeout 0s`
automáticamente para `ADMIN_IP`, `RASPI4B_IP` y `RASPI3B_IP`.

Si ocurre igualmente, forzar manualmente los tres permanentes:
```bash
ssh -i /opt/keys/captive-portal root@192.168.1.1 \
  "nft add element ip captive allowed_clients { 192.168.1.113 timeout 0s }"  # admin
ssh -i /opt/keys/captive-portal root@192.168.1.1 \
  "nft add element ip captive allowed_clients { 192.168.1.167 timeout 0s }"  # RafexPi4B
ssh -i /opt/keys/captive-portal root@192.168.1.1 \
  "nft add element ip captive allowed_clients { 192.168.1.181 timeout 0s }"  # RafexPi3B
```

---

## SSH al router falla (Authentication failed)

La llave pública no está registrada (puede haberse perdido con un reset).

```bash
# Verificar llave pública actual
cat /opt/keys/captive-portal.pub

# Re-registrar (requiere contraseña root del router)
ssh root@192.168.1.1   # con contraseña
# En el router:
cat >> /etc/dropbear/authorized_keys << 'EOF'
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL238prLPDMktu1deXGAFjQ5npVX1bQm+9Jugeiv9Uep captive-portal@rafexpi
EOF
```

O simplemente ejecutar `setup-openwrt.sh` que lo hace automáticamente (FASE A).

---

## Me quedé bloqueado del router / nadie tiene internet

El hook `forward` bloquea tráfico WiFi → internet, pero el hook `input`
(acceso directo al router) no está afectado. Acceder siempre es posible:

```bash
# Desde la laptop admin (192.168.1.113) — siempre funciona
ssh root@192.168.1.1

# En el router — eliminar tabla y restaurar internet a todos
nft delete table ip captive

# O desde la Pi
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

Para que arranque al inicio en DietPi:
```bash
echo '/usr/local/bin/k3s server --write-kubeconfig-mode=644 &' >> /etc/rc.local
```

---

## Pod en ImagePullBackOff (localhost/captive-backend:latest)

La imagen no está en containerd — hay que importarla desde podman:

```bash
podman images | grep captive-backend

# Si está en podman, importar a containerd
podman save localhost/captive-backend:latest | k3s ctr images import -

# Si no está, reconstruir
bash scripts/raspi-deploy.sh
```

---

## dnsmasq no redirige los dominios de detección

```bash
# Verificar en el router
ssh -i /opt/keys/captive-portal root@192.168.1.1 \
  "nslookup connectivitycheck.gstatic.com 127.0.0.1"
# Debe responder: Address: 192.168.1.167

# Si no resuelve:
ssh -i /opt/keys/captive-portal root@192.168.1.1 \
  "cat /etc/dnsmasq.conf | grep 192.168.1.167"
# Debe haber líneas address=/.../192.168.1.167

# Recargar dnsmasq
ssh -i /opt/keys/captive-portal root@192.168.1.1 \
  "/etc/init.d/dnsmasq reload"
```

Si no hay entradas, ejecutar `bash scripts/setup-openwrt.sh`.

---

## El sensor no envía batches al analizador

```bash
# 1. Verificar que el servicio está corriendo en RafexPi3B
/etc/init.d/network-sensor status
tail -30 /var/log/network-sensor.log

# 2. Verificar conectividad MQTT desde RafexPi3B
mosquitto_pub -h 192.168.1.167 -p 1883 -t "test/ping" -m "pong"
# Si falla → Mosquitto no escucha o la red bloquea el puerto 1883

# 3. Verificar que Mosquitto corre en RafexPi4B
/etc/init.d/mosquitto status
mosquitto_sub -h 127.0.0.1 -t "rafexpi/sensor/batch" -v

# 4. Probar el fallback HTTP directamente
curl -s -X POST http://192.168.1.167/api/ingest \
  -H "Content-Type: application/json" \
  -d '{"duration_s":30,"packets":100,"bytes":5000,"sensor_ip":"192.168.1.181"}' | python3 -m json.tool
```

---

## El analizador IA recibe batches pero no produce análisis

```bash
# 1. Ver cola pendiente
curl -s http://192.168.1.167/api/queue | python3 -m json.tool

# 2. Verificar que llama-server responde
curl -s http://192.168.1.167:8081/health
/etc/init.d/llama-server status
tail -20 /var/log/llama-server.log

# 3. Ver logs del worker en el pod
kubectl logs -f deploy/ai-analyzer | grep -E "worker|batch|error|ALTO|MEDIO|BAJO"
```

Si `llama-server` no responde:
```bash
/etc/init.d/llama-server restart
# Esperar ~30s para que cargue el modelo
curl -s http://127.0.0.1:8081/health
```

---

## La reserva DHCP de una Raspi no funciona / obtiene IP aleatoria

```bash
# Verificar que la reserva está en el router
ssh -i /opt/keys/captive-portal root@192.168.1.1 \
  "uci show dhcp | grep -A4 'RafexPi'"

# Verificar que dnsmasq la aplicó
ssh -i /opt/keys/captive-portal root@192.168.1.1 \
  "cat /tmp/dhcp.leases | grep -E 'd8:3a|b8:27'"
```

Si no existe la reserva, volver a aplicarla manualmente:
```bash
# Para RafexPi4B
bash scripts/openwrt-reserve-raspi.sh --mac d8:3a:dd:4d:4b:ae --ip 192.168.1.167

# Para RafexPi3B
bash scripts/openwrt-reserve-raspi.sh --mac b8:27:eb:5a:ec:33 --ip 192.168.1.181

# O re-ejecutar el setup completo del router (FASE C.1 hace las dos)
bash scripts/setup-openwrt.sh
```

---

## Clientes tienen sesiones ESTABLISHED que bypasean el bloqueo

Cuando se activan o recargan las reglas nftables, las conexiones TCP ya
establecidas (ESTABLISHED) no pasan por el hook forward — conntrack las acepta
directamente. Para forzar reconexión:

```bash
ssh -i /opt/keys/captive-portal root@192.168.1.1 "conntrack -F && echo OK"
```

> ⚠️ Esto corta TODAS las conexiones activas en el router, incluyendo la SSH.
> La conexión SSH se recupera automáticamente en segundos.
