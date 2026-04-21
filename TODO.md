# TODO — PoC Captive Portal + IA Local

## 🔴 Bloqueante — necesario para el flujo completo

### Integración LLM
- [ ] Instalar llama.cpp en la Pi
- [ ] Seleccionar modelo (recomendado: Qwen2.5-0.5B-Instruct o similar para arm64)
- [ ] Definir el rol del LLM en el portal:
  - Opción A: chatbot en la página del portal (educativo)
  - Opción B: análisis de tráfico de metadatos capturados
  - Opción C: ambos
- [ ] Integrar endpoint del LLM en el backend Python
- [ ] Actualizar el HTML del portal para incluir la interfaz con el LLM

---

## 🟡 Importante — mejoras funcionales

### Backend Python
- [ ] Manejar el caso de múltiples IPs en conntrack para el mismo cliente
  (actualmente toma `head -1`, puede ser ambiguo con conexiones simultáneas)
- [ ] Agregar endpoint `GET /clients` que devuelva el set `allowed_clients` actual
- [ ] Timeout configurable via variable de entorno (actualmente hardcodeado en 10s)
- [ ] Limpiar entrada conntrack del cliente tras autorizar (evitar sesiones colgadas)

### k3s / Kubernetes
- [ ] Aplicar y eliminar `k8s/cleanup-legacy.yaml` (borra ConfigMap `captive-portal-html`)
  ```bash
  kubectl delete -f k8s/cleanup-legacy.yaml
  git rm k8s/cleanup-legacy.yaml
  ```
- [ ] Agregar `livenessProbe` y `readinessProbe` al contenedor backend
  ```yaml
  livenessProbe:
    httpGet:
      path: /health
      port: 8080
    initialDelaySeconds: 5
    periodSeconds: 10
  ```
- [ ] Configurar k3s para arrancar automáticamente en DietPi (sin systemd)

### nginx
- [ ] Agregar `location /health` propio en nginx (actualmente redirige al portal)
  ```nginx
  location /health {
      return 200 '{"status":"ok"}';
      add_header Content-Type application/json;
  }
  ```
- [ ] Añadir más rutas de detección de captive portal (Windows `/ncsi.txt`, etc.)

---

## 🟢 Deseable — funcionalidades adicionales

### Portal web
- [ ] Mejorar el diseño del portal (actualmente funcional pero básico)
- [ ] Añadir contador de usuarios conectados en tiempo real
- [ ] Página de información educativa sobre seguridad en redes WiFi públicas
- [ ] Soporte para HTTPS (certificado autofirmado vía Traefik)

### Operacional
- [ ] Script de arranque automático de k3s en DietPi
- [ ] Configurar k3s para sobrevivir reinicios (actualmente manual)
- [ ] Rotación de logs del backend Python (actualmente va a stdout)
- [ ] Monitoreo básico: alertar si el pod cae o el router pierde conectividad

### Documentación
- [ ] Agregar diagrama de secuencia del flujo completo (cliente → aceptar → navegar)
- [ ] Documentar el proceso de configuración de la presentación en vivo
- [ ] README.md principal con quickstart de 5 minutos

---

## ✅ Completado

### Flujo core — funciona end-to-end
- [x] Cliente WiFi ve el portal captivo al intentar navegar
- [x] Al aceptar el portal, el cliente obtiene acceso a internet
- [x] Sin aceptar, el forward está bloqueado
- [x] Tras 30 minutos, el cliente vuelve al portal automáticamente

### Correcciones críticas de IP real del cliente
- [x] `externalTrafficPolicy: Local` en Traefik — preserva IP real del cliente (fix SNAT de kube-proxy)
- [x] nginx: `set_real_ip_from 10.42.0.0/16` + `real_ip_header X-Forwarded-For` → `$remote_addr` = IP real
- [x] nginx: `proxy_set_header X-Real-IP $remote_addr` al backend
- [x] Backend Python: prioriza `X-Real-IP` header; fallback a `X-Forwarded-For`; fallback a conntrack

### Correcciones nftables
- [x] Reglas usan `ip saddr 192.168.1.0/24` (subred) en lugar de `iifname "phy0-ap0"`
  — fix crítico: con bridge br-lan, iifname nunca hacía match
- [x] `timeout 0` → `timeout 0s` (sintaxis correcta en esta versión de nftables)
- [x] `router_add_ip` en common.sh aplica `timeout 0s` automáticamente para admin y portal
- [x] setup-openwrt.sh elimina la tabla antes del dry-run (fix "File exists" en nft -c)
- [x] Admin y portal siempre permanentes (timeout 0s), clientes con timeout 30m

### DHCP y lease time
- [x] DHCP lease time = 30 minutos en OpenWrt (UCI `dhcp.lan.leasetime=30m`)
- [x] nftables set `allowed_clients` con `timeout 30m` — autorizaciones expiran solas
- [x] Admin (192.168.1.113) y portal (192.168.1.167) con `timeout 0s` (nunca expiran)
- [x] `openwrt-allow-client.sh` soporta `--permanent` para autorizar sin expiración
- [x] `openwrt-list-clients.sh` muestra tiempo restante de cada autorización
- [x] Reserva DHCP permanente para la Pi (`openwrt-reserve-raspi.sh --auto`)

### Backend y stack k8s
- [x] Pod captive-portal 2/2 Running en k3s (nginx + backend Python sidecar)
- [x] Traefik 3.6.10 expone el portal en 192.168.1.167:80
- [x] Backend Python con logging detallado (headers, tiempos, IP, SSH)
- [x] `NFT_SET = "ip captive allowed_clients"` (corregido de `captive_fw`)
- [x] `proxy_pass http://127.0.0.1:8080` (fix IPv6 `localhost` en Alpine)
- [x] Llave SSH ed25519 generada y registrada en el router
- [x] HelmChartConfig Traefik con `externalTrafficPolicy:Local` + `forwardedHeaders`
- [x] YAMLs k8s sincronizados con la realidad del cluster

### Scripts
- [x] setup-raspi, setup-openwrt, raspi-deploy, raspi-logs, raspi-k8s-status
- [x] openwrt-allow/block/list/flush-clients, openwrt-reset-firewall
- [x] openwrt-reserve-raspi (modo --auto detecta MAC local)
- [x] lib/common.sh con LAN_SUBNET y router_add_ip con timeout 0s para admin/portal

### Documentación
- [x] AGENTS.md actualizado con estado real y notas de diseño
- [x] docs/arquitectura.md con explicación de por qué subred en lugar de interfaz
- [x] docs/setup.md con pasos completos incluyendo reserve-raspi y Traefik Local
- [x] docs/scripts.md con referencia de todos los scripts
- [x] docs/troubleshooting.md con todos los problemas encontrados y sus fixes
