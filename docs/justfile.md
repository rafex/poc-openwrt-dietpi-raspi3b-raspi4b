# Referencia del Justfile — Task Runner Operacional

El `Justfile` es el punto de entrada para **todas las operaciones** del sistema: despliegues, secretos, WiFi, logs, health checks y desarrollo local. **No compila código** — eso es responsabilidad del `Makefile`.

```bash
just --list          # listar todas las tareas disponibles con su descripción
just --summary       # resumen compacto
```

---

## Variables de entorno

Todas las variables tienen un valor por defecto. Se pueden sobreescribir de tres formas:

```bash
# 1. Prefijo en el comando
RASPI4B_IP=192.168.1.200 just setup-java

# 2. Archivo .env en la raíz (no commitear)
echo 'RASPI4B_IP=192.168.1.200' >> .env

# 3. Variable de entorno exportada en la shell
export RASPI4B_IP=192.168.1.200
just setup-java
```

| Variable | Default | Descripción |
|---|---|---|
| `RASPI4B_IP` | `192.168.1.167` | IP de RafexPi4B |
| `RASPI3B_IP` | `192.168.1.181` | IP de RafexPi3B |
| `ROUTER_IP` | `192.168.1.1` | IP del router OpenWrt |
| `ADMIN_IP` | `192.168.1.113` | IP de la máquina admin (laptop) |
| `RELEASE_TAG` | `latest` | Tag de GitHub Releases para despliegues |
| `SSH_USER_PI` | `root` | Usuario SSH para Raspis |
| `SSH_USER_ROUTER` | `root` | Usuario SSH para el router |
| `OPENWRT_ENV` | `secrets/openwrt.env` | Ruta al `.env` con credenciales WiFi del repetidor |

---

## Grupo: deploy

Tareas de despliegue en los dispositivos remotos.

### `just setup-java [release]`

Despliega el binario GraalVM nativo de `ai-analyzer` en Pi4B descargando de GitHub Releases.

```bash
just setup-java                          # release: latest
just setup-java v20260428-abc1234        # release específico
RELEASE_TAG=v20260428-abc1234 just setup-java
```

Ejecuta `scripts/setup-raspi4b-ai-analyzer-java.sh` en la Pi via SSH. Ver [scripts.md](scripts.md) para detalles completos.

---

### `just setup-python`

Despliega `ai-analyzer` Python + podman en Pi4B.

```bash
just setup-python
```

---

### `just setup-python-no-build`

Re-despliega Python sin reconstruir la imagen podman (más rápido si el código no cambió).

```bash
just setup-python-no-build
```

---

### `just setup-pi4b-all`

Setup completo de Pi4B: LLM + Mosquitto + ai-analyzer Java en secuencia.

```bash
just setup-pi4b-all
```

---

### `just setup-frontend [host]`

Compila el frontend Vite (Pug+Sass+TS) y lo despliega con nginx en podman.

```bash
just setup-frontend                      # en PI4B_IP (default)
just setup-frontend 192.168.1.200        # en host alternativo
```

---

### `just setup-frontend-fast [host]`

Re-despliega el frontend sin recompilar (usa `dist/` existente).

```bash
just setup-frontend-fast
just setup-frontend-fast 192.168.1.200
```

---

### `just setup-llm`

Instala y configura `llama-server` (llama.cpp) en Pi4B.

```bash
just setup-llm
```

**Prerequisito:** modelo `.gguf` descargado en `/opt/models/` de la Pi.

---

### `just setup-mosquitto`

Instala y configura el broker MQTT Mosquitto en Pi4B.

```bash
just setup-mosquitto
```

---

### `just setup-portal`

Despliega el portal cautivo en Pi3B.

```bash
just setup-portal
```

---

### `just setup-sensor`

Despliega el sensor de red en Pi3B.

```bash
just setup-sensor
```

---

### `just setup-router`

Configuración completa del router OpenWrt: reglas nftables, dnsmasq, llaves SSH.

```bash
just setup-router
```

---

### `just router-repeater [env_file] [host]`

**Convierte el router OpenWrt en repetidor WiFi.** Se ejecuta **desde la máquina admin**: lee las credenciales del `.env` localmente y aplica la configuración UCI en el router via SSH. No se copia ningún archivo al router.

```bash
# Uso básico (usa secrets/openwrt.env y ROUTER_IP)
just router-repeater

# .env alternativo
just router-repeater env_file=secrets/openwrt-prueba.env

# Router en IP diferente
ROUTER_IP=192.168.2.1 just router-repeater

# Combinado
just router-repeater env_file=secrets/openwrt.env host=192.168.2.1
```

**Prerequisitos:**

```bash
# 1. Crear el .env con las credenciales reales (nunca va al repo)
cp secrets/openwrt.env.example secrets/openwrt.env
chmod 600 secrets/openwrt.env
# editar: HOME_SSID, HOME_PASS, AP_SSID, AP_PASS

# 2. Tener acceso SSH al router (recomendado: sin password)
ssh-copy-id root@192.168.1.1
```

Contenido del `.env`:

```sh
HOME_SSID="NombreWiFiCasa"    # SSID de la red a la que el router se conecta como cliente
HOME_PASS="PasswordCasa"       # contraseña WPA2 (mínimo 8 caracteres)
AP_SSID="OpenWrt-Portal"       # SSID del AP que el router expone para clientes
AP_PASS="PasswordAP"           # WPA2 (opcional — vacío o ausente = AP abierto)

# Radios (opcional — se autodetectan consultando el router via SSH si se omiten)
# WIFI_STA="radio0"            # radio para el cliente STA (hacia la red de casa)
# WIFI_AP="radio1"             # radio para el AP (para clientes del portal)
```

Resultado en el router:

```
radio STA (radio0) ──→ Red de casa (WWAN/WAN, DHCP)
radio AP  (radio1) ──→ AP "OpenWrt-Portal" (LAN, para clientes del portal)
```

---

## Grupo: openwrt

Control del router OpenWrt durante las demos.

### `just router-repeater-dry-run [env_file] [host]`

Muestra exactamente qué haría `router-repeater` sin aplicar ningún cambio al router. Las credenciales se leen localmente; no se establece ninguna conexión SSH durante el dry-run.

```bash
just router-repeater-dry-run
just router-repeater-dry-run env_file=secrets/openwrt.env host=192.168.2.1
```

Salida de ejemplo:

```
[INFO]  Cargando credenciales desde: secrets/openwrt.env
[OK]    Credenciales cargadas — HOME_SSID='MiCasa_WiFi'  AP_SSID='OpenWrt-Portal'
[WARN]  AP: SIN contraseña — red abierta (cualquiera puede conectarse)
[INFO]  Radio STA (cliente → casa): radio0
[INFO]  Radio AP  (para clientes):  radio1

[INFO]  ─── DRY-RUN ─── (ningún cambio se aplica en el router) ──────────
[INFO]    Router     : root@192.168.1.1
[INFO]    HOME_SSID  : MiCasa_WiFi
[INFO]    AP_SSID    : OpenWrt-Portal
[WARN]    AP_SEGUR   : ABIERTO (sin contraseña)
[INFO]    STA radio  : radio0  (cliente → red de casa)
[INFO]    AP  radio  : radio1  (AP para clientes del portal)

[OK]    Dry-run completado. Ejecuta sin --dry-run para aplicar.
```

---

### `just router-clients`

Lista las IPs autorizadas en el portal cautivo, leases DHCP y conexiones activas.

```bash
just router-clients
```

---

### `just router-block <target>`

Bloquea un cliente por MAC o IP en el firewall del router.

```bash
just router-block 192.168.1.55
just router-block aa:bb:cc:dd:ee:ff
```

---

### `just router-allow <target>`

Desbloquea un cliente bloqueado.

```bash
just router-allow 192.168.1.55
```

---

### `just router-kick <target>`

Expulsa un cliente del portal cautivo (revoca la autorización activa).

```bash
just router-kick 192.168.1.55
```

---

### `just portal-dns-on`

Activa el DNS spoofing para el portal cautivo (`rafex.dev` → IP del portal).

```bash
just portal-dns-on
```

---

### `just portal-dns-off`

Desactiva el DNS spoofing.

```bash
just portal-dns-off
```

---

### `just portal-target <ip>`

Cambia la IP objetivo del portal cautivo (a dónde redirige el DNS spoof).

```bash
just portal-target 192.168.1.182
```

---

### `just portal-reset`

Reset completo de la demo: borra autorizaciones de clientes, reglas y estado del portal.

```bash
just portal-reset
```

---

### `just wifi-connect <ssid> <pass> [cifrado] [host]`

Conecta un dispositivo (router o Pi) a una red WiFi. Detecta automáticamente si es OpenWrt o DietPi.

```bash
just wifi-connect "MiRed" "mipassword"
just wifi-connect "MiRed" "mipassword" wpa3
just wifi-connect "MiRed" "" none          # red abierta
just wifi-connect "MiRed" "pass" wpa2 192.168.1.1
```

Tipos de cifrado soportados: `wpa2` (default), `wpa3`, `wpa`, `none`.

---

### `just wifi-status [host]`

Muestra el estado de las interfaces WiFi del router.

```bash
just wifi-status                   # ROUTER_IP
just wifi-status 192.168.1.1
```

---

## Grupo: secrets

Gestión de secretos cifrados con **age + sops**. Los secretos reales **nunca van al repositorio**.

### Arquitectura de secretos

```
secrets/
├── raspi4b.yaml          # cifrado con sops+age — SÍ en el repo
├── openwrt.env.example   # plantilla — SÍ en el repo
└── openwrt.env           # credenciales reales — en .gitignore (NO en el repo)

~/.config/sops/age/       # clave privada age — solo en la máquina admin
```

---

### `just secrets-init`

Inicializa el sistema de secretos: genera keypair age, crea `secrets/raspi4b.yaml`. **Ejecutar una sola vez** en la máquina admin.

```bash
just secrets-init
```

---

### `just secrets-edit`

Abre el editor de secretos cifrados. sops descifra automáticamente → editar → cifra al guardar.

```bash
just secrets-edit
```

---

### `just secrets-show`

Muestra los secretos descifrados en el terminal. **No redirigir a un archivo**.

```bash
just secrets-show
```

---

### `just secrets-set <KV>`

Asigna un único secreto sin abrir el editor.

```bash
just secrets-set GROQ_API_KEY=gsk_abcdef123456
just secrets-set WIFI_PASSWORD=mipassword
```

---

### `just secrets-push [host]`

Copia la clave privada age a la Pi para que pueda descifrar `raspi4b.yaml` durante los despliegues.

```bash
just secrets-push                    # → PI4B_IP
just secrets-push 192.168.1.200      # → host específico
```

---

## Grupo: health

Verificación del estado del sistema.

### `just verify`

Verifica la conectividad y estado de todos los nodos del sistema (Pi4B, Pi3B, router, ai-analyzer, LLM, MQTT).

```bash
just verify
```

---

### `just health-pi4b`

Health check completo de RafexPi4B: ai-analyzer, LLM, MQTT, nginx.

```bash
just health-pi4b
```

---

### `just health-portal`

Health check del portal cautivo en Pi3B.

```bash
just health-portal
```

---

### `just health-sensor`

Health check del sensor de red en Pi3B.

```bash
just health-sensor
```

---

### `just health-all`

Health check de todos los nodos en secuencia.

```bash
just health-all
```

---

### `just verify-ai [host]`

Verifica únicamente los endpoints de ai-analyzer sin redesplegar.

```bash
just verify-ai                       # PI4B_IP:5000
just verify-ai 192.168.1.200
```

Endpoints verificados: `/health`, `/api/stats`, `/api/whitelist`, `/events` (SSE).

---

## Grupo: logs

Acceso a logs de los servicios en tiempo real.

### `just logs [host]`

Logs en tiempo real de ai-analyzer (journalctl -f). Ctrl+C para salir.

```bash
just logs
just logs 192.168.1.200
```

---

### `just logs-proxy [host]`

Logs del contenedor nginx (proxy reverso) en Pi4B.

```bash
just logs-proxy
```

---

### `just logs-frontend [host]`

Logs del contenedor nginx frontend en Pi4B.

```bash
just logs-frontend
```

---

### `just logs-llm [host]`

Logs de llama.cpp server en Pi4B.

```bash
just logs-llm
```

---

### `just logs-portal [host]`

Logs del portal cautivo en Pi3B.

```bash
just logs-portal
```

---

### `just logs-raspi <host>`

Últimas 50 líneas de logs del sistema de una Raspi (argumento obligatorio).

```bash
just logs-raspi 192.168.1.167
just logs-raspi 192.168.1.181
```

---

## Grupo: llm

Control del servicio llama.cpp en Pi4B.

### `just llm-status [host]`

Diagnóstico detallado de llama.cpp: estado del servicio, modelos disponibles, uso de RAM.

```bash
just llm-status
```

---

### `just llm-restart [host]`

Reinicia el servicio `llama-server` vía systemd.

```bash
just llm-restart
```

---

### `just llm-stop [host]`

Detiene llama.cpp, liberando RAM para otras tareas (debugging, builds, etc.).

```bash
just llm-stop
```

---

## Grupo: mqtt

### `just mqtt-status [host]`

Estado de la cola MQTT en Pi4B: broker Mosquitto, tópicos activos, mensajes pendientes.

```bash
just mqtt-status
```

---

## Grupo: maintenance

Mantenimiento y operaciones administrativas.

### `just restart [host]`

Reinicia el servicio `ai-analyzer` vía systemd en Pi4B.

```bash
just restart
just restart 192.168.1.200
```

---

### `just status [host]`

Muestra el estado actual del servicio `ai-analyzer` (systemd status).

```bash
just status
```

---

### `just topology-setup`

Inicializa el archivo `topology.env` desde una plantilla. Necesario antes de cambiar de topología.

```bash
just topology-setup
```

---

### `just topology-switch <name>`

Cambia entre topologías predefinidas del sistema.

```bash
just topology-switch legacy
just topology-switch split_portal
```

---

### `just clean-k3s [host]`

Elimina k3s de Pi4B (reemplazado por podman + binario nativo).

```bash
just clean-k3s
```

---

### `just doctor-k3s [host]`

Diagnóstico de instalaciones residuales de k3s.

```bash
just doctor-k3s
```

---

## Grupo: dev

Tareas de desarrollo local (sin SSH, sin Pi).

### `just build`

Compila el fat JAR Java delegando en el Makefile.

```bash
just build
```

---

### `just build-rust`

Compila `libanalyzer_db.so` para el host (desarrollo/test local).

```bash
just build-rust
```

---

### `just build-frontend`

Compila el frontend Vite: Pug→HTML + Sass + TypeScript → `frontend/dist/`.

```bash
just build-frontend
```

---

### `just build-all`

Build completo: Rust arm64 + fat JAR + frontend. Delega en `make all`.

```bash
just build-all
```

---

### `just dev-frontend`

Levanta el servidor de desarrollo Vite con hot-reload (Pug + Sass + TS). Requiere backend Java en `localhost:5000` (las peticiones `/api/*`, `/health`, `/events` se proxiean automáticamente).

```bash
just dev-frontend
# abre http://localhost:5173
```

---

### `just typecheck-frontend`

Ejecuta `tsc --noEmit` para verificar tipos TypeScript sin compilar.

```bash
just typecheck-frontend
```

---

### `just lint-rust`

Ejecuta `cargo check` + `cargo clippy -- -D warnings`.

```bash
just lint-rust
```

---

### `just fmt-rust`

Formatea el código Rust con `cargo fmt`.

```bash
just fmt-rust
```

---

### `just compile-java`

Compila el proyecto Java sin empaquetar (más rápido que `fat-jar` para detectar errores).

```bash
just compile-java
```

---

### `just test-java`

Ejecuta los tests Java con Maven.

```bash
just test-java
```

---

### `just sync [host]`

Sincroniza el repositorio local a la Pi via rsync (excluye `.git`, `target`, `node_modules`). Útil en desarrollo cuando no se quiere usar git en la Pi.

```bash
just sync                            # → PI4B_IP
just sync 192.168.1.181              # → Pi3B
```

---

### `just ssh-pi4b`

Abre una shell SSH interactiva a Pi4B.

```bash
just ssh-pi4b
```

---

### `just ssh-pi3b`

Abre una shell SSH interactiva a Pi3B.

```bash
just ssh-pi3b
```

---

### `just ssh-router`

Abre una shell SSH interactiva al router OpenWrt.

```bash
just ssh-router
```

---

## Flujos de trabajo completos

### Primer despliegue desde cero

```bash
# 1. Inicializar secretos (una sola vez)
just secrets-init
just secrets-set GROQ_API_KEY=gsk_...

# 2. Copiar clave age a la Pi
just secrets-push

# 3. Compilar todo
just build-all

# 4. Desplegar stack completo en Pi4B
just setup-pi4b-all

# 5. Configurar OpenWrt
just setup-router

# 6. Convertir router en repetidor WiFi
cp secrets/openwrt.env.example secrets/openwrt.env
# editar secrets/openwrt.env con HOME_SSID, HOME_PASS, AP_SSID, AP_PASS
just router-repeater

# 7. Verificar todo
just verify
```

---

### Actualización de ai-analyzer

```bash
# Compilar y publicar release (CI)
make all

# Desplegar nueva versión
just setup-java v20260430-xyz9999

# Verificar
just verify-ai
just logs
```

---

### Actualización del frontend

```bash
just build-frontend
just setup-frontend-fast         # sin recompilar — solo redeploy del contenedor
```

---

### Cambiar credenciales WiFi del repetidor

```bash
# Editar el .env local (las credenciales solo viven en la máquina admin)
vim secrets/openwrt.env

# Re-aplicar la configuración en el router (siempre desde la máquina admin)
just router-repeater

# Si solo quieres verificar qué se aplicaría antes de hacerlo
just router-repeater-dry-run
```

---

### Demo del portal cautivo

```bash
# Preparar
just portal-reset                  # estado limpio
just portal-dns-on                 # activar DNS spoof

# Durante la demo
just router-clients                # ver quién está conectado
just router-block 192.168.1.55     # bloquear dispositivo
just router-allow 192.168.1.55     # desbloquear

# Finalizar
just portal-dns-off
just portal-reset
```

---

### Debugging de ai-analyzer

```bash
just status                        # estado del servicio systemd
just logs                          # logs en tiempo real
just health-pi4b                   # health check completo
just llm-status                    # estado del LLM
just mqtt-status                   # estado de MQTT

# Si hay problema de memoria
just llm-stop                      # liberar RAM
just restart                       # reiniciar ai-analyzer
```

---

## Referencia rápida

```
DESPLIEGUE
  setup-java [release]          Despliega ai-analyzer Java en Pi4B
  setup-frontend [host]         Despliega frontend + nginx
  setup-pi4b-all                Stack completo Pi4B
  setup-router                  Configura OpenWrt
  router-repeater [env] [host]  Configura repetidor WiFi (flujo completo)

OPENWRT
  router-repeater-dry-run       Previsualiza sin aplicar cambios (sin SSH)
  router-clients                Lista clientes conectados
  router-block/allow/kick       Control de clientes
  portal-dns-on/off             Control DNS spoof
  wifi-status [host]            Estado WiFi

SECRETOS
  secrets-init                  Inicializar age+sops (una sola vez)
  secrets-edit                  Editar secretos cifrados
  secrets-set KV                Asignar un secreto
  secrets-push [host]           Copiar clave age a la Pi

ESTADO
  verify                        Verificar todo el sistema
  health-all                    Health check de todos los nodos
  verify-ai [host]              Verificar endpoints ai-analyzer
  status [host]                 Estado servicio systemd

LOGS
  logs [host]                   Logs ai-analyzer (streaming)
  logs-llm [host]               Logs llama.cpp
  logs-portal [host]            Logs portal cautivo

DESARROLLO
  dev-frontend                  Vite hot-reload local
  build-all                     Compilar todo (make all)
  lint-rust / fmt-rust          Herramientas Rust
  compile-java / test-java      Compilación/tests Java
  sync [host]                   rsync repo → Pi
  ssh-pi4b / ssh-pi3b / ssh-router   Acceso SSH
```
