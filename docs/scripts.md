# Referencia de Scripts

Todos los scripts viven en `scripts/`. Usan la librería `scripts/lib/raspi4b-common.sh` para logging, flags comunes y helpers de apt.

---

## Logging de setup

Los scripts modulares escriben logs completos (`stdout` + `stderr`) por componente:

- Primario: `/var/log/demo-openwrt/<componente>`
- Fallback automático: `/tmp/demo-openwrt/<componente>`
- Formato: `<script>-YYYYMMDD-HHMMSS.log`

```bash
ls -1t /var/log/demo-openwrt/*/setup-*.log 2>/dev/null | head -5
```

---

## Flags comunes (todos los scripts modulares)

| Flag | Descripción |
|---|---|
| `--dry-run` | Muestra qué haría sin ejecutar nada |
| `--only-verify` | Solo verifica estado, no instala |
| `--force` | Fuerza reinstalación aunque ya esté listo |
| `--no-build` | Omite build de imágenes podman (aplica a frontend/portales) |

---

## setup-raspi4b-deps.sh ⬅ NUEVO

**Propósito:** instalar todas las dependencias del SO (Debian/DietPi Bookworm arm64) para el stack completo de Raspi4B.  
**Ejecutar en:** RafexPi4B (como root)  
**Idempotente:** Sí — comprueba antes de instalar

```bash
sudo bash scripts/setup-raspi4b-deps.sh
sudo bash scripts/setup-raspi4b-deps.sh --skip-node        # si no se compilará frontend en la Pi
sudo bash scripts/setup-raspi4b-deps.sh --skip-mosquitto   # si ya está instalado
sudo bash scripts/setup-raspi4b-deps.sh --dry-run
```

Qué instala:

| Grupo | Detalle |
|---|---|
| Base | `curl wget git ca-certificates gnupg jq python3 openssh-client cron iproute2 net-tools dnsutils less htop` |
| Contenedores | `podman uidmap slirp4netns fuse-overlayfs` |
| MQTT | `mosquitto mosquitto-clients` |
| Secretos | `age` (apt) + `sops 3.9.1` (binario arm64 de GitHub) |
| Frontend | Node.js 20 LTS via NodeSource (binario `node` + `npm`) |

---

## setup-raspi4b-all.sh

**Propósito:** orquestador general de Raspi4B — ejecuta todos los componentes en orden.  
**Ejecutar en:** RafexPi4B (como root)

Orden de ejecución:
1. `setup-raspi4b-deps.sh` — dependencias del SO
2. `setup-raspi4b-mosquitto.sh` — broker MQTT
3. `setup-raspi4b-llm.sh` — llama.cpp server
4. `setup-raspi4b-ai-analyzer-java.sh` — binario GraalVM nativo
5. `setup-raspi4b-frontend.sh` — Vite dist + nginx (podman)
6. `setup-raspi4b-portals.sh` — portales cautivos

```bash
sudo bash scripts/setup-raspi4b-all.sh
sudo bash scripts/setup-raspi4b-all.sh --skip-deps
sudo bash scripts/setup-raspi4b-all.sh --skip-llm
sudo bash scripts/setup-raspi4b-all.sh --skip-portals
sudo bash scripts/setup-raspi4b-all.sh --skip-frontend
sudo bash scripts/setup-raspi4b-all.sh --headless-web   # solo IA (sin frontend ni portales)
sudo bash scripts/setup-raspi4b-all.sh --dry-run
```

---

## setup-raspi4b-mosquitto.sh

**Propósito:** instalar/configurar/verificar solo Mosquitto MQTT.  
**Idempotente:** Sí

```bash
sudo bash scripts/setup-raspi4b-mosquitto.sh
sudo bash scripts/setup-raspi4b-mosquitto.sh --only-verify
```

- Instala `mosquitto` + `mosquitto-clients`
- Escribe `/etc/mosquitto/conf.d/rafexpi.conf` (listener `1883 0.0.0.0`, anónimo)
- Reinicia el servicio (systemd o init.d)
- Verifica publicación en `127.0.0.1:1883`

---

## setup-raspi4b-llm.sh

**Propósito:** instalar/configurar/verificar solo llama.cpp (`llama-server`).  
**Idempotente:** Sí

```bash
sudo bash scripts/setup-raspi4b-llm.sh
sudo bash scripts/setup-raspi4b-llm.sh --model-path=/opt/models/qwen2.5-0.5b-instruct-q4_k_m.gguf
sudo bash scripts/setup-raspi4b-llm.sh --only-verify
```

- Detecta el binario `llama-server` en rutas estándar
- Detecta el modelo `.gguf` (Qwen2.5-0.5B o TinyLlama)
- Genera `/etc/init.d/llama-server`
- Instala watchdog cron `/etc/cron.d/llama-watchdog`
- Health check: `http://127.0.0.1:8081/health`

**Prerequisito:** modelo descargado previamente en `/opt/models/`.

---

## setup-raspi4b-ai-analyzer-java.sh

**Propósito:** descargar e instalar el binario GraalVM nativo de `ai-analyzer` + `.so` Rust.  
**Idempotente:** Sí

```bash
sudo bash scripts/setup-raspi4b-ai-analyzer-java.sh
sudo bash scripts/setup-raspi4b-ai-analyzer-java.sh --release=v20260428-abc1234
sudo bash scripts/setup-raspi4b-ai-analyzer-java.sh --only-verify
sudo bash scripts/setup-raspi4b-ai-analyzer-java.sh --dry-run
```

- Instala `age` + `sops` si no están
- Descifra `secrets/raspi4b.yaml` → `GROQ_API_KEY` en memoria (sin escribir a disco)
- Descarga de GitHub Releases: `ai-analyzer-linux-arm64` + `libanalyzer_db-linux-arm64.so`
- Instala en `/opt/ai-analyzer/{bin,lib,html}/`
- Escribe `/etc/ai-analyzer.env` (chmod 600)
- Instala y arranca `systemd ai-analyzer.service` (`Type=simple`, `MemoryMax=300M`)
- Verifica `/health` + endpoints principales

**Sin JVM en la Pi** — binario GraalVM Native Image arm64 autocontenido.

---

## setup-raspi4b-containers.sh

**Propósito:** desplegar en Raspi4B el stack desde imágenes preconstruidas en `ghcr.io` (sin compilar localmente).  
**Idempotente:** Sí

```bash
sudo bash scripts/setup-raspi4b-containers.sh
sudo bash scripts/setup-raspi4b-containers.sh --release=v1.2.3
sudo bash scripts/setup-raspi4b-containers.sh --backend=python
sudo bash scripts/setup-raspi4b-containers.sh --skip-web
sudo bash scripts/setup-raspi4b-containers.sh --skip-backend
```

Qué hace:

| Paso | Acción |
|---|---|
| 1 | Login opcional a GHCR (`GHCR_TOKEN`) |
| 2 | Pull `linux/arm64` de imágenes según backend/flags |
| 3 | Crea/recrea contenedores podman (`ai-analyzer`, `ai-analyzer-web`) |
| 4 | Genera unidades systemd para autostart |
| 5 | Verifica endpoints (`/health`, `/api/*`, `nginx-health`) |

Imágenes usadas:
- `ghcr.io/<owner>/poc-ai-analyzer-java:<release>`
- `ghcr.io/<owner>/poc-ai-analyzer-python:<release>`
- `ghcr.io/<owner>/poc-ai-analyzer-web:<release>`

Atajo con `just` (desde tu laptop/admin):

```bash
just setup-containers
just setup-containers v1.2.3
GHCR_TOKEN=ghp_xxx GHCR_USER=rafex just setup-containers v1.2.3
```

---

## raspi4b-portals-down.sh

**Propósito:** eliminar en k3s todo lo de portal/backend cautivo en Raspi4B para dejar solo componentes de IA.  
**Idempotente:** Sí

```bash
sudo bash scripts/raspi4b-portals-down.sh
sudo bash scripts/raspi4b-portals-down.sh --only-verify
```

Acciones:
- Escala a `0` deployments de portal.
- Elimina deployments/services/ingress/configmaps de captive portal.
- Verifica que no queden pods `captive-portal*` en Running.

---

## raspi4b-clean-k3s.sh

**Propósito:** desinstalar completamente k3s de Raspi4B y liberar recursos (CNI, binarios, datos).  
**Idempotente:** Sí (si ya no existe k3s, omite lo no encontrado)

```bash
sudo bash scripts/raspi4b-clean-k3s.sh --force
sudo bash scripts/raspi4b-clean-k3s.sh --dry-run
```

Acciones:
- Detiene workloads y servicio `k3s`.
- Ejecuta `k3s-uninstall.sh` si existe.
- Limpia `/var/lib/rancher/k3s`, `/etc/rancher/k3s`, CNI e interfaces (`flannel.1`, `cni0`, etc.).
- Mantiene servicios no k3s (ej. mosquitto, llama-server).

---

## setup-raspi4b-frontend.sh

**Propósito:** compilar el frontend Vite (Pug+Sass+TS) y desplegarlo con nginx en podman.  
**Idempotente:** Sí

```bash
sudo bash scripts/setup-raspi4b-frontend.sh
sudo bash scripts/setup-raspi4b-frontend.sh --skip-build   # solo redeployar contenedores
sudo bash scripts/setup-raspi4b-frontend.sh --dry-run
```

- Instala Node.js 20 via NodeSource si no está disponible
- `npm install --prefer-offline` + `npm run build` (pug → HTML + sass + ts + vite)
- `podman build` de `ai-analyzer-frontend` (nginx:alpine + dist/)
- `podman build` de `ai-analyzer-proxy` (nginx:alpine + proxy config)
- Crea red podman `ai-net`
- Arranca contenedores en `:80` (proxy) y `:3000` (frontend interno)
- Verifica `/proxy-ping` y endpoints principales

Arquitectura runtime:

```
:80 → nginx-proxy
         ├── /          → nginx-frontend :3000   (HTML/CSS/JS hasheados)
         ├── /api/*     → ai-analyzer    :5000   (API REST Java)
         ├── /health    → ai-analyzer    :5000
         └── /events    → ai-analyzer    :5000   (SSE, sin buffer)
```

---

## setup-raspi4b-portals.sh

**Propósito:** desplegar portales cautivos (clásico + lentium) en podman/k3s (topología legacy).

```bash
sudo bash scripts/setup-raspi4b-portals.sh
sudo bash scripts/setup-raspi4b-portals.sh --no-build
sudo bash scripts/setup-raspi4b-portals.sh --only-verify
```

---

## setup-openwrt.sh

**Propósito:** configuración completa del router OpenWrt.  
**Ejecutar en:** RafexPi4B (conecta al router via SSH)  
**Idempotente:** Sí

```bash
bash scripts/setup-openwrt.sh
bash scripts/setup-openwrt.sh --topology legacy
bash scripts/setup-openwrt.sh --topology split_portal --portal-ip 192.168.1.182 --ai-ip 192.168.1.167
```

| Fase | Qué hace |
|---|---|
| Pre-flight | Verifica overlay, interfaz `phy0-ap0`, SSH |
| A | Agrega llave pública a `/etc/dropbear/authorized_keys` |
| B | Configura dnsmasq: lease `120m`, option `6`, option `114`, `captive.localhost.com` |
| C | Tabla nftables `ip captive`: permanentes admin+Pi4B+Pi3B (timeout 0s), clientes 120m |
| C.1 | Reservas DHCP UCI permanentes para ambas Raspis |
| D | Verificación completa |

---

## setup-sensor-raspi3b.sh

**Propósito:** instalación del sensor de red en RafexPi3B.  
**Ejecutar en:** RafexPi3B (como root)  
**Idempotente:** Sí

```bash
sudo bash scripts/setup-sensor-raspi3b.sh
sudo bash scripts/setup-sensor-raspi3b.sh --no-ssh
sudo bash scripts/setup-sensor-raspi3b.sh --dry-run
```

| Fase | Qué hace |
|---|---|
| Hostname | `/etc/hostname` = `RafexPi3B` |
| Pre-flight | Verifica `eth0`, IP activa |
| A | `apt install tshark tcpdump python3 python3-pip openssh-client iproute2 curl` |
| B | Copia `sensor/sensor.py` → `/opt/sensor/sensor.py` |
| C | `pip3 install requests paho-mqtt` |
| D | Genera llave SSH `/opt/keys/sensor` (ed25519), intenta copiar al router |
| E | Genera y arranca `/etc/init.d/network-sensor` con todas las env vars |
| F | Verifica PID, captura tshark 5s, conectividad MQTT |

---

## Topologías

### setup-topology.sh

```bash
sudo bash scripts/setup-topology.sh --topology=legacy
sudo bash scripts/setup-topology.sh --topology=split_portal --portal-host=192.168.1.182
```

### topology-switch.sh

```bash
sudo bash scripts/topology-switch.sh legacy
sudo bash scripts/topology-switch.sh split_portal --persist
```

### verify-topology.sh

```bash
bash scripts/verify-topology.sh
bash scripts/verify-topology.sh --topology=split_portal
```

---

## Secretos — age + sops

| Script | Propósito |
|---|---|
| `secrets-init.sh` | Inicializar keypair age + crear `secrets/raspi4b.yaml` |
| `secrets-edit.sh` | Abrir editor de secretos cifrados (sops descifra → editar → cifra) |
| `secrets-push-key.sh` | Copiar clave privada age a la Pi para descifrar en deploy |

```bash
bash scripts/secrets-init.sh
bash scripts/secrets-edit.sh
bash scripts/secrets-edit.sh --set "GROQ_API_KEY=gsk_..."
bash scripts/secrets-push-key.sh --host 192.168.1.167
```

---

## Health y diagnóstico

| Script | Propósito |
|---|---|
| `health-raspi4b.sh` | Health check completo de RafexPi4B |
| `health-raspi3b-sensor.sh` | Health del sensor en RafexPi3B |
| `health-raspi3b-portal.sh` | Health del portal en RafexPi3B (topología split) |
| `health-all.sh` | Health check de todos los nodos |

```bash
bash scripts/health-raspi4b.sh
bash scripts/health-all.sh
```

---

## LLM control

```bash
bash scripts/llm-control.sh status
bash scripts/llm-control.sh off    # apaga LLM (libera CPU/RAM)
bash scripts/llm-control.sh on     # enciende LLM
bash scripts/llm-control.sh restart
bash scripts/llm-status.sh         # diagnóstico detallado
```

---

## MQTT y análisis

```bash
bash scripts/mqtt-queue-status.sh             # estado broker + cola analyzer
bash scripts/mqtt-queue-status.sh --watch     # monitoreo continuo
```

---

## OpenWrt — Control de clientes

```bash
bash scripts/openwrt-list-clients.sh              # IPs autorizadas, leases, conntrack
bash scripts/openwrt-allow-client.sh 192.168.1.55
bash scripts/openwrt-allow-client.sh 192.168.1.55 --permanent
bash scripts/openwrt-block-client.sh 192.168.1.55
bash scripts/openwrt-flush-clients.sh             # reset para nueva demo
bash scripts/openwrt-flush-clients.sh --force
bash scripts/openwrt-reset-firewall.sh            # emergencia — desactiva todo
```

---

## Demo DNS Poisoning

```bash
bash scripts/openwrt-dns-spoof-enable.sh                    # activa rafex.dev
bash scripts/openwrt-dns-spoof-enable.sh --domain otro.com
bash scripts/openwrt-dns-spoof-disable.sh
```

---

## lib/raspi4b-common.sh

Librería compartida para los scripts de Raspi4B.

| Función | Descripción |
|---|---|
| `log_info/ok/warn/error/die` | Logging estándar `[INFO] [OK] [WARN]` |
| `need_root` | Verifica ejecución como root |
| `ensure_cmd cmd...` | Falla si algún comando no está disponible |
| `run_cmd cmd...` | Ejecuta respetando `--dry-run` |
| `apt_update_once` | `apt-get update` idempotente (solo una vez por sesión) |
| `apt_install_pkgs pkg...` | Instala solo los paquetes que faltan (con cache) |
| `parse_common_flags args...` | Parsea `--dry-run --only-verify --force --no-build` |
| `init_log_dir component` | Inicializa logging a archivo con `tee` |
| `ensure_portal_ssh_key` | Genera llave SSH `/opt/keys/captive-portal` si no existe |
| `ensure_ai_analyzer_ready` | Verifica que ai-analyzer responde en `:5000` |

---

## lib/common.sh

Constantes de red y helpers para scripts que interactúan con el router.

| Constante | Valor | Descripción |
|---|---|---|
| `ROUTER_IP` | 192.168.1.1 | Router OpenWrt |
| `RASPI4B_IP` | 192.168.1.167 | RafexPi4B |
| `RASPI3B_IP` | 192.168.1.181 | RafexPi3B |
| `ADMIN_IP` | 192.168.1.113 | Laptop admin — nunca bloquear |
| `PORTAL_TIMEOUT` | 120m | Timeout nftables clientes WiFi |

| Función | Descripción |
|---|---|
| `router_ssh cmd` | SSH al router con `/opt/keys/captive-portal` |
| `router_add_ip ip` | Agrega IP al set nftables |
| `router_del_ip ip` | Elimina IP del set |
| `router_ip_in_set ip` | Verifica si IP está en `allowed_clients` |
