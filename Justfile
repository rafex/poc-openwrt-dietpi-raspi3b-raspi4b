# =============================================================================
# Justfile — RESPONSABILIDAD ÚNICA: TASK RUNNER OPERACIONAL
# =============================================================================
# Qué hace este archivo:
#   • Desplegar servicios en Raspberry Pi (ai-analyzer, llm, mosquitto…)
#   • Gestionar secretos (age + sops)
#   • Controlar redes WiFi, OpenWrt, portal cautivo
#   • Verificar estado del sistema (health checks, logs)
#   • Tareas de desarrollo local (lint, fmt, test)
#
# Qué NO hace:
#   • Compilar código (→ Makefile)
#   • Empaquetar artefactos (→ Makefile)
#
# Uso:
#   just --list                   # listar todas las tareas disponibles
#   just setup-java               # desplegar ai-analyzer Java en Pi4B
#   just setup-python             # desplegar ai-analyzer Python/podman en Pi4B
#   just secrets-init             # inicializar sistema age+sops
#   just verify                   # verificar todos los endpoints del sistema
#   just logs                     # ver logs de ai-analyzer en Pi4B
# =============================================================================

# Directorio del Justfile (raíz del proyecto)
project_root := justfile_directory()
scripts      := project_root / "scripts"

# ── Variables de entorno con defaults ────────────────────────────────────────
# Pueden sobreescribirse: PI4B_IP=192.168.1.200 just setup-java
PI4B_IP        := env_var_or_default("RASPI4B_IP",      "192.168.1.167")
PI3B_IP        := env_var_or_default("RASPI3B_IP",      "192.168.1.181")
ROUTER_IP      := env_var_or_default("ROUTER_IP",       "192.168.1.1")
ADMIN_IP       := env_var_or_default("ADMIN_IP",        "192.168.1.113")
RELEASE_TAG    := env_var_or_default("RELEASE_TAG",     "latest")
SSH_USER_PI    := env_var_or_default("SSH_USER_PI",     "root")
SSH_USER_ROUTER := env_var_or_default("SSH_USER_ROUTER","root")

# =============================================================================
# DESPLIEGUE — ai-analyzer (Java nativo + Rust .so)
# =============================================================================

# Despliega ai-analyzer Java nativo en Pi4B (descarga binarios de GitHub Releases)
[group('deploy')]
setup-java release=RELEASE_TAG:
    @echo "→ Desplegando ai-analyzer Java (release: {{release}}) en {{PI4B_IP}}"
    ssh {{SSH_USER_PI}}@{{PI4B_IP}} \
      "cd /opt/repository/poc-openwrt-dietpi-raspi3b-raspi4b && \
       bash scripts/setup-raspi4b-ai-analyzer-java.sh --release={{release}}"

# Despliega ai-analyzer Python + podman en Pi4B
[group('deploy')]
setup-python:
    @echo "→ Desplegando ai-analyzer Python/podman en {{PI4B_IP}}"
    ssh {{SSH_USER_PI}}@{{PI4B_IP}} \
      "cd /opt/repository/poc-openwrt-dietpi-raspi3b-raspi4b && \
       bash scripts/setup-raspi4b-ai-analyzer.sh"

# Despliega ai-analyzer Python pero saltando el build de imagen
[group('deploy')]
setup-python-no-build:
    @echo "→ Re-desplegando ai-analyzer Python (sin rebuild) en {{PI4B_IP}}"
    ssh {{SSH_USER_PI}}@{{PI4B_IP}} \
      "cd /opt/repository/poc-openwrt-dietpi-raspi3b-raspi4b && \
       bash scripts/setup-raspi4b-ai-analyzer.sh --no-build"

# Despliega el stack completo de la Pi4B (llm + mosquitto + ai-analyzer Java)
[group('deploy')]
setup-pi4b-all:
    @echo "→ Setup completo Pi4B en {{PI4B_IP}}"
    ssh {{SSH_USER_PI}}@{{PI4B_IP}} \
      "cd /opt/repository/poc-openwrt-dietpi-raspi3b-raspi4b && \
       bash scripts/setup-raspi4b-all.sh"

# Despliega el frontend (Vite dist) + nginx en Pi4B via podman
[group('deploy')]
setup-frontend host=PI4B_IP:
    @echo "→ Desplegando frontend + nginx proxy en {{host}}"
    ssh {{SSH_USER_PI}}@{{host}} \
      "cd /opt/repository/poc-openwrt-dietpi-raspi3b-raspi4b && \
       bash scripts/setup-raspi4b-frontend.sh"

# Despliega frontend sin recompilar (usa dist/ existente)
[group('deploy')]
setup-frontend-fast host=PI4B_IP:
    @echo "→ Re-desplegando frontend (sin rebuild) en {{host}}"
    ssh {{SSH_USER_PI}}@{{host}} \
      "cd /opt/repository/poc-openwrt-dietpi-raspi3b-raspi4b && \
       bash scripts/setup-raspi4b-frontend.sh --skip-build"

# Despliega llama.cpp en Pi4B
[group('deploy')]
setup-llm:
    @echo "→ Setup llama.cpp en {{PI4B_IP}}"
    ssh {{SSH_USER_PI}}@{{PI4B_IP}} \
      "cd /opt/repository/poc-openwrt-dietpi-raspi3b-raspi4b && \
       bash scripts/setup-raspi4b-llm.sh"

# Despliega Mosquitto MQTT en Pi4B
[group('deploy')]
setup-mosquitto:
    @echo "→ Setup Mosquitto en {{PI4B_IP}}"
    ssh {{SSH_USER_PI}}@{{PI4B_IP}} \
      "cd /opt/repository/poc-openwrt-dietpi-raspi3b-raspi4b && \
       bash scripts/setup-raspi4b-mosquitto.sh"

# Despliega portal cautivo en Pi3B
[group('deploy')]
setup-portal:
    @echo "→ Setup portal cautivo en {{PI3B_IP}}"
    ssh {{SSH_USER_PI}}@{{PI3B_IP}} \
      "cd /opt/repository/poc-openwrt-dietpi-raspi3b-raspi4b && \
       bash scripts/setup-portal-raspi3b.sh"

# Despliega sensor de red en Pi3B
[group('deploy')]
setup-sensor:
    @echo "→ Setup sensor en {{PI3B_IP}}"
    ssh {{SSH_USER_PI}}@{{PI3B_IP}} \
      "cd /opt/repository/poc-openwrt-dietpi-raspi3b-raspi4b && \
       bash scripts/setup-sensor-raspi3b.sh"

# Configura OpenWrt (router)
[group('deploy')]
setup-router:
    @echo "→ Setup OpenWrt en {{ROUTER_IP}}"
    bash {{scripts}}/setup-openwrt.sh

# =============================================================================
# SECRETOS — age + sops
# =============================================================================

# Inicializa el sistema de secretos (genera keypair age, cifra secrets/raspi4b.yaml)
# Ejecutar UNA SOLA VEZ en la máquina admin
[group('secrets')]
secrets-init:
    @echo "→ Inicializando sistema de secretos age+sops"
    bash {{scripts}}/secrets-init.sh

# Abre el editor de secretos (sops descifra → editar → cifra al guardar)
[group('secrets')]
secrets-edit:
    @echo "→ Editando secretos cifrados"
    bash {{scripts}}/secrets-edit.sh

# Muestra los secretos actuales descifrados (NO commitear la salida)
[group('secrets')]
secrets-show:
    @echo "→ Mostrando secretos (solo en terminal local)"
    bash {{scripts}}/secrets-edit.sh --show

# Asigna un secreto sin abrir editor: just secrets-set GROQ_API_KEY=gsk_...
[group('secrets')]
secrets-set kv:
    @echo "→ Asignando secreto"
    bash {{scripts}}/secrets-edit.sh --set "{{kv}}"

# Copia la clave privada age a Pi4B para que pueda descifrar en cada deploy
[group('secrets')]
secrets-push host=PI4B_IP:
    @echo "→ Copiando clave age a {{host}}"
    bash {{scripts}}/secrets-push-key.sh --host {{host}}

# =============================================================================
# VERIFICACIÓN Y SALUD
# =============================================================================

# Verifica todos los endpoints del sistema completo
[group('health')]
verify:
    @echo "→ Verificando sistema completo"
    bash {{scripts}}/verify-topology.sh

# Health check de ai-analyzer en Pi4B
[group('health')]
health-pi4b:
    @echo "→ Health Pi4B ({{PI4B_IP}})"
    bash {{scripts}}/health-raspi4b.sh

# Health check del portal cautivo en Pi3B
[group('health')]
health-portal:
    @echo "→ Health portal cautivo ({{PI3B_IP}})"
    bash {{scripts}}/health-raspi3b-portal.sh

# Health check del sensor en Pi3B
[group('health')]
health-sensor:
    @echo "→ Health sensor ({{PI3B_IP}})"
    bash {{scripts}}/health-raspi3b-sensor.sh

# Health check de todos los nodos
[group('health')]
health-all:
    @echo "→ Health check completo"
    bash {{scripts}}/health-all.sh

# Solo verifica los endpoints de ai-analyzer (sin re-desplegar)
[group('health')]
verify-ai host=PI4B_IP:
    @echo "→ Verificando ai-analyzer en {{host}}:5000"
    ssh {{SSH_USER_PI}}@{{host}} \
      "cd /opt/repository/poc-openwrt-dietpi-raspi3b-raspi4b && \
       bash scripts/setup-raspi4b-ai-analyzer-java.sh --only-verify"

# =============================================================================
# LOGS
# =============================================================================

# Logs en tiempo real de ai-analyzer en Pi4B
[group('logs')]
logs host=PI4B_IP:
    @echo "→ Logs ai-analyzer ({{host}}) — Ctrl+C para salir"
    ssh {{SSH_USER_PI}}@{{host}} "journalctl -u ai-analyzer -f --no-pager"

# Logs del nginx proxy en Pi4B
[group('logs')]
logs-proxy host=PI4B_IP:
    @echo "→ Logs nginx proxy ({{host}})"
    ssh {{SSH_USER_PI}}@{{host}} "podman logs -f ai-analyzer-proxy"

# Logs del contenedor frontend en Pi4B
[group('logs')]
logs-frontend host=PI4B_IP:
    @echo "→ Logs nginx frontend ({{host}})"
    ssh {{SSH_USER_PI}}@{{host}} "podman logs -f ai-analyzer-frontend"

# Logs de llama.cpp en Pi4B
[group('logs')]
logs-llm host=PI4B_IP:
    @echo "→ Logs llama.cpp ({{host}})"
    ssh {{SSH_USER_PI}}@{{host}} "journalctl -u llama-server -f --no-pager"

# Logs del portal cautivo en Pi3B
[group('logs')]
logs-portal host=PI3B_IP:
    @echo "→ Logs portal ({{host}})"
    ssh {{SSH_USER_PI}}@{{host}} "journalctl -u captive-portal -f --no-pager"

# Logs generales de una Raspi (últimas 50 líneas)
[group('logs')]
logs-raspi host:
    @echo "→ Últimos logs de {{host}}"
    bash {{scripts}}/raspi-logs.sh {{host}}

# =============================================================================
# WIFI Y RED
# =============================================================================

# Conecta a una red WiFi (detecta OS: OpenWrt/DietPi)
# Uso: just wifi-connect SSID contraseña [cifrado]
# cifrado: wpa2 (default), wpa3, wpa, none
[group('wifi')]
wifi-connect ssid pass cifrado="wpa2" host=ROUTER_IP:
    @echo "→ Conectando {{host}} a WiFi '{{ssid}}' ({{cifrado}})"
    bash {{scripts}}/wifi-connect.sh \
      --host {{host}} \
      --ssid "{{ssid}}" \
      --pass "{{pass}}" \
      --security "{{cifrado}}"

# Estado del uplink WiFi en OpenWrt
[group('wifi')]
wifi-status host=ROUTER_IP:
    @echo "→ Estado WiFi en {{host}}"
    ssh {{SSH_USER_ROUTER}}@{{host}} "iwinfo 2>/dev/null || iw dev"

# =============================================================================
# OPENWRT — Control de clientes
# =============================================================================

# Lista clientes conectados al router
[group('openwrt')]
router-clients:
    @echo "→ Clientes en {{ROUTER_IP}}"
    bash {{scripts}}/openwrt-list-clients.sh

# Bloquea un cliente por MAC o IP
[group('openwrt')]
router-block target:
    @echo "→ Bloqueando {{target}} en {{ROUTER_IP}}"
    bash {{scripts}}/openwrt-block-client.sh --target "{{target}}"

# Desbloquea un cliente por MAC o IP
[group('openwrt')]
router-allow target:
    @echo "→ Desbloqueando {{target}} en {{ROUTER_IP}}"
    bash {{scripts}}/openwrt-allow-client.sh --target "{{target}}"

# Expulsa un cliente del portal cautivo
[group('openwrt')]
router-kick target:
    @echo "→ Expulsando {{target}}"
    bash {{scripts}}/openwrt-kick-client.sh --target "{{target}}"

# Activa el DNS spoofing del portal cautivo
[group('openwrt')]
portal-dns-on:
    @echo "→ Activando DNS spoof (portal cautivo)"
    bash {{scripts}}/openwrt-dns-spoof-enable.sh

# Desactiva el DNS spoofing
[group('openwrt')]
portal-dns-off:
    @echo "→ Desactivando DNS spoof"
    bash {{scripts}}/openwrt-dns-spoof-disable.sh

# Cambia el objetivo del portal (IP a redirigir)
[group('openwrt')]
portal-target ip:
    @echo "→ Cambiando objetivo portal a {{ip}}"
    bash {{scripts}}/openwrt-portal-target.sh --ip "{{ip}}"

# Reset completo de la demo (portal + reglas + clientes)
[group('openwrt')]
portal-reset:
    @echo "→ Reset demo del portal cautivo"
    bash {{scripts}}/portal-reset-demo.sh

# =============================================================================
# LLM — llama.cpp
# =============================================================================

# Estado de llama.cpp en Pi4B
[group('llm')]
llm-status host=PI4B_IP:
    @echo "→ Estado llama.cpp en {{host}}"
    bash {{scripts}}/llm-status.sh --host {{host}}

# Reinicia llama.cpp en Pi4B
[group('llm')]
llm-restart host=PI4B_IP:
    @echo "→ Reiniciando llama.cpp en {{host}}"
    ssh {{SSH_USER_PI}}@{{host}} "systemctl restart llama-server"

# Detiene llama.cpp (libera RAM para otras tareas)
[group('llm')]
llm-stop host=PI4B_IP:
    @echo "→ Deteniendo llama.cpp en {{host}}"
    ssh {{SSH_USER_PI}}@{{host}} "systemctl stop llama-server"

# =============================================================================
# MQTT
# =============================================================================

# Estado de la cola MQTT en Pi4B
[group('mqtt')]
mqtt-status host=PI4B_IP:
    @echo "→ Estado MQTT en {{host}}"
    bash {{scripts}}/mqtt-queue-status.sh --host {{host}}

# =============================================================================
# MANTENIMIENTO
# =============================================================================

# Elimina k3s de Pi4B (ya no se usa, reemplazado por podman/binario nativo)
[group('maintenance')]
clean-k3s host=PI4B_IP:
    @echo "→ Limpiando k3s de {{host}}"
    ssh {{SSH_USER_PI}}@{{host}} \
      "cd /opt/repository/poc-openwrt-dietpi-raspi3b-raspi4b && \
       bash scripts/raspi4b-clean-k3s.sh"

# Diagnóstico de k3s (por si queda alguna instalación)
[group('maintenance')]
doctor-k3s host=PI4B_IP:
    @echo "→ Diagnóstico k3s en {{host}}"
    ssh {{SSH_USER_PI}}@{{host}} \
      "cd /opt/repository/poc-openwrt-dietpi-raspi3b-raspi4b && \
       bash scripts/raspi4b-k3s-doctor.sh --check"

# Reinicia ai-analyzer en Pi4B
[group('maintenance')]
restart host=PI4B_IP:
    @echo "→ Reiniciando ai-analyzer en {{host}}"
    ssh {{SSH_USER_PI}}@{{host}} "systemctl restart ai-analyzer"

# Estado de ai-analyzer como servicio systemd
[group('maintenance')]
status host=PI4B_IP:
    @echo "→ Estado ai-analyzer en {{host}}"
    ssh {{SSH_USER_PI}}@{{host}} "systemctl status ai-analyzer --no-pager"

# Topología: inicializar archivo topology.env desde una plantilla
[group('maintenance')]
topology-setup:
    @echo "→ Configurando topología"
    bash {{scripts}}/setup-topology.sh

# Cambia entre topologías predefinidas
[group('maintenance')]
topology-switch name:
    @echo "→ Cambiando topología a '{{name}}'"
    bash {{scripts}}/topology-switch.sh "{{name}}"

# =============================================================================
# DESARROLLO LOCAL
# =============================================================================

# Lint + check Rust (sin compilar artefacto final)
[group('dev')]
lint-rust:
    @echo "→ cargo check + clippy"
    cd {{project_root}}/backend/java/ai-analyzer/db-lib && \
      cargo check && cargo clippy -- -D warnings
    @echo "✓ Rust OK"

# Formato Rust
[group('dev')]
fmt-rust:
    @echo "→ cargo fmt"
    cd {{project_root}}/backend/java/ai-analyzer/db-lib && cargo fmt

# Compilar Java sin empaquetar (rápido, solo verifica errores de compilación)
[group('dev')]
compile-java:
    @echo "→ mvnw compile"
    cd {{project_root}}/backend/java/ai-analyzer && ./mvnw compile -q

# Tests Java (cuando se agreguen)
[group('dev')]
test-java:
    @echo "→ mvnw test"
    cd {{project_root}}/backend/java/ai-analyzer && ./mvnw test

# Construir fat JAR localmente (delega a Makefile)
[group('dev')]
build:
    @echo "→ make fat-jar (delega a Makefile)"
    make -C {{project_root}} fat-jar

# Construir Rust host (delega a Makefile)
[group('dev')]
build-rust:
    @echo "→ make rust (delega a Makefile)"
    make -C {{project_root}} rust

# Construir frontend localmente (delega a Makefile)
[group('dev')]
build-frontend:
    @echo "→ make frontend (delega a Makefile)"
    make -C {{project_root}} frontend

# Dev mode frontend (hot-reload pug + sass + ts) — local
[group('dev')]
dev-frontend:
    @echo "→ Frontend dev mode (pug watch + vite)"
    cd {{project_root}}/frontend && npm run dev

# Type-check TypeScript del frontend
[group('dev')]
typecheck-frontend:
    @echo "→ tsc --noEmit"
    cd {{project_root}}/frontend && npm run typecheck

# Build completo (Rust arm64 + fat JAR + frontend) — delega a Makefile
[group('dev')]
build-all:
    @echo "→ make all (delega a Makefile)"
    make -C {{project_root}} all

# Sync del repo a Pi4B via rsync (para desarrollo sin git en la Pi)
[group('dev')]
sync host=PI4B_IP:
    @echo "→ Sincronizando repo a {{host}}:/opt/repository/"
    rsync -avz --exclude='.git' --exclude='target' --exclude='node_modules' \
      {{project_root}}/ \
      {{SSH_USER_PI}}@{{host}}:/opt/repository/poc-openwrt-dietpi-raspi3b-raspi4b/

# Shell SSH a Pi4B
[group('dev')]
ssh-pi4b:
    ssh {{SSH_USER_PI}}@{{PI4B_IP}}

# Shell SSH a Pi3B
[group('dev')]
ssh-pi3b:
    ssh {{SSH_USER_PI}}@{{PI3B_IP}}

# Shell SSH al router OpenWrt
[group('dev')]
ssh-router:
    ssh {{SSH_USER_ROUTER}}@{{ROUTER_IP}}
