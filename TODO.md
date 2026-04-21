# TODO — PoC Captive Portal + IA Local

## 🔴 Bloqueante — necesario para el flujo completo

### Router OpenWrt
- [ ] Ejecutar `bash scripts/openwrt-reserve-raspi.sh` para fijar IP 192.168.1.167 permanentemente en DHCP
- [ ] Ejecutar `bash scripts/setup-openwrt.sh` desde la Pi
  - Configura nftables (tabla `ip captive`, redirección HTTP, bloqueo de forward)
  - Configura dnsmasq (dominios de detección → 192.168.1.167)
  - Persiste reglas en `/etc/nftables.d/captive-portal.nft`
- [ ] Validar con `bash scripts/raspi-logs.sh --test` (Tests 3, 4 y 5)
- [ ] Prueba real: conectar dispositivo al WiFi "INFINITUM MOVIL" y verificar redirección

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
  k3s kubectl delete -f k8s/cleanup-legacy.yaml
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
  (actualmente hay que arrancarlo manualmente o via `raspi-k8s-status.sh`)

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

### Integración LLM
- [ ] Instalar llama.cpp en la Pi
- [ ] Seleccionar modelo (recomendado: Qwen2.5-0.5B-Instruct o similar para arm64)
- [ ] Definir el rol del LLM en el portal:
  - Opción A: chatbot en la página del portal (educativo)
  - Opción B: análisis de tráfico de metadatos capturados
  - Opción C: ambos
- [ ] Integrar endpoint del LLM en el backend Python
- [ ] Actualizar el HTML del portal para incluir la interfaz con el LLM

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

- [x] DHCP lease time = 30 minutos en OpenWrt (UCI `dhcp.lan.leasetime=30m`)
- [x] nftables set `allowed_clients` con `timeout 30m` — autorizaciones expiran solas
- [x] Admin (192.168.1.128) y portal (192.168.1.167) con `timeout 0` (nunca expiran)
- [x] `openwrt-allow-client.sh` soporta `--permanent` para autorizar sin expiración
- [x] `openwrt-list-clients.sh` muestra tiempo restante de cada autorización
- [x] Script `openwrt-flush-clients.sh` para resetear clientes al portal (conserva admin+portal permanentes)
- [x] Script `openwrt-reserve-raspi.sh` para reserva DHCP permanente de la Pi (leasetime=infinite, detecta MAC automáticamente)

- [x] Pod captive-portal 2/2 Running en k3s (nginx + backend Python sidecar)
- [x] Traefik 3.6.10 expone el portal en 192.168.1.167:80
- [x] Backend Python con SSH+conntrack para detección de IP
- [x] Backend Python con SSH+nft para autorización de clientes
- [x] Fix: `NFT_SET = "ip captive allowed_clients"` (era `captive_fw`)
- [x] Fix: `proxy_pass http://127.0.0.1:8080` (fix IPv6 `localhost` en Alpine)
- [x] Llave SSH ed25519 generada y registrada en el router
- [x] ConfigMap nginx con proxy_pass, HTML del portal y página de aceptado
- [x] HelmChartConfig Traefik con forwardedHeaders para IP real del cliente
- [x] YAMLs k8s sincronizados con la realidad del cluster
- [x] Scripts: setup-raspi, setup-openwrt, raspi-deploy, raspi-logs, raspi-k8s-status
- [x] Scripts: openwrt-allow/block/list-clients, openwrt-reset-firewall
- [x] Documentación: arquitectura, setup, scripts, troubleshooting
