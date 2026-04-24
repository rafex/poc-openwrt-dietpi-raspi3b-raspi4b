# Release v0.3.0

**24 de Abril de 2026**

## Resumen

Release enfocanda en herramientas de diagnóstico, control inteligente de llamadas LLM y mejoras de portabilidad. Se agregan scripts de monitoreo integral para debugging en tiempo real de la pila MQTT + AI. Nuevo soporte para modelos GGUF personalizados y stack IA modular.

## 🎯 Características Principales

### 1. Herramientas de Diagnóstico Avanzadas

#### `llm-status.sh`
Inspecciona a fondo el estado de `llama-server`:
- Estado del servicio init.d
- PID en ejecución con verificación de proceso
- Health check HTTP en puerto 8081 (`/health`)
- Modelo actualmente cargado (desde `/proc/<pid>/cmdline`)
- Modelo configurado en el servicio (fallback)
- Línea de comandos completa del proceso

**Uso:**
```bash
bash scripts/llm-status.sh
```

#### `mqtt-queue-status.sh`
Diagnóstico integral de broker Mosquitto y cola del analyzer:
- Estado del servicio y PID
- Puerto 1883 en LISTEN
- Métricas `$SYS` del broker (clientes, subscripciones, bytes)
- Estado de cola (pending/processing/done/error)
- Estadísticas de procesamiento (batches_ok/error, llama_calls)
- Estado del pod ai-analyzer en k3s
- Resumen de SQLite (batches por status)

**Modo watch:**
```bash
bash scripts/mqtt-queue-status.sh --watch --interval 5
```

### 2. Control Inteligente de LLM en Clasificador de Dominios

Sistema de **budgeting** adaptativo que evita saturación del LLM:

**Safe Mode (adaptativo):**
- Se activa cuando `queue_size ≤ DOMAIN_CLASSIFIER_LLM_MAX_QUEUE_SIZE`
- Presupuesto máximo: `DOMAIN_CLASSIFIER_LLM_MAX_NEW_PER_REQUEST` llamadas por request
- Se desactiva cuando cola crece (evita overhead en períodos altos)

**Parámetros Configurables:**
```bash
# En k8s deployment o env vars:
DOMAIN_CLASSIFIER_LLM_MAX_NEW_PER_REQUEST=2    # Max llamadas por request
DOMAIN_CLASSIFIER_LLM_TIMEOUT_S=8               # Timeout en segundos
DOMAIN_CLASSIFIER_LLM_N_PREDICT=48              # Tokens de respuesta
DOMAIN_CLASSIFIER_LLM_MAX_QUEUE_SIZE=4          # Umbral para safe_mode
```

**Métricas expuestas** en `/api/stats`:
```json
{
  "llm_classifier": {
    "enabled": true,
    "safe_mode": true,
    "queue_size": 2,
    "max_queue_size": 4,
    "max_new_per_request": 2,
    "used_budget": 1,
    "timeout_s": 8,
    "n_predict": 48
  }
}
```

### 3. Setup Modular - Bundle AI Stack

Nuevo `setup-raspi4b-ai-stack.sh`:
```bash
# Instala solo stack IA (sin portales)
bash scripts/setup-raspi4b-ai-stack.sh

# Con controladores:
bash scripts/setup-raspi4b-ai-stack.sh --skip-mosquitto
bash scripts/setup-raspi4b-ai-stack.sh --skip-llm
bash scripts/setup-raspi4b-ai-stack.sh --skip-analyzer
```

Ejecuta internamente:
- `setup-raspi4b-mosquitto.sh`
- `setup-raspi4b-llm.sh`
- `setup-raspi4b-ai-analyzer.sh`

### 4. Soporte Modelos Personalizados

Flag `--model-path` en `setup-raspi4b-llm.sh`:
```bash
# Usar modelo en ubicación personalizada
bash scripts/setup-raspi4b-llm.sh --model-path=/opt/custom/qwen2.5-0.5b.gguf

# Búsqueda mejorada:
# - Patrones más flexibles para Qwen2.5 y TinyLlama
# - Cachés de Hugging Face (~/.cache/huggingface/hub/)
# - Fallback robusto con find() si los patrones fallan
```

## 🔧 Cambios Técnicos

### OpenWrt - Persistencia de nftables

**Antes:**
```
/etc/nftables.d/captive-portal.nft  ← parseado automáticamente por fw4
```

**Después:**
```
/etc/captive-portal.nft  ← incluido explícitamente vía script
/etc/captive-portal-fw4-include.sh  ← wrapper registrado en UCI firewall
```

Beneficio: Evita errores sintácticos de fw4 al intentar parsear archivo
que contiene tabla `ip` a nivel top-level.

### LLM - Parámetros Configurables

Función `call_llama()` ahora soporta:
```python
def call_llama(
    prompt: str,
    *,
    timeout_s: int = 120,
    n_predict: int | None = None,
    temperature: float = 0.7,
    top_p: float = 0.9,
) -> str:
```

Usada desde clasificador de dominios:
```python
response = call_llama(
    prompt,
    timeout_s=DOMAIN_CLASSIFIER_LLM_TIMEOUT_S,  # 8s
    n_predict=DOMAIN_CLASSIFIER_LLM_N_PREDICT,  # 48 tokens
    temperature=0.1,                             # Más determinista
    top_p=0.5,
)
```

### Portabilidad Mejorada

- **mqtt-queue-status.sh**: Migración de here-string (`<<<"$json"`) a variable de entorno
- **setup-raspi4b-llm.sh**: Búsqueda de modelos con fallback robusto
- **Python3**: Compatibilidad mejorada con sintaxis de heredoc alternativa

## 📊 Estadísticas

| Métrica | Valor |
|---------|-------|
| Commits nuevos | 8 |
| Scripts nuevos | 3 |
| Funciones LLM mejoradas | 2 |
| Variables de entorno | 4 |
| Herramientas de diagnóstico | 2 |

## 🚀 Upgrade desde v0.2.0

1. **Pull cambios:**
   ```bash
   git fetch origin && git checkout v0.3.0
   ```

2. **Redeployed (si usa split_portal):**
   ```bash
   bash scripts/setup-topology.sh
   ```

3. **Verificación:**
   ```bash
   bash scripts/llm-status.sh
   bash scripts/mqtt-queue-status.sh
   ```

4. **Configurar dominio classifier (opcional):**
   ```bash
   # Actualizar env vars en k8s deployment
   kubectl set env deployment/ai-analyzer \
     DOMAIN_CLASSIFIER_LLM_MAX_NEW_PER_REQUEST=2 \
     DOMAIN_CLASSIFIER_LLM_TIMEOUT_S=8 \
     DOMAIN_CLASSIFIER_LLM_N_PREDICT=48 \
     DOMAIN_CLASSIFIER_LLM_MAX_QUEUE_SIZE=4
   ```

## 📝 Notas

- Todos los scripts heredados continúan funcionando sin cambios
- nftables migration es automatizada en `setup-openwrt.sh` y reparable con `openwrt-core-access-repair.sh`
- Budget system es **no destructivo**: si se alcanza presupuesto simplemente se deja de llamar al LLM

---

# Release v0.2.0

## Resumen

Release de producción con refactorización de portal node, soporte para topologías múltiples y mejora significativa de seguridad y monitoreo. Portal ahora separa frontend y backend para mejor escalabilidad. Stack IA completamente funcional con automatización de políticas.

## Cambios Principales

### 🎯 Portal Node - Arquitectura Dual

El portal captive se despliega ahora en dos contenedores separados para mejor gestión:

**Frontend (nginx)** en Raspi3B:
- Sirve HTML estático del portal (`portal.html`, `services.html`, `blocked.html`, `people.html`)
- Proxy transparente a backend local para `/api/register/*`
- Proxy a AI node para dashboards (`/dashboard`, `/terminal`, `/rulez`)
- Puerto 80 con host network

**Backend (Python)** en Raspi3B:
- Maneja registro de clientes/invitados (`/api/register/client`, `/api/register/guest`)
- Dashboard de personas (`/api/people/dashboard`)
- Persistencia en SQLite local (`/data/lentium.db`)
- SSH remoto al router OpenWrt para autorizar clientes en nftables

```bash
# Deploy portal node completo
./scripts/portal-node-deploy.sh

# Ver estado
./scripts/portal-node-status.sh
```

### 🗺️ Topologías Múltiples

Ahora soportamos dos topologías de despliegue definidas en `scripts/lib/topology.env`:

**legacy** (por defecto):
```
OpenWrt → Sensor(Raspi3B#1) → IA+Portal(Raspi4B)
```
Portal centralizado en Raspi4B vía k3s.

**split_portal** (nueva):
```
OpenWrt → Portal(Raspi3B#2) + Sensor(Raspi3B#1) → IA(Raspi4B)
```
Portal distribuido en Raspi3B#2, IA separada en Raspi4B.

Cambiar topología:
```bash
export TOPOLOGY=split_portal
./scripts/setup-topology.sh
./scripts/topology-switch.sh
./scripts/verify-topology.sh
```

### 🧠 Stack IA Mejorado

Nuevos dashboards operacionales:

- **`/people`**: Vista HTML que consulta AI node, muestra registros y análisis
- **`/dashboard`**: Análisis de tráfico con gráficos de riesgo
- **`/terminal`**: Log en vivo con SSE desde worker thread
- **`/rulez`**: Editor visual de reglas/prompts IA en SQLite

Automatización:
- Router MCP integrado: IA puede autorizar/bloquear clientes automáticamente
- Reglas configurables por tráfico sospechoso, escaneos, patrones

```bash
# Controlar llama.cpp (apagar para ahorrar CPU)
./scripts/llm-control.sh off
./scripts/llm-control.sh on
```

### 🔒 Seguridad y Configuración

**nftables en OpenWrt**:
- Tabla `ip captive` con reglas por subred (no interfaz)
- Set `allowed_clients` con timeout 120m para WiFi
- Permanentes (timeout 0s): admin, Raspi4B, Raspi3B, portal node
- Recarga limpia sin conextrack dirty

**DHCP/DNS**:
- Lease time: 120 minutos (coincide con timeout de portal)
- Option 6: DNS del router (192.168.1.1)
- Option 114: URL del portal (RFC 7710)
- Dominio fallback: `captive.localhost.com`

**SSH Automation**:
- `/opt/keys/captive-portal` (Raspi4B/3B → OpenWrt)
- `/opt/keys/sensor` (Raspi3B → OpenWrt)
- Autenticación sin contraseña con ed25519

### 📊 Monitoreo

Scripts de diagnóstico:

```bash
# Estado general
./scripts/sensor-status.sh
./scripts/raspi-k8s-status.sh
./scripts/portal-node-status.sh

# Logs de componentes
./scripts/raspi-logs.sh <componente>

# Validación E2E
./scripts/verify-topology.sh
```

Logs centralizados en `/var/log/demo-openwrt/<componente>` con fallback a `/tmp`.

## Instalación / Actualización

### Fresh Install (legacy)

```bash
# Router OpenWrt
./scripts/setup-openwrt.sh
./scripts/setup-openwrt-wifi-uplink.sh

# Raspi3B (sensor)
./scripts/setup-sensor-raspi3b.sh

# Raspi4B (AI + Portal)
./scripts/setup-raspi4b-all.sh
```

### Fresh Install (split_portal)

```bash
export TOPOLOGY=split_portal
./scripts/setup-topology.sh
```

### Actualizar desde v0.1.0

```bash
# Pull cambios
git pull origin main

# Deploy nuevas imágenes
./scripts/setup-raspi4b-portals.sh
./scripts/setup-raspi4b-ai-analyzer.sh

# Si usas split_portal
./scripts/setup-portal-raspi3b.sh
./scripts/portal-node-deploy.sh
```

## Requisitos

| Componente | Mínimo | Recomendado |
|---|---|---|
| Raspi4B RAM | 2GB | 4GB |
| Raspi3B RAM | 1GB | 1GB |
| Storage Raspi4B | 16GB | 32GB |
| Storage Raspi3B | 8GB | 16GB |
| Internet | 5 Mbps | 10+ Mbps |

## Notas Operativas

### ⚠️ Importante

1. **Laptop admin (192.168.1.113) NUNCA debe ser bloqueada**. Está en lista permanente en nftables.
2. **SSH en OpenWrt**: Puerto 22, usuario `root`, autenticación con ED25519
3. **k3s en Raspi4B**: Solo namespace `default`, Traefik 3.6.10 expone puertos 80/443
4. **LLM**: TinyLlama 1.1B demanda ~500MB RAM, puede apagarse con `./scripts/llm-control.sh off`

### Base de Datos

SQLite con TablasCríticas:
- `batches`: Estado de análisis de tráfico (pending/processing/done/error)
- `analyses`: Resultados con riesgo detectado
- Ubicaciones: 
  - Raspi4B: `/opt/analyzer/data/sensor.db` (k3s hostPath)
  - Raspi3B (split_portal): `/opt/captive-portal/lentium-data/lentium.db`

### Credenciales

Demo con autenticación mínima (`allow_anonymous=true` en MQTT). Para producción:
- Agregar usuarios MQTT con contraseña
- Usar certificados SSL/TLS
- Whitelist de IPs en OpenWrt

## Problemas Conocidos

### Portal no responde directamente
- Verificar que nftables no esté bloqueando: `nft list table ip captive`
- Ver logs: `/var/log/demo-openwrt/portal-node`

### IA no analiza tráfico
- Revisar llama.cpp: `./scripts/llm-control.sh status`
- Ver MQTT: `mosquitto_sub -t 'rafexpi/#' -v`
- SQLite: `sqlite3 /opt/analyzer/data/sensor.db "SELECT * FROM batches ORDER BY created LIMIT 5;"`

### Raspi3B sensor no publica
- SSH: `ssh root@192.168.1.181 "systemctl status network-sensor"`
- Logs: `ssh root@192.168.1.181 "tail -f /var/log/demo-openwrt/sensor"`
- Comprobar MQTT: `mosquitto_pub -h 192.168.1.167 -t test -m ok`

## Compatibilidad

- **OpenWrt**: 25.12.2+ (ath79 mips_24kc)
- **k3s**: v1.34.6+
- **Python**: 3.13.0+ (alpine)
- **DietPi**: Bullseye/Bookworm arm64/arm32v7
- **Podman**: 5.0+
- **llama.cpp**: b8849+ (GGUF format)

## Roadmap v0.3.0

- [ ] Dashboard web centralizado (no SSE, WebSocket)
- [ ] Persistencia de configuración en etcd (k3s native)
- [ ] Multi-portal: Raspi3B#2 como respaldo activo
- [ ] Autenticación OAUTH2 en portal
- [ ] Exportación de análisis (Prometheus, InfluxDB)
- [ ] Mobile app para captura de evidencia de seguridad

## Contribución

Reportar bugs o sugerencias en GitHub Issues. Seguir [Conventional Commits](https://www.conventionalcommits.org/) en PRs.

## Licencia

Ver [LICENSE](LICENSE)

---

**Publicado**: 22 de Abril de 2026  
**Tag**: `v0.2.0`  
**Rama**: `main`
