# Changelog

Todos los cambios significativos de este proyecto están documentados en este archivo.

## [0.3.0] - 2026-04-24

### ✨ Características

- **Herramientas de Diagnóstico**: 
  - `llm-status.sh` - Inspección detallada de llama-server (PID, modelo cargado, health check HTTP)
  - `mqtt-queue-status.sh` - Diagnóstico integral de broker Mosquitto y cola IA (con modo `--watch`)
- **Bundle AI Stack Modular**: `setup-raspi4b-ai-stack.sh` para instalar solo stack IA sin portales
- **Soporte Modelos Personalizados**: Flag `--model-path=/ruta/modelo.gguf` en `setup-raspi4b-llm.sh`
- **Control Inteligente de LLM**:
  - Sistema de budgeting en clasificador de dominios
  - Safe-mode adaptativo basado en tamaño de cola
  - Parámetros configurables: timeout, n_predict, temperature, top_p
  - Métricas expuestas en `/api/stats`

### 🔧 Cambios Técnicos

- **OpenWrt**: Migración de nftables a `/etc/captive-portal.nft` (fuera de `/etc/nftables.d` para evitar parseo automático de fw4)
- **Búsqueda de Modelos**: Patrones más flexibles y fallback robusto con `find()` 
- **LLM**: Parámetros en `call_llama()` ahora son configurables (timeout_s, n_predict, temperature, top_p)
- **Portabilidad**: Mejoras en compatibilidad de Python y manejo de redirecciones en scripts

### 🐛 Correcciones

- **openwrt-core-access-repair.sh**: Manejo mejorado de errores en firewall restart (tolera warnings de tabla inet fw4)
- **mqtt-queue-status.sh**: Compatibilidad con shells restrictivos (migración de stdin a variables de entorno)
- **Dominio Classifier**: Refresco selectivo de categorías cached como "otros" solo si vienen de reglas

### 📦 Variables de Entorno Nuevas

- `DOMAIN_CLASSIFIER_LLM_MAX_NEW_PER_REQUEST` (default: 2)
- `DOMAIN_CLASSIFIER_LLM_TIMEOUT_S` (default: 8)
- `DOMAIN_CLASSIFIER_LLM_N_PREDICT` (default: 48)
- `DOMAIN_CLASSIFIER_LLM_MAX_QUEUE_SIZE` (default: 4)

## [0.2.0] - 2026-04-22

### ✨ Características

- **Portal Node Separado**: Despliegue de frontend (nginx) y backend (Python) en contenedores independientes en Raspi3B
- **people.html**: Nueva vista HTML que funciona como dashboard local consultando datos del AI node
- **Topología Split Portal**: Soporte completo para topología alternativa (OpenWrt → Portal(3B#2) + Sensor(3B#1) → AI(4B))
- **Modularización de Setup**: Scripts individuales para instalación de componentes en Raspi4B
  - `setup-raspi4b-mosquitto.sh`
  - `setup-raspi4b-llm.sh`
  - `setup-raspi4b-ai-analyzer.sh`
  - `setup-raspi4b-portals.sh`
- **Automatización de Políticas IA**: Router MCP para aplicar acciones de seguridad desde análisis de tráfico
- **Dashboards Operacionales**: 
  - Dashboard de personas registradas/conectadas (`/people`)
  - Dashboard de análisis de tráfico y riesgo (`/dashboard`)
  - Terminal en vivo con logs de análisis (`/terminal`)
  - Editor de reglas/prompts IA (`/rulez`)
- **Deteción Mejorada de Captive Portal**: 
  - Dominio fallback: `captive.localhost.com`
  - DHCP option 114 (RFC 7710): `http://192.168.1.167/portal`
  - Bloqueo inteligente por subred en nftables

### 🐛 Correcciones

- **Portal Node**: 
  - Readiness check para backend antes de desplegar frontend
  - Diagnóstico mejorado con inspección de contenedor si falla
- **OpenWrt**: Forzar configuración de dnsmasq para captive portal correctamente
- **Setup**: Cache APT en Raspi4B para acelerar instalación
- **Portal Lentium**: Geolocalización de direcciones limitada a México en búsquedas
- **Deploy**: Verificación de rollout activo antes de proceder

### 🔧 Cambios Técnicos

- **nftables**: Reglas por subred `ip saddr 192.168.1.0/24` en lugar de interfaz
- **MQTT**: Queue persistente en SQLite con worker thread único (sin race conditions)
- **llama.cpp**: Configuración crítica con ctx-size=4096 y --parallel=1
- **k3s**: Traefik con `externalTrafficPolicy: Local` para preservar IP real del cliente
- **Docker/Podman**: Imágenes base `python:3.13-alpine3.23` para consistencia
- **Logging**: Centralización en `/var/log/demo-openwrt/<componente>` con fallback a `/tmp`

### 📦 Dependencias

- k3s v1.34.6
- Traefik 3.6.10
- llama.cpp b8849 (TinyLlama 1.1B-Chat Q4_K_M)
- Mosquitto MQTT 2.0.x
- tshark (Wireshark)
- Python 3.13-alpine3.23

### 🚀 Despliegue

Topologías soportadas:
- **legacy**: OpenWrt → Sensor(3B#1) → IA+Portal(4B)
- **split_portal**: OpenWrt → Portal(3B#2) + Sensor(3B#1) → IA(4B)

Scripts de orquestación:
- `setup-topology.sh`: Despliegue completo por topología
- `topology-switch.sh`: Cambiar between topologías
- `verify-topology.sh`: Validación E2E

### 📝 Notas de Desmesurador

- Mantener permanentes (timeout 0s): admin (192.168.1.113), RafexPi4B (192.168.1.167), RafexPi3B (192.168.1.181)
- DHCP lease time: 120 minutos para clientes WiFi
- SSH keys para automatización:
  - `/opt/keys/captive-portal` (RafexPi4B → OpenWrt)
  - `/opt/keys/sensor` (RafexPi3B → OpenWrt)

---

## [0.1.0] - 2026-03-15

### ✨ Características Iniciales

- Captive portal funcional extremo a extremo
- Stack IA con TinyLlama local y llama.cpp
- Sensor de tráfico con tshark en Raspi3B
- Integración OpenWrt con nftables
- MQTT para comunicación sensor-analyzer
- SQLite para persistencia de análisis
- Dashboard básico de análisis

### 🔧 Componentes Base

- OpenWrt 25.12.2 con ath79/mips_24kc
- DietPi en Raspi3B y Raspi4B
- k3s v1.34.6 en Raspi4B
- Mosquitto MQTT broker
- Python 3.13 para backends
- nginx para frontend

---

## Formato de Commits

Este proyecto sigue [Conventional Commits](https://www.conventionalcommits.org/):

- `feat:` Nueva funcionalidad
- `fix:` Corrección de bug
- `docs:` Solo cambios en documentación
- `style:` Cambios de formato (sin lógica)
- `refactor:` Cambio de código sin cambiar funcionalidad
- `perf:` Mejora de rendimiento
- `test:` Agregar/actualizar tests
- `chore:` Cambios de build, deps, herramientas

Scope opcional: `feat(portal-node):`, `fix(ai):`, etc.

Ejemplo:
```
feat(portal-node): agregar backend separado para registro

- Frontend nginx sigue en Raspi3B
- Backend Python en puerto 8080 maneja /api/register/*
- Mejor scalability y separación de responsabilidades
```
