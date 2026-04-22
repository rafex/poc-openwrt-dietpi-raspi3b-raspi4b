# Referencia de Scripts

Todos los scripts viven en `scripts/`. Los que interactúan con el router se ejecutan **desde RafexPi4B** via SSH. Los scripts de la Raspi 3B se ejecutan **en RafexPi3B**.

---

## Logging de setup

Todos los scripts `setup-*` escriben logs completos (`stdout` + `stderr`) en:

- Primario: `/var/log/demo-openwrt/setup`
- Fallback automático: `/tmp/demo-openwrt/setup`

Formato:
- `<script>-YYYYMMDD-HHMMSS.log`

Ejemplo:
```bash
ls -1t /var/log/demo-openwrt/setup/setup-*.log 2>/dev/null | head -5
```

---

## setup-openwrt.sh

**Propósito:** Configuración completa del router OpenWrt para el captive portal y las Raspis.  
**Ejecutar en:** RafexPi4B (conecta al router via SSH con `/opt/keys/captive-portal`)  
**Idempotente:** Sí

```bash
bash scripts/setup-openwrt.sh
```

| Fase | Qué hace |
|---|---|
| Pre-flight | Verifica espacio en overlay, interfaz `phy0-ap0`, acceso SSH |
| A | Agrega llave pública a `/etc/dropbear/authorized_keys` |
| B | Escribe bloque captive en `/etc/dnsmasq.conf` (sin depender de `/etc/dnsmasq.d/`) |
| B | Configura DHCP: lease `120m`, option `6` (DNS router), option `114` (URL captive) |
| C | Aplica nftables: timeout **120m** para clientes, permanentes (timeout 0s) para admin + RafexPi4B + RafexPi3B |
| **C.1** | **Reservas DHCP UCI permanentes**: RafexPi4B y RafexPi3B con `leasetime=infinite` y su hostname |
| D | Verificación: tabla nftables, admin en el set, dnsmasq resuelve correctamente |

Cambios respecto a la versión anterior:
- **DHCP lease time subido de 30m a 120m** (sincronizado con el timeout del set nftables)
- **RafexPi3B añadida como permanente** en `allowed_clients` (timeout 0s) — nunca necesita pasar por el portal
- **FASE C.1 nueva** — crea reservas DHCP en el router para ambas Raspis con sus hostnames correctos
- **Detección captive mejorada**: `dhcp-option=114,http://192.168.1.167/portal`
- **Dominio fallback manual**: `captive.localhost.com`

> **Regla de oro:** admin `192.168.1.113`, RafexPi4B `192.168.1.167` y RafexPi3B `192.168.1.181`
> siempre tienen `timeout 0s` — nunca se bloquean.

---

## setup-ai-raspi4b.sh

**Propósito:** Instalación del stack IA completo en RafexPi4B.  
**Ejecutar en:** RafexPi4B (como root)  
**Idempotente:** Sí

```bash
sudo bash scripts/setup-ai-raspi4b.sh
sudo bash scripts/setup-ai-raspi4b.sh --no-build   # omitir build de imagen
sudo bash scripts/setup-ai-raspi4b.sh --no-llama   # omitir configuración llama-server
```

| Fase | Qué hace |
|---|---|
| Hostname | `/etc/hostname` = `RafexPi4B`; actualiza `/etc/hosts` y `hostname` en caliente |
| DHCP | SSH al router → reserva UCI `RafexPi4B  d8:3a:dd:4d:4b:ae → 192.168.1.167  infinite` |
| Pre-flight | Verifica k3s corriendo (lo arranca si es necesario), podman disponible |
| A0 | Instala Mosquitto; escribe `/etc/mosquitto/conf.d/rafexpi.conf` (`listen 1883 0.0.0.0, allow_anonymous true`); habilita y reinicia |
| A0 | Instalación apt robusta: no interactiva, timeout, reintentos y recuperación `dpkg` |
| A | Localiza `llama-server` (rutas habituales + `find`); localiza modelo `tinyllama*.gguf`; resuelve symlinks con `realpath` |
| B | Genera `/etc/init.d/llama-server` con `ctx-size=4096 --parallel 1 --threads 4`; habilita; instala `/etc/cron.d/llama-watchdog` (autorelanza cada minuto si se cae); espera hasta 60s que responda en `:8081` |
| C | `podman build --cgroup-manager=cgroupfs --platform linux/arm64 -t localhost/ai-analyzer:latest` |
| D | `podman save localhost/ai-analyzer:latest \| k3s ctr images import -` |
| E | `kubectl apply` ai-analyzer-deployment/svc/ingress; limpia recursos legacy (dashboard separado); `rollout restart` |
| F | `rollout status --timeout=120s`; verifica `/health` y `/dashboard` |

**Variables de entorno configurables** (en el deployment k8s `ai-analyzer-deployment.yaml`):

| Variable | Default | Descripción |
|---|---|---|
| `MQTT_HOST` | 192.168.1.167 | Broker Mosquitto |
| `MQTT_PORT` | 1883 | Puerto MQTT |
| `MQTT_TOPIC` | rafexpi/sensor/batch | Topic MQTT |
| `DB_PATH` | /data/sensor.db | SQLite (hostPath) |
| `LLAMA_URL` | http://192.168.1.167:8081 | llama-server endpoint |
| `N_PREDICT` | 384 | Tokens a generar |
| `PORT` | 5000 | Puerto Flask |
| `LOG_LEVEL` | INFO | Nivel de log |

---

## setup-openwrt-wifi-uplink.sh

**Propósito:** Configurar router con uplink WAN por WiFi 5GHz y AP 2.4GHz abierto para el captive portal.  
**Ejecutar en:** RafexPi4B  
**Idempotente:** Sí

```bash
bash scripts/setup-openwrt-wifi-uplink.sh \
  --uplink-ssid netup \
  --uplink-pass 123 \
  --ap-ssid "INFINITUM MOVIL"
```

Qué hace:
- Detecta radios 2.4/5GHz (`wifi-device`) en OpenWrt
- Crea `network.wwan` (DHCP)
- Configura `wireless.sta_uplink` (5GHz, modo `sta`, red `wwan`)
- Configura `wireless.ap_captive` (2.4GHz, `encryption=none`)
- Agrega `wwan` a la zona `wan` del firewall
- Aplica `network reload`, `wifi reload`, `ifup wwan`, `firewall reload`

---

## setup-sensor-raspi3b.sh

**Propósito:** Instalación del sensor de red en RafexPi3B.  
**Ejecutar en:** RafexPi3B (como root)  
**Idempotente:** Sí

```bash
sudo bash scripts/setup-sensor-raspi3b.sh
sudo bash scripts/setup-sensor-raspi3b.sh --no-ssh    # omitir SSH al router
sudo bash scripts/setup-sensor-raspi3b.sh --dry-run   # solo mostrar qué haría
```

| Fase | Qué hace |
|---|---|
| Hostname | `/etc/hostname` = `RafexPi3B`; actualiza `/etc/hosts` y `hostname` en caliente |
| Pre-flight | Verifica interfaz eth0, detecta IP activa, muestra configuración |
| A | `apt-get install tshark tcpdump python3 python3-pip python3-requests openssh-client iproute2 curl` |
| B | Copia `sensor/sensor.py` → `/opt/sensor/sensor.py`; reinicia si ya estaba corriendo |
| C | `pip3 install requests paho-mqtt` (si no están ya disponibles) |
| D | Genera llave SSH ed25519 en `/opt/keys/sensor`; intenta `ssh-copy-id` al router automáticamente |
| D.1 | SSH al router con la llave del sensor → reserva UCI `RafexPi3B  b8:27:eb:5a:ec:33 → 192.168.1.181  infinite` |
| E | Genera `/etc/init.d/network-sensor` con todas las env vars; `update-rc.d defaults`; inicia el servicio |
| F | Verifica PID, captura de 5s con tshark, conectividad con el analizador |

**Variables de entorno** del servicio (configurables antes de ejecutar):

| Variable | Default | Descripción |
|---|---|---|
| `SENSOR_IFACE` | eth0 | Interfaz de captura |
| `MQTT_HOST` | 192.168.1.167 | Broker Mosquitto |
| `MQTT_PORT` | 1883 | Puerto MQTT |
| `MQTT_TOPIC` | rafexpi/sensor/batch | Topic |
| `ANALYZER_URL` | http://192.168.1.167/api/ingest | Fallback HTTP |
| `BATCH_INTERVAL` | 30 | Segundos entre batches |
| `ROUTER_IP` | 192.168.1.1 | Router para SSH opcional |
| `USE_ROUTER_SSH` | true | Usar SSH al router para enriquecer datos |

---

## sensor-status.sh

**Propósito:** Diagnóstico completo del sistema sensor + IA.  
**Ejecutar en:** RafexPi4B

```bash
bash scripts/sensor-status.sh            # estado general
bash scripts/sensor-status.sh --test     # 8 tests funcionales
bash scripts/sensor-status.sh --follow   # logs en vivo del analizador
```

Qué muestra:
- Estado de pods k3s (`ai-analyzer`, `captive-portal`)
- Estado de `llama-server` (init.d) y respuesta en `:8081/health`
- Estado de `mosquitto` (init.d)
- `/health` y `/api/stats` del analizador
- URLs de los dashboards
- (Opcional) SSH a RafexPi3B para verificar el proceso sensor

Tests funcionales (`--test`):

| Test | Qué verifica |
|---|---|
| 1 | `GET /health` → `{"status":"ok"}` |
| 2 | `GET /api/stats` → JSON con métricas |
| 3 | `GET /api/history` → array de análisis |
| 4 | `GET /api/queue` → estado de la cola |
| 5 | `POST /api/ingest` con batch de muestra → 202 |
| 6 | llama-server responde en `:8081` |
| 7 | Mosquitto acepta publicaciones en `:1883` |
| 8 | `GET /dashboard` → HTML (200) |

---

## llm-control.sh

**Propósito:** Encender/apagar el LLM local para reducir uso de CPU cuando no se está usando.  
**Ejecutar en:** RafexPi4B

```bash
bash scripts/llm-control.sh status
bash scripts/llm-control.sh off
bash scripts/llm-control.sh on
bash scripts/llm-control.sh restart
```

Comportamiento:
- `off`: detiene `/etc/init.d/llama-server` y desactiva watchdog (`/etc/cron.d/llama-watchdog`)
- `on`: arranca `llama-server` y reactiva watchdog
- `status`: muestra PID, health HTTP en `:8081` y estado watchdog

---

## openwrt-allow-client.sh

**Propósito:** Autorizar manualmente una IP en el captive portal.  
**Ejecutar en:** RafexPi4B

```bash
bash scripts/openwrt-allow-client.sh 192.168.1.55
bash scripts/openwrt-allow-client.sh 192.168.1.55 --permanent  # timeout 0s
```

---

## openwrt-block-client.sh

**Propósito:** Bloquear una IP (devuelve al portal).  
**Ejecutar en:** RafexPi4B

```bash
bash scripts/openwrt-block-client.sh 192.168.1.55
```

> Nunca bloquea `ADMIN_IP`, `RASPI4B_IP` ni `RASPI3B_IP`. Protección en `common.sh`.

---

## openwrt-list-clients.sh

**Propósito:** Estado actual de clientes en el router.  
**Ejecutar en:** RafexPi4B

```bash
bash scripts/openwrt-list-clients.sh
```

Muestra:
- IPs en el set `allowed_clients` (con timeouts)
- Leases DHCP activos (`/tmp/dhcp.leases`)
- Conexiones activas al puerto 80 (conntrack)
- Reglas nftables activas

---

## openwrt-reserve-raspi.sh

**Propósito:** Reserva DHCP manual para una Raspi en el router (complemento — `setup-openwrt.sh` ya lo hace automáticamente para ambas Raspis).  
**Ejecutar en:** RafexPi4B o directamente en la Raspi a reservar  
**Idempotente:** Sí

```bash
# Modo recomendado: ejecutar desde la Pi que se quiere reservar
bash scripts/openwrt-reserve-raspi.sh --auto              # detecta MAC local, usa IP por defecto
bash scripts/openwrt-reserve-raspi.sh --auto 192.168.1.181

# MAC manual
bash scripts/openwrt-reserve-raspi.sh --mac b8:27:eb:5a:ec:33 --ip 192.168.1.181
```

> **Nota:** `setup-openwrt.sh` ya configura las reservas de RafexPi4B y RafexPi3B automáticamente en la FASE C.1. Este script sirve para reservas adicionales o correcciones manuales.

---

## openwrt-flush-clients.sh

**Propósito:** Resetear clientes autorizados — todos vuelven al portal.  
**Ejecutar en:** RafexPi4B

```bash
bash scripts/openwrt-flush-clients.sh           # pide confirmación
bash scripts/openwrt-flush-clients.sh --force   # sin confirmación
```

- Vacía `allowed_clients` preservando admin, RafexPi4B y RafexPi3B (permanentes)
- `conntrack -F` — fuerza reconexión de sesiones ESTABLISHED

| | `flush-clients` | `reset-firewall` |
|---|---|---|
| Elimina clientes temporales | ✅ | ✅ |
| Mantiene nftables activo | ✅ | ❌ |
| Portal sigue funcionando | ✅ | ❌ |
| Uso típico | Reset entre demos | Emergencia total |

---

## openwrt-dns-spoof-enable.sh

**Propósito:** Activar demo de DNS poisoning — suplantar dominios.  
**Ejecutar en:** RafexPi4B  
**Idempotente:** Sí

```bash
bash scripts/openwrt-dns-spoof-enable.sh                   # activa rafex.dev
bash scripts/openwrt-dns-spoof-enable.sh --domain otro.com
```

Además de dnsmasq, aplica los manifiestos k8s del pod `dns-spoof` (deployment + svc + ingress).
El pod dns-spoof es **completamente separado** del captive-portal.

---

## openwrt-dns-spoof-disable.sh

**Propósito:** Desactivar la demo de DNS poisoning.  
**Ejecutar en:** RafexPi4B

```bash
bash scripts/openwrt-dns-spoof-disable.sh
```

Elimina entradas dnsmasq y los recursos k8s del pod dns-spoof.

---

## openwrt-reset-firewall.sh

**Propósito:** Emergencia — desactiva todo el captive portal.  
**Ejecutar en:** RafexPi4B

```bash
bash scripts/openwrt-reset-firewall.sh
```

Elimina: tabla `ip captive`, `/etc/nftables.d/captive-portal.nft`, `/etc/dnsmasq.d/captive-portal.conf`, bloque captive en `/etc/dnsmasq.conf`, flush conntrack. No toca la configuración base de `fw4`.

---

## lib/common.sh

Librería compartida cargada con `. scripts/lib/common.sh`.

### Constantes principales

| Constante | Valor | Descripción |
|---|---|---|
| `ROUTER_IP` | 192.168.1.1 | Router OpenWrt |
| `PORTAL_IP` | 192.168.1.167 | = RASPI4B_IP |
| `ADMIN_IP` | 192.168.1.113 | Laptop admin — nunca bloquear |
| `RASPI4B_IP` | 192.168.1.167 | RafexPi4B |
| `RASPI4B_MAC` | d8:3a:dd:4d:4b:ae | MAC RafexPi4B |
| `RASPI4B_HOSTNAME` | RafexPi4B | Hostname RafexPi4B |
| `RASPI3B_IP` | 192.168.1.181 | RafexPi3B |
| `RASPI3B_MAC` | b8:27:eb:5a:ec:33 | MAC RafexPi3B |
| `RASPI3B_HOSTNAME` | RafexPi3B | Hostname RafexPi3B |
| `PORTAL_TIMEOUT` | 120m | Timeout nftables clientes WiFi |

### Funciones

| Función | Descripción |
|---|---|
| `log_info/ok/warn/error/die` | Logging estilo `[INFO] [OK] [WARN]` |
| `validate_ip <ip>` | Valida formato A.B.C.D (POSIX sh puro) |
| `router_ssh <cmd>` | SSH al router con `/opt/keys/captive-portal` |
| `check_ssh_key` | Verifica que la llave existe |
| `test_router_ssh` | Prueba conectividad SSH al router |
| `router_table_exists` | Verifica si la tabla `ip captive` existe |
| `router_set_exists` | Verifica si el set `allowed_clients` existe |
| `router_ip_in_set <ip>` | Verifica si una IP está en el set |
| `router_add_ip <ip>` | Agrega IP al set (timeout 0s para admin/RafexPi4B/RafexPi3B; PORTAL_TIMEOUT para el resto) |
| `router_del_ip <ip>` | Elimina IP del set |
