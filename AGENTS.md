# AGENTS.md — PoC Captive Portal + IA Local

## Contexto del proyecto

PoC educativa de seguridad en redes públicas que combina:
- Captive portal en Raspberry Pi 4 (RafexPi)
- LLM local con llama.cpp (pendiente)
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
              │   │     externalTrafficPolicy: Local  ← preserva IP real del cliente
              │   └── Pod captive-portal (2/2 Running)
              │       ├── [portal]  nginx:alpine :80
              │       │     set_real_ip_from 10.42.0.0/16 + real_ip_header X-Forwarded-For
              │       └── [backend] captive-backend:latest :8080
              ├── /opt/keys/captive-portal (llave SSH ed25519)
              └── llama.cpp (pendiente)
```

## Dispositivos

| Dispositivo | IP | OS | Acceso |
|---|---|---|---|
| Router OpenWrt | 192.168.1.1 | OpenWrt 25.12.2 (ath79/mips_24kc) | SSH root, Dropbear |
| Raspberry Pi 4 (RafexPi) | 192.168.1.167 | DietPi Debian trixie arm64 | SSH, k3s v1.34.6 |
| Laptop admin | 192.168.1.113 | — | **NUNCA bloquear esta IP** |

## Repositorio

```
/opt/repository/poc-openwrt-dietpi-raspi3b-raspi4b/
├── backend/captive-portal/
│   ├── backend.py          # Servidor HTTP Python :8080
│   │                       # Prioriza X-Real-IP header; fallback a conntrack
│   └── Dockerfile          # python:3.13-alpine3.23 + openssh-client
├── k8s/
│   ├── captive-portal-configmap.yaml   # nginx.conf (realip) + HTML
│   ├── captive-portal-deployment.yaml  # nginx + backend sidecar
│   ├── captive-portal-svc.yaml         # ClusterIP 80+8080
│   ├── captive-portal-ingress.yaml     # Traefik → :80
│   ├── traefik-helmchartconfig.yaml    # externalTrafficPolicy:Local + forwardedHeaders
│   └── cleanup-legacy.yaml             # elimina ConfigMap huérfano
├── scripts/
│   ├── lib/common.sh                   # SSH helpers, validación IP, LAN_SUBNET
│   ├── setup-raspi.sh                  # instala desde cero la Pi
│   ├── setup-openwrt.sh                # configura el router (nftables + dnsmasq)
│   ├── raspi-deploy.sh                 # actualiza k3s
│   ├── raspi-logs.sh                   # logs + tests funcionales
│   ├── raspi-k8s-status.sh             # diagnóstico completo → output/
│   ├── openwrt-allow-client.sh         # autoriza IP en nftables
│   ├── openwrt-block-client.sh         # bloquea IP en nftables
│   ├── openwrt-list-clients.sh         # lista estado de clientes
│   ├── openwrt-flush-clients.sh        # resetea clientes (conserva admin+portal)
│   ├── openwrt-reserve-raspi.sh        # reserva DHCP permanente para la Pi
│   └── openwrt-reset-firewall.sh       # emergencia: elimina tabla nftables
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
- [x] `externalTrafficPolicy: Local` en el Service de Traefik — preserva IP real del cliente
- [x] Pod captive-portal 2/2 Running (nginx sidecar + backend Python)
- [x] nginx con `set_real_ip_from 10.42.0.0/16` + `real_ip_header X-Forwarded-For`
- [x] Backend Python: prioriza `X-Real-IP` header; fallback a conntrack
- [x] Backend autoriza clientes via SSH+nft en OpenWrt
- [x] `NFT_SET = "ip captive allowed_clients"`
- [x] `proxy_pass http://127.0.0.1:8080` (fix IPv6 localhost en Alpine)
- [x] Llave SSH en `/opt/keys/captive-portal` (ed25519)
- [x] HelmChartConfig Traefik: `externalTrafficPolicy:Local` + `forwardedHeaders.insecure`
- [x] SSH desde el backend al router: funciona

### Router OpenWrt ✅
- [x] Llave SSH de la Pi registrada en `/etc/dropbear/authorized_keys`
- [x] nftables: tabla `ip captive` con reglas por subred (`ip saddr 192.168.1.0/24`)
- [x] dnsmasq: dominios de detección de captive portal → 192.168.1.167
- [x] DHCP lease time: 30 minutos (UCI `dhcp.lan.leasetime=30m`)
- [x] Set `allowed_clients` con `timeout 30m`; admin y portal con `timeout 0s` (permanentes)
- [x] Reglas persistentes en `/etc/nftables.d/captive-portal.nft`
- [x] Reserva DHCP permanente para la Pi (UCI `leasetime=infinite`)

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

### nftables — reglas por subred, no por interfaz
- **Usar `ip saddr 192.168.1.0/24`** — NO `iifname "phy0-ap0"`
- Razón: en OpenWrt los clientes WiFi pasan por `br-lan`; el hook forward ve `br-lan`, no `phy0-ap0`
- Tabla: `ip captive` — set: `allowed_clients`
- `priority filter - 1` en `forward_captive` para evaluar antes que fw4
- Admin y portal con `timeout 0s` (permanentes); clientes con `timeout 30m` (default del set)
- Al recargar reglas: eliminar tabla con `nft delete table ip captive` ANTES del dry-run (`nft -c -f`)
  porque `nft -c` también falla con "File exists" si el set ya existe
- Limpiar conntrack al activar reglas: `conntrack -F`

### Traefik — IP real del cliente
- `externalTrafficPolicy: Local` en el Service — SIN esto kube-proxy hace SNAT y la IP del cliente
  se pierde (aparece `10.42.0.1` en lugar de `192.168.1.X`)
- `forwardedHeaders.insecure` + `trustedIPs=0.0.0.0/0` — Traefik propaga `X-Forwarded-For`

### nginx — extracción de IP real
- `set_real_ip_from 10.42.0.0/16` + `real_ip_header X-Forwarded-For` + `real_ip_recursive on`
- Después de esto `$remote_addr` = IP real del cliente WiFi (192.168.1.X)
- Pasa al backend con `proxy_set_header X-Real-IP $remote_addr`

### nginx + backend sidecar
- nginx y backend corren en el **mismo pod** — comparten red del pod
- `proxy_pass http://127.0.0.1:8080` — **no `localhost`** (se resuelve a `::1` en Alpine)
- Backend escucha en `0.0.0.0:8080` (solo IPv4)

### Backend Python — detección de IP
1. Lee `X-Real-IP` header (puesto por nginx con la IP real del cliente)
2. Fallback: primer elemento de `X-Forwarded-For` que sea `192.168.1.X`
3. Fallback final: consulta conntrack en el router via SSH

### OpenWrt
- **No usar `systemctl`** — usar `/etc/init.d/`
- Overlay: ~840KB — no instalar paquetes innecesarios
- Dropbear: opciones SSH básicas únicamente
- `/etc/dnsmasq.d/` puede no existir — usar `/etc/dnsmasq.conf` con marcadores
- `timeout 0` sin unidad NO es válido en esta versión de nftables — usar `timeout 0s`

### Raspberry Pi (DietPi)
- **No usar `systemctl` directamente** — DietPi no usa systemd como PID 1
- `podman build --runtime=runc --network=host`
- `podman save | k3s ctr images import -`
- Imagen en containerd: `localhost/captive-backend:latest`

### Regla de oro
**Siempre agregar `192.168.1.113` (admin) con `timeout 0s` ANTES de activar cualquier regla de bloqueo.**
`router_add_ip` en `common.sh` hace esto automáticamente para admin y portal.
