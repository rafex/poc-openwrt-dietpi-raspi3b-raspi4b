# Guía de Setup — Captive Portal PoC

## Prerequisitos

| Componente | Requisito |
|---|---|
| Raspberry Pi 4 | DietPi instalado, conectada a la red LAN del router |
| Router OpenWrt | OpenWrt 25.x, acceso SSH como root |
| Laptop admin | IP 192.168.1.113 en la misma red |
| k3s | Instalado en la Pi (v1.32+) |
| podman | Instalado en la Pi con `--runtime=runc` disponible |

---

## Paso 1 — Clonar el repositorio en la Pi

```bash
mkdir -p /opt/repository
cd /opt/repository
git clone <url-repo> poc-openwrt-dietpi-raspi3b-raspi4b
cd poc-openwrt-dietpi-raspi3b-raspi4b
```

---

## Paso 2 — Reservar la IP de la Pi en el router (1 vez)

Ejecutar **desde la Pi** para que el router siempre le asigne `192.168.1.167`:

```bash
bash scripts/openwrt-reserve-raspi.sh --auto
```

`--auto` detecta la MAC de la Pi automáticamente desde sus interfaces locales.
Crea una reserva UCI con `leasetime=infinite` en el DHCP del router.

> Sin esta reserva, si la Pi se reinicia puede obtener una IP diferente y
> todo el captive portal deja de funcionar.

---

## Paso 3 — Setup inicial de la Pi

Genera la llave SSH, construye la imagen Docker e inicia k3s con todos los manifiestos.

```bash
bash scripts/setup-raspi.sh
```

Qué hace:
- Verifica que k3s está corriendo
- Crea `/opt/keys/` y genera la llave SSH `captive-portal` (ed25519)
- Construye la imagen `captive-backend:latest` con podman
- Importa la imagen en containerd (k3s)
- Aplica los manifiestos k8s en orden
- Verifica que el portal responde en `http://192.168.1.167`

Al terminar muestra la **llave pública** que hay que registrar en el router.

---

## Paso 4 — Setup del router OpenWrt

Ejecutar **desde la Pi** (usa la llave SSH generada en el paso anterior):

```bash
bash scripts/setup-openwrt.sh
```

Qué hace:
- **FASE A:** Agrega la llave pública al router (`/etc/dropbear/authorized_keys`)
- **FASE B:** Configura dnsmasq — dominios de detección → `192.168.1.167`; lease time 30m
- **FASE C:** Crea la tabla nftables `ip captive`:
  - Reglas por subred (`ip saddr 192.168.1.0/24`) — NO por interfaz
  - Redirección HTTP de clientes WiFi al portal
  - Bloqueo de forward excepto admin, portal, DHCP, DNS y clientes autorizados
  - Admin (`192.168.1.113`) y portal (`192.168.1.167`) con `timeout 0s` (permanentes)
  - Clientes autorizados con `timeout 30m` (expiran solos)
- **FASE D:** Persiste las reglas en `/etc/nftables.d/captive-portal.nft`

> ⚠️ **Seguridad**: en caso de quedarse bloqueado del router:
> ```bash
> ssh root@192.168.1.1   # SSH al router no usa el hook forward
> nft delete table ip captive
> ```

---

## Paso 5 — Verificar funcionamiento

```bash
# Tests funcionales completos
bash scripts/raspi-logs.sh --test
```

| Test | Qué verifica |
|---|---|
| 1 | HTTP: `/portal` → 200, `/accepted` → 200, `/` → 302 |
| 2 | Backend Python `:8080/health` dentro del pod |
| 3 | SSH desde el backend al router |
| 4 | Tabla `ip captive` + set `allowed_clients` en nftables |
| 5 | conntrack accesible en el router |

---

## Paso 6 — Prueba real con dispositivo WiFi

1. Conectar el celular al WiFi "INFINITUM MOVIL"
2. Abrir URL HTTP: `http://neverssl.com` o `http://example.com`
3. El router debe redirigir al portal: `http://192.168.1.167/portal`
4. Sin aceptar: no hay internet
5. Aceptar: navegar libremente durante 30 minutos
6. Verificar desde la Pi:

```bash
bash scripts/openwrt-list-clients.sh
```

> ⚠️ Los navegadores modernos abren HTTPS por defecto. La detección automática
> de captive portal del SO (Android/iOS) usa HTTP — eso sí dispara el portal.

---

## Flujo de actualización

Cuando se modifica `backend.py` o los manifiestos k8s:

```bash
# Rebuild + apply + verify
bash scripts/raspi-deploy.sh

# Solo cambió el ConfigMap (HTML o nginx config) — sin rebuild
bash scripts/raspi-deploy.sh --no-build

# Solo rebuild de la imagen — sin apply
bash scripts/raspi-deploy.sh --only-build
```

---

## Diagnóstico

```bash
# Estado completo de k3s — guarda en output/output_status_TIMESTAMP.md
bash scripts/raspi-k8s-status.sh

# Logs en vivo de nginx y backend con prefijo de color
bash scripts/raspi-logs.sh --follow

# Solo logs del backend Python
bash scripts/raspi-logs.sh --backend

# Estado de clientes en el router
bash scripts/openwrt-list-clients.sh
```

---

## Gestión de clientes WiFi

```bash
# Listar clientes autorizados, leases DHCP y conexiones activas
bash scripts/openwrt-list-clients.sh

# Autorizar manualmente una IP (sin pasar por el portal)
bash scripts/openwrt-allow-client.sh 192.168.1.55
bash scripts/openwrt-allow-client.sh 192.168.1.55 --permanent  # sin expiración

# Bloquear una IP (vuelve al portal)
bash scripts/openwrt-block-client.sh 192.168.1.55

# Resetear todos los clientes al portal (para demo)
bash scripts/openwrt-flush-clients.sh
bash scripts/openwrt-flush-clients.sh --force   # sin confirmación

# Emergencia — desactivar todo el captive portal
bash scripts/openwrt-reset-firewall.sh
```

---

## Notas importantes

### OpenWrt
- Usar `nft` exclusivamente — **no `iptables`** (OpenWrt 25.x usa nftables)
- Servicios con `/etc/init.d/` — **no `systemctl`**
- Overlay del router: ~840KB — no instalar paquetes innecesarios
- Dropbear no soporta todos los flags de openssh
- `timeout 0` sin unidad NO es válido — usar `timeout 0s`
- Las reglas usan `ip saddr 192.168.1.0/24` (subred) porque `iifname "phy0-ap0"` no funciona con bridge `br-lan`

### Traefik — IP real del cliente
- `externalTrafficPolicy: Local` es obligatorio para que la IP del cliente llegue correctamente
- Sin esto, kube-proxy hace SNAT y la IP se pierde (`10.42.0.1` en los logs)

### nginx + backend sidecar
- nginx y el backend Python corren en el **mismo pod** (sidecar)
- `proxy_pass http://127.0.0.1:8080/accept` — usar IP explícita, **no `localhost`** (IPv6 en Alpine)
- nginx usa `set_real_ip_from 10.42.0.0/16` para extraer la IP real de `X-Forwarded-For`
- El backend escucha en `0.0.0.0:8080` (IPv4 únicamente)

### Raspberry Pi (DietPi)
- DietPi no usa systemd como PID 1 — verificar servicios con `ps aux`
- Builds con `podman build --runtime=runc --network=host`
- Importar imágenes con `podman save | k3s ctr images import -`
- La imagen en containerd se llama `localhost/captive-backend:latest`
