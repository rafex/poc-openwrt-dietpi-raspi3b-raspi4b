# Guía de Setup — Captive Portal + IA Local

## Dispositivos y prerequisitos

| Dispositivo | Hostname | IP | Requisitos |
|---|---|---|---|
| Router OpenWrt | — | 192.168.1.1 | OpenWrt 25.x, SSH root, nftables, dnsmasq |
| Raspberry Pi 4B | RafexPi4B | 192.168.1.167 | DietPi, k3s v1.32+, podman, llama.cpp compilado |
| Raspberry Pi 3B | RafexPi3B | 192.168.1.181 | DietPi, acceso root, red LAN |
| Laptop admin | — | 192.168.1.113 | Acceso SSH, repositorio clonado |

---

## Paso 1 — Clonar el repositorio en RafexPi4B

```bash
mkdir -p /opt/repository
cd /opt/repository
git clone <url-repo> poc-openwrt-dietpi-raspi3b-raspi4b
cd poc-openwrt-dietpi-raspi3b-raspi4b
```

---

## Paso 2 — Setup del router OpenWrt

Ejecutar **desde RafexPi4B**. Configura nftables, dnsmasq, DHCP y las reservas permanentes de ambas Raspis.

```bash
bash scripts/setup-openwrt.sh
```

Qué hace:

| Fase | Qué hace |
|---|---|
| Pre-flight | Verifica espacio en overlay, interfaz `phy0-ap0`, SSH al router |
| A | Agrega llave pública al router (`/etc/dropbear/authorized_keys`) |
| B | Configura dnsmasq — dominios de detección → `192.168.1.167`; **lease time 120m** |
| C | Crea tabla nftables `ip captive`: timeout **120m** para clientes; **RafexPi4B y RafexPi3B permanentes** (timeout 0s) |
| C.1 | **Reservas DHCP UCI permanentes** para RafexPi4B (`d8:3a:dd:4d:4b:ae → 192.168.1.167`) y RafexPi3B (`b8:27:eb:5a:ec:33 → 192.168.1.181`) con `leasetime=infinite` |
| D | Verifica la configuración completa |

> ⚠️ **Seguridad**: en caso de quedarse bloqueado del router:
> ```bash
> ssh root@192.168.1.1   # SSH al router no pasa por el hook forward
> nft delete table ip captive
> ```

---

## Paso 3 — Setup de RafexPi4B (IA + k3s)

Instala todo el stack IA: Mosquitto, llama-server, ai-analyzer en k3s, captive portal.
También configura el hostname y la reserva DHCP de esta Raspi en el router.

```bash
sudo bash scripts/setup-ai-raspi4b.sh
```

Opciones:

```bash
sudo bash scripts/setup-ai-raspi4b.sh --no-build   # omitir build de imagen
sudo bash scripts/setup-ai-raspi4b.sh --no-llama   # omitir llama-server
```

Qué hace:

| Fase | Qué hace |
|---|---|
| Hostname | Configura `/etc/hostname` = `RafexPi4B` |
| DHCP | SSH al router → UCI reserva `RafexPi4B  d8:3a:dd:4d:4b:ae → 192.168.1.167  infinite` |
| Pre-flight | Verifica k3s corriendo, podman disponible |
| A0 | Instala Mosquitto, configura `:1883 allow_anonymous true`, habilita en arranque |
| A | Localiza binario `llama-server` y modelo `tinyllama*.gguf` (busca rutas habituales + find) |
| B | Genera servicio init.d `llama-server`: `ctx-size=4096 --parallel 1 --threads 4` |
| C | `podman build --cgroup-manager=cgroupfs --platform linux/arm64` imagen `ai-analyzer` |
| D | `podman save \| k3s ctr images import -` |
| E | `kubectl apply` ai-analyzer + limpieza recursos legacy |
| F | Verifica pods, `/health`, `/dashboard` |

**Prerequisito llama.cpp:** el modelo TinyLlama Q4_K_M debe estar descargado:

```bash
mkdir -p /opt/models
wget -O /opt/models/tinyllama-1.1b-chat-q4.gguf \
  https://huggingface.co/TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF/resolve/main/\
tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf
```

---

## Paso 4 — Setup de RafexPi3B (sensor de red)

Instala tshark, Python, paho-mqtt, el sensor y su servicio init.d.
También configura el hostname y la reserva DHCP de esta Raspi en el router.

Ejecutar **en RafexPi3B** (copiar el repo o transferir los archivos necesarios):

```bash
sudo bash scripts/setup-sensor-raspi3b.sh
```

Opciones:

```bash
sudo bash scripts/setup-sensor-raspi3b.sh --no-ssh    # omitir configuración SSH al router
sudo bash scripts/setup-sensor-raspi3b.sh --dry-run   # solo mostrar qué haría
```

Qué hace:

| Fase | Qué hace |
|---|---|
| Hostname | Configura `/etc/hostname` = `RafexPi3B` |
| Pre-flight | Verifica interfaz eth0, IP activa |
| A | Instala: `tshark tcpdump python3 python3-pip openssh-client iproute2 curl` |
| B | Copia `sensor/sensor.py` → `/opt/sensor/sensor.py` |
| C | Instala dependencias Python: `requests`, `paho-mqtt` |
| D | Genera llave SSH `/opt/keys/sensor` (ed25519); intenta copiarla al router automáticamente |
| D.1 | SSH al router con la llave del sensor → UCI reserva `RafexPi3B  b8:27:eb:5a:ec:33 → 192.168.1.181  infinite` |
| E | Genera servicio init.d `/etc/init.d/network-sensor` con todas las env vars; lo habilita e inicia |
| F | Verifica que el servicio corre, tshark captura, el analizador responde |

**Variables de entorno del servicio** (configurables antes de ejecutar el script):

```bash
export MQTT_HOST="192.168.1.167"        # broker Mosquitto en RafexPi4B
export MQTT_PORT="1883"
export MQTT_TOPIC="rafexpi/sensor/batch"
export ANALYZER_URL="http://192.168.1.167/api/ingest"  # fallback HTTP
export ROUTER_IP="192.168.1.1"
```

---

## Paso 5 — Verificar el sistema completo

```bash
# Desde RafexPi4B — diagnóstico completo
bash scripts/sensor-status.sh

# Con tests funcionales
bash scripts/sensor-status.sh --test

# Logs en vivo del analizador
bash scripts/sensor-status.sh --follow
```

| Recurso | URL |
|---|---|
| Dashboard visual | http://192.168.1.167/dashboard |
| Terminal en vivo | http://192.168.1.167/terminal |
| API historial | http://192.168.1.167/api/history |
| API stats | http://192.168.1.167/api/stats |
| Health check | http://192.168.1.167/health |

---

## Paso 6 — Prueba real con dispositivo WiFi

1. Conectar el celular al WiFi "INFINITUM MOVIL"
2. Abrir URL HTTP: `http://neverssl.com` o `http://example.com`
3. El router redirige al portal: `http://192.168.1.167/portal`
4. Sin aceptar: sin internet
5. Aceptar: navegar libremente durante **120 minutos**
6. Verificar clientes autorizados:

```bash
bash scripts/openwrt-list-clients.sh
```

> ⚠️ Los navegadores modernos abren HTTPS por defecto. La detección automática
> de captive portal (Android/iOS) usa HTTP — eso sí dispara el portal.

---

## Flujo de actualización

### Actualizar el analizador IA (código Python, HTML)

```bash
# En RafexPi4B — rebuild + reimport + rollout restart
sudo bash scripts/setup-ai-raspi4b.sh --no-llama

# Solo rollout (si la imagen ya está importada)
kubectl rollout restart deployment/ai-analyzer
kubectl rollout status deployment/ai-analyzer --timeout=120s
```

### Actualizar el sensor

```bash
# En RafexPi3B — copia sensor.py y reinicia el servicio
cp sensor/sensor.py /opt/sensor/sensor.py
/etc/init.d/network-sensor restart
```

### Reconfigurar el router desde cero

```bash
bash scripts/setup-openwrt.sh
```

---

## Diagnóstico rápido

```bash
# Estado del sistema completo
bash scripts/sensor-status.sh

# Estado de k3s
kubectl get pods -A
kubectl get nodes

# Logs del analizador
kubectl logs -f deploy/ai-analyzer

# Estado del sensor (en RafexPi3B)
/etc/init.d/network-sensor status

# Logs del sensor
tail -f /var/log/network-sensor.log

# Estado de Mosquitto
/etc/init.d/mosquitto status
mosquitto_sub -h 192.168.1.167 -t "rafexpi/sensor/batch" -v

# Estado de llama-server
/etc/init.d/llama-server status
curl -s http://192.168.1.167:8081/health
```

---

## Gestión de clientes WiFi

```bash
# Listar clientes autorizados, leases DHCP y conexiones activas
bash scripts/openwrt-list-clients.sh

# Autorizar manualmente una IP (sin pasar por el portal)
bash scripts/openwrt-allow-client.sh 192.168.1.55
bash scripts/openwrt-allow-client.sh 192.168.1.55 --permanent  # sin expiración

# Bloquear una IP (vuelve al portal)
bash scripts/openwrt-block-client.sh 192.168.1.55

# Resetear todos los clientes al portal (para demo)
bash scripts/openwrt-flush-clients.sh
bash scripts/openwrt-flush-clients.sh --force   # sin confirmación

# Emergencia — desactivar todo el captive portal
bash scripts/openwrt-reset-firewall.sh
```

---

## Demo DNS Poisoning (componente separado)

```bash
# Activar suplantación de rafex.dev → 192.168.1.167
bash scripts/openwrt-dns-spoof-enable.sh

# [audiencia visita http://rafex.dev — ve la página explicativa]

# Desactivar
bash scripts/openwrt-dns-spoof-disable.sh
```

El pod `dns-spoof` es completamente independiente del captive portal.

---

## Notas importantes

### OpenWrt
- `nft` exclusivamente — **no `iptables`** (OpenWrt 25.x usa nftables)
- Servicios con `/etc/init.d/` (OpenWrt no usa `systemctl`)
- Overlay del router: ~840KB
- `timeout 0` sin unidad NO es válido — usar `timeout 0s`
- Matching por subred (`ip saddr 192.168.1.0/24`) porque `iifname "phy0-ap0"` no funciona con bridge `br-lan`

### DietPi (ambas Raspis)
- Priorizar servicios con `/etc/init.d/` + `update-rc.d defaults`
- Si `systemctl` existe y está activo, puede usarse como fallback en algunos scripts
- Builds con `podman build --cgroup-manager=cgroupfs --runtime=runc`
- `podman save | k3s ctr images import -`

### llama.cpp b8849
- Flags válidos: `--model --port --host --ctx-size --threads --parallel`
- **NO usar**: `--n-parallel --n-predict --log-disable` (no existen)
- `ctx-size=4096` es mínimo para evitar "KV cache exhausted"
- El modelo en HuggingFace cache usa symlinks — el script usa `realpath` para resolver
