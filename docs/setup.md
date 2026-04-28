# Guía de Setup — AI Analyzer + Portal Cautivo + IA Local

> Stack actual (2026-04-28):  
> **Java 21 (GraalVM nativo arm64)** · Rust SQLite (cdylib) · Vite/Pug/Sass/TS (frontend) · nginx (podman) · llama.cpp · Mosquitto

---

## Dispositivos y prerequisitos

| Dispositivo | Hostname | IP | Sistema | Rol |
|---|---|---|---|---|
| Router OpenWrt | — | 192.168.1.1 | OpenWrt 25.x | Captive portal (nftables + dnsmasq) |
| Raspberry Pi 4B | RafexPi4B | 192.168.1.167 | DietPi Bookworm | AI backend + MQTT + LLM + frontend |
| Raspberry Pi 3B | RafexPi3B | 192.168.1.181 | DietPi Bookworm | Sensor de red (tshark → MQTT) |
| Laptop admin | — | 192.168.1.113 | Cualquier SO | SSH, compilación local, despliegue |

### Prerequisitos en la Pi 4B

El script `setup-raspi4b-deps.sh` instala todo automáticamente. En caso de instalación manual:

| Dependencia | Versión mín. | Instalación |
|---|---|---|
| Debian/DietPi | Bookworm (12) | — |
| podman | 4.x | `apt install podman` |
| Node.js | 20 LTS | NodeSource: `curl -fsSL https://deb.nodesource.com/setup_20.x \| bash - && apt install nodejs` |
| age | cualquiera | `apt install age` |
| sops | 3.9+ | binario arm64 de GitHub Releases |
| curl wget git | cualquiera | `apt install curl wget git` |
| python3 | 3.x | `apt install python3` |

> **llama.cpp** y el **binario GraalVM nativo** se descargan en los scripts de cada componente.  
> **No se necesita JVM** en la Pi — el binario Java es 100% nativo (GraalVM Native Image).

---

## Paso 0 — Clonar el repositorio

```bash
# En RafexPi4B
mkdir -p /opt/repository
cd /opt/repository
git clone <url-repo> poc-openwrt-dietpi-raspi3b-raspi4b
cd poc-openwrt-dietpi-raspi3b-raspi4b
```

---

## Paso 1 — Instalar dependencias del SO (Debian/DietPi Bookworm)

```bash
sudo bash scripts/setup-raspi4b-deps.sh
```

Flags opcionales:

```bash
sudo bash scripts/setup-raspi4b-deps.sh --skip-node       # si no vas a compilar el frontend en la Pi
sudo bash scripts/setup-raspi4b-deps.sh --skip-mosquitto  # si Mosquitto ya está instalado
sudo bash scripts/setup-raspi4b-deps.sh --dry-run         # ver qué haría sin ejecutar
```

Qué instala:

| Grupo | Paquetes |
|---|---|
| Base | `curl wget git ca-certificates gnupg jq python3 openssh-client cron iproute2` |
| Contenedores | `podman uidmap slirp4netns fuse-overlayfs` |
| MQTT | `mosquitto mosquitto-clients` |
| Secretos | `age` (apt) + `sops` (binario arm64 de GitHub) |
| Frontend build | Node.js 20 LTS via NodeSource (`nodejs` = node + npm) |

---

## Paso 2 — Setup del router OpenWrt

Ejecutar **desde RafexPi4B** via SSH al router:

```bash
bash scripts/setup-openwrt.sh
# con topología explícita:
bash scripts/setup-openwrt.sh --topology legacy
bash scripts/setup-openwrt.sh --topology split_portal --portal-ip 192.168.1.182 --ai-ip 192.168.1.167
```

| Fase | Qué hace |
|---|---|
| Pre-flight | Verifica espacio en overlay, interfaz `phy0-ap0`, SSH al router |
| A | Agrega llave pública a `/etc/dropbear/authorized_keys` |
| B | Configura `dnsmasq`: lease `120m`, option `114` (URL captive), dominio `captive.localhost.com` |
| C | Crea tabla nftables `ip captive`: timeout **120m** para clientes, permanentes RafexPi4B/3B/admin |
| C.1 | Reservas DHCP UCI permanentes para ambas Raspis (`leasetime=infinite`) |
| D | Verificación completa |

> ⚠️ Emergencia — quedar bloqueado del router:
> ```bash
> ssh root@192.168.1.1
> nft delete table ip captive
> ```

### 2.1 — Uplink WiFi (WAN por WiFi 5 GHz)

```bash
bash scripts/setup-openwrt-wifi-uplink.sh \
  --uplink-ssid MiRed5G \
  --uplink-pass contraseña \
  --ap-ssid "INFINITUM MOVIL"
```

### 2.2 — Topología

```bash
sudo bash scripts/setup-topology.sh --topology=legacy
# o
sudo bash scripts/setup-topology.sh --topology=split_portal --portal-host=192.168.1.182
```

---

## Paso 3 — Setup completo de RafexPi4B (recomendado)

```bash
sudo bash scripts/setup-raspi4b-all.sh
```

Ejecuta en orden: deps → mosquitto → llm → ai-analyzer-java → frontend → portales.

Flags:

```bash
sudo bash scripts/setup-raspi4b-all.sh --skip-deps        # si los deps ya están instalados
sudo bash scripts/setup-raspi4b-all.sh --skip-llm         # si llama.cpp ya está configurado
sudo bash scripts/setup-raspi4b-all.sh --skip-portals     # solo IA + frontend
sudo bash scripts/setup-raspi4b-all.sh --skip-frontend    # solo IA + portales
sudo bash scripts/setup-raspi4b-all.sh --headless-web     # solo IA (sin portales ni frontend)
sudo bash scripts/setup-raspi4b-all.sh --dry-run          # ver sin ejecutar
```

---

## Paso 3 — Setup por componente (reinstalación parcial)

### 3.1 — Broker MQTT (Mosquitto)

```bash
sudo bash scripts/setup-raspi4b-mosquitto.sh
sudo bash scripts/setup-raspi4b-mosquitto.sh --only-verify
```

Instala `mosquitto` + `mosquitto-clients`, escribe `/etc/mosquitto/conf.d/rafexpi.conf`, reinicia el servicio y verifica publicación en `127.0.0.1:1883`.

### 3.2 — LLM local (llama.cpp)

**Prerequisito:** el modelo debe estar descargado antes:

```bash
mkdir -p /opt/models

# Opción A — Qwen2.5-0.5B (recomendado, más capaz)
wget -O /opt/models/qwen2.5-0.5b-instruct-q4_k_m.gguf \
  "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf"

# Opción B — TinyLlama (más ligero, 1.1B)
wget -O /opt/models/tinyllama-1.1b-chat-q4.gguf \
  "https://huggingface.co/TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF/resolve/main/tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf"
```

```bash
sudo bash scripts/setup-raspi4b-llm.sh
sudo bash scripts/setup-raspi4b-llm.sh --model-path=/opt/models/qwen2.5-0.5b-instruct-q4_k_m.gguf
sudo bash scripts/setup-raspi4b-llm.sh --only-verify
```

Genera `/etc/init.d/llama-server` y watchdog cron. Health check: `http://127.0.0.1:8081/health`.

### 3.3 — AI Analyzer (binario GraalVM nativo)

```bash
sudo bash scripts/setup-raspi4b-ai-analyzer-java.sh
sudo bash scripts/setup-raspi4b-ai-analyzer-java.sh --release=v20250425-abc1234
sudo bash scripts/setup-raspi4b-ai-analyzer-java.sh --only-verify
sudo bash scripts/setup-raspi4b-ai-analyzer-java.sh --dry-run
```

Qué hace:

| Paso | Acción |
|---|---|
| 1 | Instala `age` + `sops` si no están |
| 2 | Descifra `secrets/raspi4b.yaml` → `GROQ_API_KEY` en memoria |
| 3 | Descarga `ai-analyzer-linux-arm64` + `libanalyzer_db-linux-arm64.so` de GitHub Releases |
| 4 | Instala en `/opt/ai-analyzer/{bin,lib,html}/` |
| 5 | Escribe `/etc/ai-analyzer.env` (chmod 600) |
| 6 | Instala y arranca `systemd` `ai-analyzer.service` |
| 7 | Verifica `/health` y endpoints principales |

Servicio systemd:
- `Type=simple` · `MemoryMax=300M` · `Restart=on-failure`
- `LD_LIBRARY_PATH=/opt/ai-analyzer/lib`
- Escucha en `:5000`

```bash
systemctl status ai-analyzer
journalctl -u ai-analyzer -f
systemctl restart ai-analyzer
```

### 3.4 — Frontend (Vite dist + nginx podman)

```bash
sudo bash scripts/setup-raspi4b-frontend.sh
sudo bash scripts/setup-raspi4b-frontend.sh --skip-build   # solo redeployar contenedores
sudo bash scripts/setup-raspi4b-frontend.sh --dry-run
```

Qué hace:

| Paso | Acción |
|---|---|
| 1 | `npm install` + `npm run build` (Pug → HTML, Sass, TypeScript, Vite) |
| 2 | Copia `dist/` al contexto del Dockerfile frontend |
| 3 | `podman build` imagen `ai-analyzer-frontend` (nginx:alpine + dist/) |
| 4 | `podman build` imagen `ai-analyzer-proxy` (nginx:alpine + config proxy) |
| 5 | Crea red podman `ai-net` si no existe |
| 6 | Arranca contenedores `ai-analyzer-frontend` (:3000) y `ai-analyzer-proxy` (:80) |
| 7 | Verifica endpoints via HTTP |

Arquitectura en runtime:

```
:80 → podman nginx-proxy
         ├── /           → podman nginx-frontend :3000
         ├── /api/*      → systemd ai-analyzer   :5000
         ├── /health     → systemd ai-analyzer   :5000
         └── /events     → systemd ai-analyzer   :5000  (SSE, sin buffer)
```

```bash
podman ps                             # estado contenedores
podman logs -f ai-analyzer-proxy      # logs proxy
podman logs -f ai-analyzer-frontend   # logs frontend
```

---

## Paso 4 — Setup de RafexPi3B (sensor de red)

Ejecutar **en RafexPi3B**:

```bash
sudo bash scripts/setup-sensor-raspi3b.sh
sudo bash scripts/setup-sensor-raspi3b.sh --no-ssh    # sin SSH al router
sudo bash scripts/setup-sensor-raspi3b.sh --dry-run
```

| Fase | Qué hace |
|---|---|
| Hostname | `/etc/hostname` = `RafexPi3B` |
| A | Instala `tshark tcpdump python3 python3-pip openssh-client iproute2 curl` |
| B | Copia `sensor/sensor.py` → `/opt/sensor/sensor.py` |
| C | `pip3 install requests paho-mqtt` |
| D | Genera llave SSH `/opt/keys/sensor`; copia al router |
| E | Genera y arranca `/etc/init.d/network-sensor` |
| F | Verifica captura + MQTT |

---

## Paso 5 — Verificar el sistema completo

```bash
bash scripts/verify-topology.sh
bash scripts/health-raspi4b.sh
```

| Recurso | URL |
|---|---|
| Dashboard | `http://192.168.1.167/` |
| Chat IA (Groq/Qwen) | `http://192.168.1.167/chat.html` |
| Terminal | `http://192.168.1.167/terminal.html` |
| Reglas y políticas | `http://192.168.1.167/rulez.html` |
| Reportes | `http://192.168.1.167/reports.html` |
| Health API (directo) | `http://192.168.1.167:5000/health` |
| LLM health | `http://192.168.1.167:8081/health` |

---

## Paso 6 — Secretos (Groq API Key)

```bash
# Inicializar sistema (solo una vez en la laptop admin)
bash scripts/secrets-init.sh

# Copiar clave age a la Pi
bash scripts/secrets-push-key.sh --host 192.168.1.167

# Editar secretos
bash scripts/secrets-edit.sh

# Asignar un valor directo
bash scripts/secrets-edit.sh --set "GROQ_API_KEY=gsk_..."
```

Los secretos se cifran con `age` + `sops` en `secrets/raspi4b.yaml` y se descifran en memoria durante el despliegue. **Nunca se almacenan en texto plano en disco.**

---

## Paso 7 — Demo captive portal (prueba real)

1. Conectar dispositivo al WiFi `INFINITUM MOVIL`
2. Abrir URL HTTP: `http://neverssl.com` o `http://example.com`
3. El router redirige al portal: `http://192.168.1.167/portal`
4. Sin aceptar → sin internet. Con aceptar → libre durante **120 minutos**

```bash
bash scripts/openwrt-list-clients.sh      # clientes actuales
bash scripts/openwrt-flush-clients.sh     # resetear para nueva demo
```

---

## Compilación local (laptop admin)

El binario GraalVM y el frontend se compilan en la laptop y se despliegan vía GitHub Releases + `setup-raspi4b-all.sh`.

```bash
# Prerequisitos en laptop admin:
#   - Rust + rustup (target aarch64-unknown-linux-gnu)
#   - JDK 21 + GraalVM CE 21
#   - Node.js >= 20
#   - gcc-aarch64-linux-gnu (Linux) / musl-cross (macOS)

# Build completo
make all           # Rust arm64 + fat JAR + frontend dist/

# Build individual
make rust-arm64    # solo .so arm64
make fat-jar       # solo fat JAR
make frontend      # solo Vite dist

# Verificación de código
make check         # cargo check + clippy + mvnw compile
just typecheck-frontend   # tsc --noEmit
```

---

## Actualización del sistema

### Actualizar AI Analyzer (nueva release)

```bash
# Desde laptop admin — merge, push → CI genera release automáticamente

# En Pi4B — descargar y reinstalar binarios de la release
sudo bash scripts/setup-raspi4b-ai-analyzer-java.sh --release=v20260428-abc1234
# o para tomar la última:
sudo bash scripts/setup-raspi4b-ai-analyzer-java.sh
```

### Actualizar solo el frontend

```bash
# Opción A — compilar en laptop y desplegar
make frontend
just setup-frontend   # rsync + podman rebuild en Pi

# Opción B — compilar directamente en la Pi
just setup-frontend   # hace npm build + podman en la Pi
```

### Actualizar sensor (Pi3B)

```bash
cp sensor/sensor.py /opt/sensor/sensor.py
/etc/init.d/network-sensor restart
```

---

## Diagnóstico rápido

```bash
# ── AI Analyzer ──────────────────────────────────────────────────────────────
systemctl status ai-analyzer
journalctl -u ai-analyzer -n 50 --no-pager
curl -s http://127.0.0.1:5000/health | python3 -m json.tool

# ── Frontend / nginx ──────────────────────────────────────────────────────────
podman ps
podman logs ai-analyzer-proxy
podman logs ai-analyzer-frontend
curl -s http://127.0.0.1:80/proxy-ping

# ── LLM llama.cpp ─────────────────────────────────────────────────────────────
/etc/init.d/llama-server status
curl -s http://127.0.0.1:8081/health
bash scripts/llm-status.sh

# ── MQTT Mosquitto ────────────────────────────────────────────────────────────
systemctl status mosquitto || /etc/init.d/mosquitto status
mosquitto_sub -h 127.0.0.1 -t "rafexpi/sensor/batch" -v &

# ── Sensor (en RafexPi3B) ─────────────────────────────────────────────────────
/etc/init.d/network-sensor status
tail -f /var/log/network-sensor.log

# ── Router ────────────────────────────────────────────────────────────────────
bash scripts/openwrt-list-clients.sh
ssh root@192.168.1.1 "nft list table ip captive"
```

---

## Notas importantes

### DietPi / Debian Bookworm (Raspis)

- Scripts de servicios: `/etc/init.d/` + `update-rc.d defaults` como fallback; systemd cuando está disponible
- Builds de contenedores: `podman build --cgroup-manager=cgroupfs --runtime=runc` (si falla con cgroupfs v2)
- **No se necesita k3s ni JVM** — el backend Java es un binario ELF estático arm64

### AI Analyzer — binario GraalVM

- Arranque < 100ms, ~80MB RAM base, sin JVM
- SQLite via `libanalyzer_db.so` (Rust bundled) — sin `libsqlite3-dev` del sistema
- `LD_LIBRARY_PATH=/opt/ai-analyzer/lib` inyectado por systemd
- Env vars desde `/etc/ai-analyzer.env` (chmod 600)

### Frontend — Vite + Pug + Sass + TypeScript

- No hay framework JS (sin Vue, React, Angular)
- Pug compila a HTML como paso `prebuild`; Vite procesa TypeScript y Sass
- Animate.css importado vía Sass (`@use "animate.css/animate.min.css"`)
- nginx en podman sirve los estáticos hasheados con cache agresivo

### OpenWrt

- Exclusivamente `nft` — **no `iptables`**
- Servicios con `/etc/init.d/` (OpenWrt no tiene systemd)
- `timeout 0` debe escribirse como `timeout 0s`

### llama.cpp

- Flags válidos: `--model --port --host --ctx-size --threads --parallel`
- **NO usar**: `--n-parallel --n-predict --log-disable`
- `ctx-size=4096` es el mínimo seguro
