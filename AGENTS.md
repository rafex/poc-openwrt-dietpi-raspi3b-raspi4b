
# AGENTS.md — PoC Captive Portal + IA Local en Red WiFi

## Contexto del proyecto

PoC educativa de seguridad en redes públicas que combina:
- Captive portal en Raspberry Pi 4B (RafexPi4B) con k3s
- Sensor de red en Raspberry Pi 3B (RafexPi3B) capturando tráfico con tshark
- LLM local TinyLlama 1.1B con llama.cpp — análisis de seguridad en batches
- Router OpenWrt como gateway WiFi con nftables + dnsmasq
- MQTT (Mosquitto) como cola de mensajes entre el sensor y el analizador IA
- SQLite como persistencia de batches y análisis

## Hito 1 (completado)

Estado al **22 de abril de 2026**:
- Captive portal funcional extremo a extremo (registro cliente/invitado y autorización nftables).
- Stack IA funcional (sensor → MQTT → analyzer → TinyLlama → dashboard).
- Detección captive mejorada:
  - dnsmasq con dominios de detección en `/etc/dnsmasq.conf`
  - DHCP option `114` (`http://192.168.1.167/portal`)
  - dominio fallback `captive.localhost.com` y subdominio `people.localhost.com`
- Scripts `setup-*` con logging persistente por componente en `/var/log/demo-openwrt/<componente>` (fallback `/tmp/demo-openwrt/<componente>`).
- Script operativo para apagar/encender LLM (`scripts/llm-control.sh`) y reducir CPU.

## Arquitectura

```
Internet
    ↓
Router OpenWrt (192.168.1.1)   ath79/mips_24kc
    │  nftables: tabla ip captive
    │    • allowed_clients timeout 120m (clientes WiFi)
    │    • permanentes (timeout 0s): admin, RafexPi4B, RafexPi3B
    │  dnsmasq: dominios captive portal → 192.168.1.167
    │           captive.localhost.com → 192.168.1.167
    │           DHCP option 114 → http://192.168.1.167/portal
    │           lease 120m
    │  DHCP reservas: RafexPi4B=192.168.1.167, RafexPi3B=192.168.1.181
    │
    ├── WAN: phy1-sta0 → WiFi upstream (5 GHz)
    └── AP:  phy0-ap0  → WiFi "INFINITUM MOVIL" (2.4 GHz)
                │
                ▼ clientes WiFi (192.168.1.x)
                │
    ┌───────────────────────────────────────────────┐
    │  RafexPi4B — 192.168.1.167  (Raspberry Pi 4B) │
    │  DietPi Debian trixie arm64 + k3s v1.34.6     │
    │                                                │
    │  Servicios init.d:                             │
    │    • mosquitto :1883 (MQTT broker)             │
    │    • llama-server :8081 (TinyLlama Q4_K_M)    │
    │      ctx-size=4096, --parallel 1               │
    │                                                │
    │  k3s Pods:                                     │
    │    ├── captive-portal-lentium (2/2)            │
    │    │     nginx:alpine :80 + captive-backend-lentium │
    │    │     GET /portal /services /blocked /people │
    │    ├── ai-analyzer (1/1)                       │
    │    │     python:3.13-alpine3.23 :5000          │
    │    │     SQLite: /data/sensor.db               │
    │    │     MQTT subscriber: rafexpi/sensor/batch  │
    │    │     Worker: 1 análisis a la vez           │
    │    │     GET /dashboard  — UI visual           │
    │    │     GET /terminal   — log en vivo (SSE)   │
    │    │     GET /rulez      — reglas/prompts IA   │
    │    │     GET /api/history /api/stats /api/queue │
    │    │     POST /api/ingest (HTTP fallback)       │
    │    └── dns-spoof (nginx:alpine — demo separada) │
    │                                                │
    │  /opt/keys/captive-portal  (SSH al router)     │
    │  /opt/analyzer/data/sensor.db  (hostPath)      │
    └───────────────────────────────────────────────┘
                │  MQTT publish (rafexpi/sensor/batch)
                │  HTTP fallback POST /api/ingest
                ▼
    ┌───────────────────────────────────────────────┐
    │  RafexPi3B — 192.168.1.181  (Raspberry Pi 3B) │
    │  DietPi + tshark + Python 3                   │
    │                                                │
    │  Servicio: /etc/init.d/network-sensor          │
    │    tshark -i eth0 (promiscuo, 18 campos)       │
    │    TrafficAggregator: stats por IP, escaneos   │
    │    SSH opcional al router: conntrack + leases  │
    │    Publica batch cada 30s vía MQTT             │
    │    Fallback: HTTP POST al analizador           │
    │  /opt/keys/sensor  (SSH al router OpenWrt)     │
    └───────────────────────────────────────────────┘

    Laptop admin (192.168.1.113) — NUNCA bloquear
```

## Dispositivos

| Dispositivo | Hostname | IP | MAC | OS | Acceso |
|---|---|---|---|---|---|
| Router OpenWrt | — | 192.168.1.1 | — | OpenWrt 25.12.2 (ath79) | SSH root, Dropbear |
| Raspberry Pi 4B | RafexPi4B | 192.168.1.167 | d8:3a:dd:4d:4b:ae | DietPi Debian trixie arm64 | SSH, k3s v1.34.6 |
| Raspberry Pi 3B | RafexPi3B | 192.168.1.181 | b8:27:eb:5a:ec:33 | DietPi Debian arm | SSH, sensor init.d |
| Laptop admin | — | 192.168.1.113 | — | — | **NUNCA bloquear** |

## Repositorio

```
poc-openwrt-dietpi-raspi3b-raspi4b/
├── backend/
│   ├── captive-portal/
│   │   ├── backend.py           # HTTP Python :8080 — autoriza clientes via SSH+nft
│   │   └── Dockerfile           # python:3.13-alpine
│   ├── captive-portal-lentium/
│   │   ├── backend.py           # Portal Lentium + /services + /people + /blocked
│   │   ├── portal.html
│   │   ├── services.html
│   │   ├── blocked.html
│   │   ├── blocked-art/art-*.svg
│   │   └── Dockerfile           # python:3.13-alpine3.23
│   └── ai-analyzer/
│       ├── analyzer.py          # MQTT subscriber + worker + Flask API + SSE
│       ├── dashboard.html       # UI visual (servido desde Python)
│       ├── terminal.html        # Terminal SSE en vivo
│       ├── rulez.html           # editor de reglas/prompts (SQLite)
│       ├── router_mcp.py        # abstracción de acciones al router OpenWrt
│       ├── requirements.txt     # requests, paho-mqtt
│       └── Dockerfile           # python:3.13-alpine3.23
├── sensor/
│   ├── sensor.py                # tshark capture + TrafficAggregator + MQTT/HTTP
│   ├── requirements.txt         # requests, paho-mqtt
│   └── sensor.service           # plantilla init.d
├── k8s/
│   ├── captive-portal-configmap.yaml
│   ├── captive-portal-deployment.yaml
│   ├── captive-portal-svc.yaml
│   ├── captive-portal-ingress.yaml
│   ├── traefik-helmchartconfig.yaml
│   ├── cleanup-legacy.yaml
│   ├── ai-analyzer-deployment.yaml  # env: MQTT_HOST/PORT/TOPIC, DB_PATH, LLAMA_URL
│   ├── ai-analyzer-svc.yaml
│   ├── ai-analyzer-ingress.yaml     # /dashboard, /terminal, /api/*
│   ├── dns-spoof-deployment.yaml    # nginx:alpine — demo separada
│   ├── dns-spoof-svc.yaml
│   ├── dns-spoof-configmap.yaml
│   └── dns-spoof-ingress.yaml       # Host: rafex.dev, www.rafex.dev
├── scripts/
│   ├── lib/common.sh                # constantes, SSH helpers, router_add_ip
│   ├── lib/raspi4b-common.sh        # logging/flags/helpers setup modular
│   ├── lib/topology.env             # topología base (legacy/split_portal)
│   ├── lib/topology-common.sh       # helper bash para cargar topología
│   ├── setup-openwrt.sh             # configura router completo
│   ├── setup-openwrt-wifi-uplink.sh # WAN por WiFi 5GHz + AP 2.4 abierto
│   ├── setup-ai-raspi4b.sh          # legacy (mantenido por compatibilidad)
│   ├── setup-raspi4b-mosquitto.sh   # instala/configura solo Mosquitto
│   ├── setup-raspi4b-llm.sh         # instala/configura solo llama.cpp
│   ├── setup-raspi4b-ai-analyzer.sh # despliega solo ai-analyzer en k3s
│   ├── setup-raspi4b-portals.sh     # despliega solo portales en k3s
│   ├── setup-raspi4b-all.sh         # orquestador general Raspi4B
│   ├── setup-sensor-raspi3b.sh      # instala sensor en Raspi 3B
│   ├── setup-portal-raspi3b.sh      # instala portal node en Raspi3B #2
│   ├── portal-node-deploy.sh        # redeploy nginx portal node
│   ├── portal-node-status.sh        # status/health portal node
│   ├── setup-topology.sh            # orquesta despliegue por topología
│   ├── topology-switch.sh           # cambia legacy <-> split_portal
│   ├── verify-topology.sh           # validación E2E por topología
│   ├── llm-control.sh               # on/off/restart/status de llama-server
│   ├── raspi-deploy.sh              # despliegue k8s de portales + ingress
│   ├── portal-switch.sh             # alterna portal activo (lentium/clásico)
│   ├── sensor-status.sh             # diagnóstico completo del sistema
│   ├── openwrt-allow-client.sh
│   ├── openwrt-block-client.sh
│   ├── openwrt-kick-client.sh
│   ├── openwrt-list-clients.sh
│   ├── openwrt-flush-clients.sh
│   ├── openwrt-reserve-raspi.sh     # reserva DHCP manual (complemento)
│   ├── openwrt-dns-spoof-enable.sh
│   ├── openwrt-dns-spoof-disable.sh
│   └── openwrt-reset-firewall.sh
├── docs/
│   ├── arquitectura.md
│   ├── setup.md
│   ├── scripts.md
│   └── troubleshooting.md
├── output/                          # reportes raspi-k8s-status.sh
├── README.md
└── TODO.md
```

## Estado actual

### Router OpenWrt ✅
- [x] nftables: tabla `ip captive` con reglas por subred (`ip saddr 192.168.1.0/24`)
- [x] `allowed_clients` timeout **120m** (subido de 30m)
- [x] Permanentes (timeout 0s): admin `192.168.1.113`, RafexPi4B `192.168.1.167`, RafexPi3B `192.168.1.181`
- [x] dnsmasq: dominios de detección de captive portal → 192.168.1.167
- [x] Dominio fallback: `captive.localhost.com` → 192.168.1.167
- [x] DHCP option `114`: `http://192.168.1.167/portal`
- [x] DHCP option `6`: DNS del router (`192.168.1.1`) para clientes LAN
- [x] DHCP lease time: **120m** (UCI `dhcp.lan.leasetime=120m`)
- [x] Reservas DHCP permanentes:
  - RafexPi4B — `d8:3a:dd:4d:4b:ae` → 192.168.1.167 (leasetime=infinite)
  - RafexPi3B — `b8:27:eb:5a:ec:33` → 192.168.1.181 (leasetime=infinite)
- [x] Reglas persistentes en `/etc/nftables.d/captive-portal.nft`

### RafexPi4B / k3s ✅
- [x] k3s v1.34.6+k3s1 corriendo
- [x] Traefik 3.6.10 expone el portal en :80 (`externalTrafficPolicy: Local`)
- [x] Pod `captive-portal-lentium` 2/2 Running — nginx sidecar + backend Python
- [x] Mosquitto MQTT broker corriendo en :1883
- [x] llama-server (TinyLlama Q4_K_M) en :8081 — ctx-size=4096, --parallel 1
- [x] Watchdog `/etc/cron.d/llama-watchdog` — relanza llama-server automáticamente si se cae
- [x] `scripts/llm-control.sh` para apagar/encender LLM y watchdog según uso
- [x] Pod ai-analyzer corriendo — Flask + MQTT subscriber + worker + SQLite
- [x] UIs IA: `/dashboard` (visual), `/terminal` (SSE), `/rulez` (reglas/prompts)
- [x] UIs portal Lentium: `/portal`, `/services`, `/people`, `/blocked`
- [x] HTML servido desde la imagen Docker (no ConfigMap — evita errores de parseo YAML)
- [x] hostPath `/opt/analyzer/data/sensor.db` — persiste entre reinicios de pod
- [x] hostPath `/opt/captive-portal/lentium-data/lentium.db` — persiste registros del portal
- [x] Pod dns-spoof (nginx:alpine) — demo DNS poisoning separada
- [x] Hostname configurado: RafexPi4B
- [x] Setup modular disponible: `setup-raspi4b-{mosquitto,llm,ai-analyzer,portals,all}.sh`

### RafexPi3B / Sensor ✅
- [x] tshark capturando en eth0 (modo promiscuo, 18 campos tab-separated)
- [x] `TrafficAggregator`: stats por IP, detección de escaneos de puertos
- [x] paho-mqtt: publica batches a `rafexpi/sensor/batch` cada 30s (QoS=1)
- [x] HTTP fallback a `http://192.168.1.167/api/ingest` si MQTT falla
- [x] Llave SSH `/opt/keys/sensor` para consultas opcionales al router (conntrack + leases)
- [x] Servicio init.d `/etc/init.d/network-sensor` habilitado en arranque
- [x] Hostname configurado: RafexPi3B
- [x] Reserva DHCP configurada automáticamente al correr `setup-sensor-raspi3b.sh`

### Stack IA ✅
- [x] TinyLlama 1.1B-Chat Q4_K_M vía llama.cpp b8849 (formato ChatML)
- [x] Prompt compacto ~350 tokens en español — análisis de seguridad en 3 puntos + riesgo BAJO/MEDIO/ALTO
- [x] Worker thread procesa 1 batch a la vez (no hay saturación de KV cache)
- [x] Batches persistidos en SQLite (status: pending → processing → done/error)
- [x] Reencola batches huérfanos al arrancar el pod

### Topologías soportadas ✅
- [x] `legacy`: OpenWrt -> Sensor(3B#1) -> AI+k3s+Portal(4B)
- [x] `split_portal`: OpenWrt -> Portal(3B#2) + Sensor(3B#1) -> AI+k3s(4B)
- [x] Archivo central: `scripts/lib/topology.env` (override en `/etc/demo-openwrt/topology.env`)
- [x] Scripts: `setup-topology.sh`, `topology-switch.sh`, `verify-topology.sh`

## Inventario de vistas HTML (para agentes)

- HTML físicos en repo: **6**
- Vistas HTML dinámicas (sin archivo `.html`): **2**
- Total vistas HTML accesibles: **8**

| Ruta | Fuente | Propósito |
|---|---|---|
| `/portal` (también `/`) | `backend/captive-portal-lentium/portal.html` | Registro cliente/invitado y autorización en router |
| `/services` | `backend/captive-portal-lentium/services.html` | Control operativo de servicios de la PoC |
| `/blocked` | `backend/captive-portal-lentium/blocked.html` | Pantalla “sitio bloqueado por IA” |
| `/blocked-art/*` | `backend/captive-portal-lentium/blocked-art/art-01..10.svg` | Arte aleatorio para bloqueo |
| `/people` | HTML generado por `backend/captive-portal-lentium/backend.py` | Dashboard de personas registradas/conectadas |
| `/accepted` | HTML inline en `backend/captive-portal-lentium/backend.py` | Confirmación de acceso (compatibilidad) |
| `/dashboard` | `backend/ai-analyzer/dashboard.html` | Dashboard IA de tráfico/riesgo |
| `/terminal` | `backend/ai-analyzer/terminal.html` | Log en vivo por SSE |
| `/rulez` | `backend/ai-analyzer/rulez.html` | Editor de reglas/prompts IA en SQLite |

Dominios relevantes:
- `captive.localhost.com` → abrir portal (`/portal`)
- `people.localhost.com` → dashboard de personas (`/people`)

## Constantes globales (lib/common.sh)

```sh
ROUTER_IP="192.168.1.1"
PORTAL_IP="192.168.1.167"        # en legacy=RASPI4B_IP; en split_portal=PORTAL_NODE_IP
ADMIN_IP="192.168.1.113"
LAN_SUBNET="192.168.1.0/24"
RASPI4B_IP="192.168.1.167"
RASPI4B_MAC="d8:3a:dd:4d:4b:ae"
RASPI4B_HOSTNAME="RafexPi4B"
RASPI3B_IP="192.168.1.181"
RASPI3B_MAC="b8:27:eb:5a:ec:33"
RASPI3B_HOSTNAME="RafexPi3B"
PORTAL_NODE_IP="192.168.1.182"   # Raspi3B #2 opcional (topología split_portal)
TOPOLOGY="legacy|split_portal"
PORTAL_TIMEOUT="120m"            # timeout del set nftables = leasetime DHCP clientes
```

## Llaves SSH

| Llave | Ubicación | Propósito |
|---|---|---|
| `captive-portal` | `/opt/keys/captive-portal` (RafexPi4B) | Scripts OpenWrt → router |
| `captive-portal.pub` | `/opt/keys/captive-portal.pub` | Registrada en router (Dropbear) |
| `sensor` | `/opt/keys/sensor` (RafexPi3B) | Sensor → router (conntrack/leases opcionales) |
| `sensor.pub` | `/opt/keys/sensor.pub` | Registrada en router (Dropbear) |

```
# captive-portal (RafexPi4B)
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL238prLPDMktu1deXGAFjQ5npVX1bQm+9Jugeiv9Uep captive-portal@rafexpi

# sensor (RafexPi3B) — generada por setup-sensor-raspi3b.sh
ssh-ed25519 AAAAC3... sensor@raspi3b
```

## Notas importantes para el agente

### nftables — reglas por subred, no por interfaz
- **Usar `ip saddr 192.168.1.0/24`** — NO `iifname "phy0-ap0"`
- Razón: clientes WiFi pasan por `br-lan`; el hook forward ve `br-lan`, no `phy0-ap0`
- Tabla: `ip captive` — set: `allowed_clients`
- `priority filter - 1` en `forward_captive` — evalúa antes que fw4
- Permanentes (timeout 0s): admin, RASPI4B_IP (AI), RASPI3B_IP (sensor), PORTAL_IP (según topología)
- Clientes WiFi: `timeout 120m` (2 horas desde la última vez que pasaron por el portal)
- Al recargar: `nft delete table ip captive` ANTES del dry-run (`nft -c -f`)
- Limpiar conntrack al activar reglas: `conntrack -F`
- `timeout 0` sin unidad NO válido — usar `timeout 0s`
- `router_add_ip` en `common.sh` aplica `timeout 0s` automáticamente para admin, portal y ambas Raspis

### MQTT + SQLite — arquitectura de cola
- Broker Mosquitto en RafexPi4B :1883, `allow_anonymous true` (demo)
- Topic: `rafexpi/sensor/batch` (QoS=1)
- Sensor publica JSON con stats de 30s; analyzer suscribe y persiste en SQLite
- Worker thread único: evita race conditions y saturación del LLM
- SQLite tablas: `batches` (pending/processing/done/error) + `analyses`
- Al iniciar el pod: reencola batches con status pending/processing

### llama.cpp — configuración crítica
- Versión b8849 — flags válidos: `--model`, `--port`, `--host`, `--ctx-size`, `--threads`, `--parallel`
- **NO usar**: `--n-parallel`, `--n-predict`, `--log-disable` (no existen en esta versión)
- `--parallel 1` — 1 slot en paralelo; toda la KV cache disponible para ese slot
- `ctx-size=4096` — necesario: prompt ~350 tokens + n_predict=384 = ~734 tokens por análisis
- Con ctx-size=2048 y n_parallel=4 auto → solo 512 tokens/slot → crash "KV cache exhausted"
- Formato de prompt: ChatML (`<|system|>`, `<|user|>`, `<|assistant|>`)
- Endpoint: `POST http://192.168.1.167:8081/completion`

### Imagen Docker ai-analyzer
- Base: `python:3.13-alpine3.23`
- Regla de repo: cualquier imagen Python debe usar `python:3.13-alpine3.23`
- Build: `podman build --cgroup-manager=cgroupfs --platform linux/arm64`
- Import: `podman save | k3s ctr images import -`
- HTML (dashboard.html, terminal.html, rulez.html) copiados dentro de la imagen — NO en ConfigMap
  - ConfigMap con HTML/JS falla al hacer `kubectl apply` por literales JS (`{}`, template strings)

### Traefik — IP real del cliente
- `externalTrafficPolicy: Local` — obligatorio para preservar IP real del cliente WiFi
- Sin esto: kube-proxy SNAT → backends ven `10.42.0.1` en vez de `192.168.1.X`
- `forwardedHeaders.insecure` + Traefik propaga `X-Forwarded-For`

### nginx + backend sidecar (captive-portal)
- Mismo pod → comparten red del pod
- `proxy_pass http://127.0.0.1:8080` — NO `localhost` (resuelve a `::1` en Alpine)
- `set_real_ip_from 10.42.0.0/16` + `real_ip_header X-Forwarded-For` → `$remote_addr` = IP real

### OpenWrt
- **No usar `systemctl`** — usar `/etc/init.d/`
- Overlay: ~840KB — no instalar paquetes innecesarios
- Dropbear: opciones SSH básicas únicamente
- Para captive portal usar bloque en `/etc/dnsmasq.conf` (ruta confiable en OpenWrt)
- Configurar por UCI en `dhcp.lan.dhcp_option`:
  - `6,192.168.1.1` (DNS del router)
  - `114,http://192.168.1.167/portal` (RFC 7710/8910)
- Mantener dominio fallback `captive.localhost.com` apuntando al portal

### DietPi (ambas Raspis)
- **No usar `systemctl` directamente** — DietPi no usa systemd como PID 1
- Servicios con `/etc/init.d/` y `update-rc.d defaults`
- Verificar procesos con `ps aux` o PID files

### Logs de setup
- Los setups escriben logs por componente en `/var/log/demo-openwrt/<componente>`.
- Si no hay permisos, fallback automático a `/tmp/demo-openwrt/<componente>`.

### Regla de oro
**`192.168.1.113` (admin) y `192.168.1.181` (RafexPi3B) NUNCA pierden acceso a internet.**
`router_add_ip` en `common.sh` aplica `timeout 0s` automáticamente para admin, portal y ambas Raspis.
