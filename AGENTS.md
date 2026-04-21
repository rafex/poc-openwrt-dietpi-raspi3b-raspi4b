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
              ├── k3s v1.34.6+k3s1
              │   ├── Traefik 3.6.10 (LoadBalancer :80/:443)
              │   └── Pod captive-portal (2/2 Running)
              │       ├── [portal]  nginx:alpine :80
              │       └── [backend] captive-backend:latest :8080
              ├── /opt/keys/captive-portal (llave SSH ed25519)
              └── llama.cpp (pendiente)
```

## Dispositivos

| Dispositivo | IP | OS | Acceso |
|---|---|---|---|
| Router OpenWrt | 192.168.1.1 | OpenWrt 25.12.2 (ath79/mips_24kc) | SSH root, Dropbear |
| Raspberry Pi 4 (RafexPi) | 192.168.1.167 | DietPi Debian trixie arm64 | SSH, k3s v1.34.6 |
| Laptop admin | 192.168.1.128 | — | **NUNCA bloquear esta IP** |

## Repositorio

```
/opt/repository/poc-openwrt-dietpi-raspi3b-raspi4b/
├── backend/captive-portal/
│   ├── backend.py          # Servidor HTTP Python :8080
│   │                       # NFT_SET = "ip captive allowed_clients"
│   └── Dockerfile          # python:3.13-alpine3.23 + openssh-client
├── k8s/
│   ├── captive-portal-configmap.yaml   # nginx.conf + HTML
│   ├── captive-portal-deployment.yaml  # nginx + backend sidecar
│   ├── captive-portal-svc.yaml         # ClusterIP 80+8080
│   ├── captive-portal-ingress.yaml     # Traefik → :80
│   ├── traefik-helmchartconfig.yaml    # forwardedHeaders insecure
│   └── cleanup-legacy.yaml             # elimina ConfigMap huérfano
├── scripts/
│   ├── lib/common.sh                   # SSH helpers, validación IP
│   ├── setup-raspi.sh                  # instala desde cero la Pi
│   ├── setup-openwrt.sh                # configura el router
│   ├── raspi-deploy.sh                 # actualiza k3s
│   ├── raspi-logs.sh                   # logs + tests funcionales
│   ├── raspi-k8s-status.sh             # diagnóstico completo → output/
│   ├── openwrt-allow-client.sh         # autoriza IP en nftables
│   ├── openwrt-block-client.sh         # bloquea IP en nftables
│   ├── openwrt-list-clients.sh         # lista estado de clientes
│   └── openwrt-reset-firewall.sh       # emergencia: resetea nftables
├── docs/
│   ├── arquitectura.md
│   ├── setup.md
│   ├── scripts.md
│   └── troubleshooting.md
├── output/                             # reportes raspi-k8s-status.sh
└── TODO.md
```

## Estado actual

### Pi / k3s ✅
- [x] k3s v1.34.6+k3s1 instalado y corriendo
- [x] Traefik 3.6.10 expone el portal en puerto 80 en 192.168.1.167
- [x] Pod captive-portal 2/2 Running (nginx sidecar + backend Python)
- [x] Backend Python detecta IP del cliente via SSH+conntrack en OpenWrt
- [x] Backend autoriza clientes via SSH+nft en OpenWrt
- [x] `NFT_SET = "ip captive allowed_clients"` (corregido de `captive_fw`)
- [x] `proxy_pass http://127.0.0.1:8080` (fix IPv6 localhost en Alpine)
- [x] Llave SSH en `/opt/keys/captive-portal` (ed25519)
- [x] ConfigMap activo: `captive-portal-nginx-conf` con nginx.conf + HTML + proxy_pass
- [x] HelmChartConfig Traefik: forwardedHeaders.insecure + trustedIPs=0.0.0.0/0
- [x] SSH desde el backend al router: funciona (llave registrada en router)

### Router OpenWrt ⚠️
- [x] Llave SSH de la Pi registrada en `/etc/dropbear/authorized_keys`
- [ ] nftables: tabla `ip captive` con reglas de redirección y bloqueo
- [ ] dnsmasq: dominios de detección de captive portal → 192.168.1.167
- [ ] Reglas persistentes en `/etc/nftables.d/captive-portal.nft`
- **Pendiente: `bash scripts/setup-openwrt.sh`**

### Integración LLM ❌
- [ ] llama.cpp instalado en la Pi
- [ ] Integración del LLM con el captive portal

## Llave SSH

- Ubicación en Pi: `/opt/keys/captive-portal` (privada), `/opt/keys/captive-portal.pub`
- Montada en el pod via `hostPath`
- Registrada en `/etc/dropbear/authorized_keys` del router

```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL238prLPDMktu1deXGAFjQ5npVX1bQm+9Jugeiv9Uep captive-portal@rafexpi
```

## Notas importantes para el agente

### nftables
- Tabla: `ip captive` — set: `allowed_clients`
- **No usar `iptables`** — usar `nft` exclusivamente (OpenWrt 25.x)
- `priority filter - 1` en `forward_captive` para evaluar antes que fw4
- Limpiar conntrack al activar reglas: `conntrack -F`

### nginx + backend sidecar
- nginx y backend corren en el **mismo pod** — comparten red del pod
- `proxy_pass http://127.0.0.1:8080` — **no `localhost`** (se resuelve a `::1` en Alpine)
- Backend escucha en `0.0.0.0:8080` (solo IPv4)

### OpenWrt
- **No usar `systemctl`** — usar `/etc/init.d/`
- Overlay: ~840KB — no instalar paquetes innecesarios
- Dropbear: opciones SSH básicas únicamente

### Raspberry Pi (DietPi)
- **No usar `systemctl` directamente** — DietPi no usa systemd como PID 1
- `podman build --runtime=runc --network=host`
- `podman save | k3s ctr images import -`
- Imagen en containerd: `localhost/captive-backend:latest`

### Regla de oro
**Siempre agregar `192.168.1.128` al set `allowed_clients` ANTES de activar cualquier regla de bloqueo WiFi.**
