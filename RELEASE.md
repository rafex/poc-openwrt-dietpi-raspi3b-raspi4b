# Release v0.2.0

**22 de Abril de 2026**

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
