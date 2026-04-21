# Guía de Setup — Captive Portal PoC

## Prerequisitos

| Componente | Requisito |
|---|---|
| Raspberry Pi 4 | DietPi instalado, conectada a la red LAN del router |
| Router OpenWrt | OpenWrt 25.x, acceso SSH como root |
| Laptop admin | IP fija 192.168.1.128 en la misma red |
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

## Paso 2 — Setup inicial de la Pi

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

## Paso 3 — Setup del router OpenWrt

Ejecutar **desde la Pi** (usa la llave SSH generada en el paso anterior):

```bash
bash scripts/setup-openwrt.sh
```

Qué hace:
- Agrega la llave pública al router (`/etc/dropbear/authorized_keys`)
- Configura dnsmasq para redirigir dominios de detección a `192.168.1.167`
- Crea la tabla nftables `ip captive` con:
  - Redirección HTTP de clientes WiFi al portal
  - Bloqueo de forward excepto clientes autorizados, DHCP y DNS
- Persiste las reglas en `/etc/nftables.d/captive-portal.nft`
- **Garantiza que `192.168.1.128` (admin) siempre tiene acceso**

> ⚠️ **Seguridad**: en caso de quedarse bloqueado del router:
> ```bash
> ssh root@192.168.1.1   # SSH directo no usa el hook forward
> nft delete table ip captive
> ```

---

## Paso 4 — Verificar funcionamiento

```bash
# Resumen de estado + últimas líneas de logs
bash scripts/raspi-logs.sh

# Tests funcionales completos (HTTP + SSH router + nftables + conntrack)
bash scripts/raspi-logs.sh --test
```

Tests que ejecuta:
1. HTTP endpoints del portal (`/portal`, `/accepted`, `/`)
2. Backend Python responde en `:8080` dentro del pod
3. SSH desde el backend al router
4. Tabla `ip captive` existe con set `allowed_clients`
5. Conntrack accesible en el router

---

## Flujo de actualización

Cuando se modifica `backend.py` o los manifiestos k8s:

```bash
# En la Pi — rebuild + apply + verify
bash scripts/raspi-deploy.sh

# Solo cambió el ConfigMap (HTML o nginx config) — sin rebuild
bash scripts/raspi-deploy.sh --no-build

# Solo rebuild de la imagen — sin apply
bash scripts/raspi-deploy.sh --only-build

# Limpiar recursos legacy (solo necesario una vez)
bash scripts/raspi-deploy.sh --cleanup
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

# Estado de clientes en el router (set nft + DHCP leases + conntrack)
bash scripts/openwrt-list-clients.sh
```

---

## Gestión de clientes WiFi

```bash
# Listar clientes autorizados, leases DHCP y conexiones activas
bash scripts/openwrt-list-clients.sh

# Autorizar manualmente una IP (sin pasar por el portal)
bash scripts/openwrt-allow-client.sh 192.168.1.55

# Bloquear una IP (vuelve al portal)
bash scripts/openwrt-block-client.sh 192.168.1.55

# Emergencia — desactivar todo el captive portal
bash scripts/openwrt-reset-firewall.sh
```

---

## Notas importantes

### OpenWrt
- Usar `nft` exclusivamente — **no `iptables`** (OpenWrt 25.x usa nftables)
- Servicios con `/etc/init.d/` — **no `systemctl`**
- Overlay del router: ~840KB — no instalar paquetes innecesarios
- Dropbear no soporta todos los flags de openssh — usar opciones básicas

### Raspberry Pi (DietPi)
- DietPi no usa systemd como PID 1 — verificar servicios con `ps aux`
- Builds con `podman build --runtime=runc --network=host`
- Importar imágenes con `podman save | k3s ctr images import -`
- La imagen en containerd se llama `localhost/captive-backend:latest`

### nginx + backend sidecar
- nginx y el backend Python corren en el **mismo pod** (sidecar)
- nginx hace `proxy_pass http://127.0.0.1:8080/accept` — usar IP explícita, **no `localhost`** (se resuelve a IPv6 `::1` en Alpine)
- El backend escucha en `0.0.0.0:8080` (IPv4 únicamente)
