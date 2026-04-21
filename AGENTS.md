# AGENTS.md — PoC Captive Portal + IA Local

## Contexto del proyecto

PoC educativa de seguridad en redes públicas que combina:
- Captive portal en Raspberry Pi 4 (RafexPi)
- LLM local con llama.cpp
- Router OpenWrt como gateway WiFi
- k3s como plataforma de despliegue en la Pi

## Arquitectura

```
Internet
    ↓
Router OpenWrt (192.168.1.1)
    ├── WAN: phy1-sta0 → WiFi "netup" (5 GHz)
    └── AP:  phy0-ap0  → WiFi "INFINITUM MOVIL" (2.4 GHz)
                ↓
         Clientes WiFi (192.168.1.x)
                ↓
         Raspberry Pi 4 — RafexPi (192.168.1.167)
              ├── k3s
              │   ├── Traefik (ingress, puerto 80)
              │   └── captive-portal (nginx + backend Python)
              ├── dnsmasq (DNS local)
              └── llama.cpp (LLM local)
```

## Dispositivos

| Dispositivo | IP | OS | Acceso |
|---|---|---|---|
| Router OpenWrt | 192.168.1.1 | OpenWrt 25.12.2 (ath79/mips_24kc) | SSH root, dropbear, sin systemd |
| Raspberry Pi 4 (RafexPi) | 192.168.1.167 | DietPi (Debian trixie, arm64) | SSH, sin systemd como PID 1 |
| Laptop admin | 192.168.1.128 | — | NUNCA bloquear esta IP |

## Repositorio

```
/opt/repository/poc-openwrt-dietpi-raspi3b-raspi4b/
└── backend/
    └── captive-portal/
        ├── backend.py        # Servidor HTTP Python en puerto 8080
        ├── Dockerfile        # python:3.13-alpine3.23 + openssh-client
        └── k8s/
            ├── captive-portal-deployment.yaml
            ├── captive-portal-configmap.yaml
            └── captive-portal-svc.yaml
```

## Estado actual

- [x] nginx eliminado del host, portal corre en k3s
- [x] Traefik expone el portal en puerto 80 en 192.168.1.167
- [x] dnsmasq redirige dominios de detección de captive portal a la Pi
- [x] nftables en OpenWrt redirige HTTP (puerto 80) al portal
- [x] Backend Python detecta IP del cliente via SSH+conntrack en OpenWrt
- [x] Backend autoriza clientes via SSH+nft en OpenWrt
- [ ] Reglas de bloqueo WiFi en OpenWrt (pendiente — router reseteado)
- [ ] Integración con LLM

## Llave SSH

- Ubicación en Pi: `/opt/keys/captive-portal` (privada), `/opt/keys/captive-portal.pub` (pública)
- Montada en el pod via `hostPath`
- Debe estar en `/etc/dropbear/authorized_keys` del router OpenWrt

```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL238prLPDMktu1deXGAFjQ5npVX1bQm+9Jugeiv9Uep captive-portal@rafexpi
```

## Tareas para Claude Code

### Script 1 — `scripts/setup-openwrt.sh`

Script idempotente que configura el router OpenWrt desde cero. Debe ejecutarse via SSH desde la Pi.

**Requisitos:**
- Agregar llave SSH pública al router en `/etc/dropbear/authorized_keys`
- Configurar dnsmasq para redirigir dominios de detección de captive portal a `192.168.1.167`
- Configurar nftables para:
  - Redirigir HTTP (puerto 80) de clientes WiFi al portal
  - Bloquear tráfico de `phy0-ap0` excepto:
    - IP de admin `192.168.1.128` (NUNCA bloquear)
    - Tráfico hacia el portal `192.168.1.167`
    - DHCP (puertos 67/68 UDP)
    - DNS (puerto 53)
  - Agregar/quitar IPs del set `allowed_clients`
- Hacer las reglas persistentes en `/etc/nftables.d/captive-portal.nft` o `/etc/firewall.user`
- **IMPORTANTE:** Siempre agregar `192.168.1.128` al set `allowed_clients` antes de activar bloqueo
- Usar `nft` (no `iptables` — OpenWrt 25.x usa nftables)
- Sin systemd — usar `/etc/init.d/` para servicios

**Consideraciones OpenWrt:**
- El firewall usa tabla `inet fw4` con cadena `forward_lan`
- Las reglas deben insertarse en `inet fw4 forward_lan` para ser evaluadas antes del `accept_to_wan`
- El conntrack acepta conexiones establecidas antes de evaluar forward — considerar limpiar conntrack al activar bloqueo
- Dropbear es el servidor SSH (no openssh)

---

### Script 2 — `scripts/setup-raspi.sh`

Script idempotente que configura la Raspberry Pi 4 desde cero.

**Requisitos:**
- Verificar que k3s está corriendo
- Crear directorio `/opt/keys` si no existe
- Generar llave SSH si no existe en `/opt/keys/captive-portal`
- Aplicar todos los manifiestos de k8s en orden
- Construir y cargar la imagen `captive-backend:latest` en k3s
- Verificar que el portal responde en `http://192.168.1.167`
- Usar `podman build --runtime=runc --network=host` para builds
- Usar `podman save | k3s ctr images import -` para cargar imágenes
- Sin systemd — verificar servicios con `ps aux`

---

### Script 3 — `scripts/openwrt-allow-client.sh <IP>`

Script que autoriza manualmente una IP en OpenWrt.

**Requisitos:**
- Recibe IP como argumento
- Hace SSH al router y agrega la IP al set `allowed_clients`
- Verifica que la IP fue agregada
- Usar llave `/opt/keys/captive-portal`

---

### Script 4 — `scripts/openwrt-block-client.sh <IP>`

Script que bloquea manualmente una IP en OpenWrt.

**Requisitos:**
- Recibe IP como argumento
- Hace SSH al router y elimina la IP del set `allowed_clients`
- Nunca bloquear `192.168.1.128`
- Verificar que la IP fue eliminada

---

### Script 5 — `scripts/openwrt-list-clients.sh`

Lista el estado actual de clientes en OpenWrt.

**Requisitos:**
- Mostrar IPs autorizadas en `allowed_clients`
- Mostrar clientes conectados al WiFi (desde `/tmp/dhcp.leases`)
- Mostrar conexiones activas en conntrack al puerto 80
- Usar llave `/opt/keys/captive-portal`

---

### Script 6 — `scripts/openwrt-reset-firewall.sh`

Resetea las reglas de firewall al estado seguro inicial.

**Requisitos:**
- Eliminar todas las reglas de captive portal de `inet fw4 forward_lan`
- Eliminar tabla `ip captive` (redirección HTTP)
- Mantener `192.168.1.128` siempre con acceso
- NO eliminar la configuración base de OpenWrt (`fw4`)
- Útil para recuperación de emergencia

---

## Notas importantes para el agente

### OpenWrt
- **No usar `iptables`** — usar `nft` exclusivamente
- **No usar `systemctl`** — usar `/etc/init.d/` o `service`
- El router tiene **muy poco espacio** (~840KB overlay) — no instalar paquetes innecesarios
- Dropbear no soporta todos los flags de openssh — usar opciones básicas
- El conntrack es crítico — conexiones `ESTABLISHED` bypasean el forward filter

### Raspberry Pi (DietPi)
- **No usar `systemctl` directamente** — DietPi no usa systemd como PID 1
- Usar `podman` con `--runtime=runc --network=host` para builds
- La imagen en k3s se llama `localhost/captive-backend:latest`
- El Deployment monta `/opt/keys` como `hostPath`
- Traefik 3.6.x — usar `HelmChartConfig` para configuración estática

### Regla de oro
**Siempre agregar `192.168.1.128` al set `allowed_clients` ANTES de activar cualquier regla de bloqueo WiFi.**
