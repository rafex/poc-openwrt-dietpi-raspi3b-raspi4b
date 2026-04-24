# Referencia de Scripts

Todos los scripts viven en `scripts/`. Los que interactúan con el router se ejecutan **desde RafexPi4B** via SSH. Los scripts de la Raspi 3B se ejecutan **en RafexPi3B**.

---

## Logging de setup

Los scripts modulares de Raspi4B escriben logs completos (`stdout` + `stderr`) por componente:

- Primario: `/var/log/demo-openwrt/<componente>`
- Fallback automático: `/tmp/demo-openwrt/<componente>`

Formato:
- `<script>-YYYYMMDD-HHMMSS.log`

Ejemplo:
```bash
ls -1t /var/log/demo-openwrt/*/setup-*.log 2>/dev/null | head -5
```

---

## setup-openwrt.sh

**Propósito:** Configuración completa del router OpenWrt para el captive portal y las Raspis.  
**Ejecutar en:** RafexPi4B (conecta al router via SSH con `/opt/keys/captive-portal`)  
**Idempotente:** Sí

```bash
bash scripts/setup-openwrt.sh
bash scripts/setup-openwrt.sh --topology legacy
bash scripts/setup-openwrt.sh --topology split_portal --portal-ip 192.168.1.182 --ai-ip 192.168.1.167
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

## Topologías (orquestación y switch)

### scripts/lib/topology.env

Archivo central de configuración de topología (`legacy` o `split_portal`).

Ruta por defecto en repo:
- `scripts/lib/topology.env`

Override recomendado por host:
- `/etc/demo-openwrt/topology.env`

### setup-topology.sh

**Propósito:** ejecutar el flujo completo según topología, sin borrar el despliegue actual.

```bash
sudo bash scripts/setup-topology.sh --topology=legacy
sudo bash scripts/setup-topology.sh --topology=split_portal --portal-host=192.168.1.182
```

Comportamiento:
- `legacy`: OpenWrt + stack completo Raspi4B
- `split_portal`: OpenWrt + Raspi4B (`--skip-portals`) + portal node Raspi3B#2

### topology-switch.sh

**Propósito:** cambiar rápidamente el modo activo en OpenWrt (y opcionalmente persistir en topology env).

```bash
sudo bash scripts/topology-switch.sh legacy
sudo bash scripts/topology-switch.sh split_portal --persist
```

### verify-topology.sh

**Propósito:** validación E2E de endpoints + permanentes en nftables.

```bash
bash scripts/verify-topology.sh --topology=legacy
bash scripts/verify-topology.sh --topology=split_portal
```

---

## Setup modular Raspi4B

### scripts/lib/raspi4b-common.sh

**Propósito:** librería compartida para setup modular en Raspi4B.

Incluye:
- logging estandarizado por componente
- parsing de flags comunes (`--dry-run`, `--only-verify`, `--no-build`, `--force`)
- helpers de apt idempotentes
- validaciones (`need_root`, `ensure_cmd`, `ensure_k3s_ready`)

### setup-raspi4b-mosquitto.sh

**Propósito:** instalar/configurar/verificar solo Mosquitto.

```bash
sudo bash scripts/setup-raspi4b-mosquitto.sh
sudo bash scripts/setup-raspi4b-mosquitto.sh --only-verify
```

Aplica:
- instalación `mosquitto` + `mosquitto-clients`
- `/etc/mosquitto/conf.d/rafexpi.conf`
- restart del servicio
- test publish local en `127.0.0.1:1883`

### setup-raspi4b-llm.sh

**Propósito:** instalar/configurar/verificar solo `llama.cpp` (`llama-server`).

```bash
sudo bash scripts/setup-raspi4b-llm.sh
sudo bash scripts/setup-raspi4b-llm.sh --only-verify
```

Aplica:
- detección binario `llama-server`
- detección modelo `.gguf` (Qwen2.5-0.5B o TinyLlama)
- generación de `/etc/init.d/llama-server`
- watchdog `/etc/cron.d/llama-watchdog`
- health check `http://127.0.0.1:8081/health`

### setup-raspi4b-ai-analyzer.sh

**Propósito:** desplegar solo `ai-analyzer` en k3s.

```bash
sudo bash scripts/setup-raspi4b-ai-analyzer.sh
sudo bash scripts/setup-raspi4b-ai-analyzer.sh --no-build
```

Aplica:
- build/import `localhost/ai-analyzer:latest` (opcional con `--no-build`)
- `kubectl apply` deployment/svc/ingress de analyzer
- `rollout restart` + verificación de endpoints (`/health`, `/dashboard`, `/terminal`, `/rulez`)

### setup-raspi4b-ai-stack.sh

**Propósito:** bundle mínimo de IA en Raspi4B (solo `mosquitto` + `llama.cpp` + `ai-analyzer`).

```bash
sudo bash scripts/setup-raspi4b-ai-stack.sh
sudo bash scripts/setup-raspi4b-ai-stack.sh --no-build
sudo bash scripts/setup-raspi4b-ai-stack.sh --skip-llm
```

Aplica:
- `setup-raspi4b-mosquitto.sh`
- `setup-raspi4b-llm.sh`
- `setup-raspi4b-ai-analyzer.sh`
- verificación final de pantallas clave: `/dashboard` y `/rulez`

No despliega portales.

### setup-raspi4b-portals.sh

**Propósito:** desplegar solo portales (clásico + lentium) en k3s.

```bash
sudo bash scripts/setup-raspi4b-portals.sh
sudo bash scripts/setup-raspi4b-portals.sh --no-build
```

Aplica:
- garantía de llaves SSH del portal
- ejecución de `scripts/raspi-deploy.sh` (con o sin build)
- verificación HTTP de `/portal`, `/accepted`, `/services`, `/people`

### setup-raspi4b-all.sh

**Propósito:** orquestador general de Raspi4B (responsabilidad compuesta).

```bash
sudo bash scripts/setup-raspi4b-all.sh
sudo bash scripts/setup-raspi4b-all.sh --skip-llm
sudo bash scripts/setup-raspi4b-all.sh --skip-portals --skip-analyzer
sudo bash scripts/setup-raspi4b-all.sh --headless-web
```

Orden de ejecución por defecto:
1. `setup-raspi4b-mosquitto.sh`
2. `setup-raspi4b-llm.sh`
3. `setup-raspi4b-ai-analyzer.sh`
4. `setup-raspi4b-portals.sh`

`--headless-web`:
- deja Raspi4B solo para IA (llama.cpp + analyzer + sqlite)
- pensado para topología `split_portal` (portal frontend en Raspi3B#2)

### setup-ai-raspi4b.sh (legacy)

Se mantiene por compatibilidad histórica, pero la recomendación operativa es usar los scripts modulares anteriores.

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

## setup-portal-raspi3b.sh

**Propósito:** instalar y desplegar portal/frontend liviano en Raspi3B#2 con podman + nginx.
**Ejecutar en:** Raspi3B#2 (nodo portal alternativo)

```bash
sudo bash scripts/setup-portal-raspi3b.sh
sudo bash scripts/setup-portal-raspi3b.sh --only-verify
```

Aplica:
- instala `podman` y `curl`
- despliega contenedor `captive-portal-node` (`nginx:alpine`)
- sirve estáticos (`/portal`, `/services`, `/blocked`, `/blocked-art/*`)
- proxy de `/api/*`, `/people`, `/accepted`, `/dashboard`, `/terminal`, `/rulez` al nodo IA (Raspi4B)

## portal-node-deploy.sh

**Propósito:** redeploy del contenedor nginx en portal node.

```bash
sudo bash scripts/portal-node-deploy.sh
```

## portal-node-status.sh

**Propósito:** estado rápido del portal node y health HTTP local.

```bash
bash scripts/portal-node-status.sh
```

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

## llm-status.sh

**Propósito:** diagnóstico detallado del LLM, incluyendo qué modelo está corriendo realmente.  
**Ejecutar en:** RafexPi4B

```bash
bash scripts/llm-status.sh
```

Muestra:
- estado del servicio `/etc/init.d/llama-server`
- PID en ejecución (si existe)
- health HTTP en `:8081`
- modelo en ejecución (leído de `/proc/<pid>/cmdline`)
- modelo configurado en el servicio (fallback)

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
