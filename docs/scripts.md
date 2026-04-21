# Referencia de Scripts

Todos los scripts viven en `scripts/`. Los que interactúan con el router
se ejecutan **desde la Pi** via SSH.

---

## setup-raspi.sh

**Propósito:** Instalación inicial de la Pi desde cero.  
**Ejecutar en:** Raspberry Pi  
**Idempotente:** Sí

```bash
bash scripts/setup-raspi.sh
```

| Fase | Qué hace |
|---|---|
| A | Verifica que k3s está corriendo (`ps aux`) |
| B | Crea `/opt/keys/`, genera llave SSH ed25519 si no existe |
| C | `podman build` + `podman save \| k3s ctr images import` |
| D | `kubectl apply` en orden: configmap → svc → deployment |
| E | Verifica HTTP en `http://192.168.1.167` |

---

## setup-openwrt.sh

**Propósito:** Configuración del router OpenWrt.  
**Ejecutar en:** Raspberry Pi (conecta al router via SSH)  
**Idempotente:** Sí

```bash
bash scripts/setup-openwrt.sh
```

| Fase | Qué hace |
|---|---|
| Pre-flight | Verifica espacio en overlay, interfaz `phy0-ap0`, SSH |
| A | Agrega llave pública a `/etc/dropbear/authorized_keys` |
| B | Escribe `/etc/dnsmasq.d/captive-portal.conf` y recarga dnsmasq |
| C | Valida sintaxis nft → elimina tabla → aplica → re-confirma admin en set |
| D | Persiste en `/etc/nftables.d/captive-portal.nft` |

> **Regla de oro:** `192.168.1.128` se agrega al set `allowed_clients`
> ANTES de activar cualquier regla de bloqueo.

---

## raspi-deploy.sh

**Propósito:** Actualizar el captive portal en k3s.  
**Ejecutar en:** Raspberry Pi

```bash
bash scripts/raspi-deploy.sh              # build + apply + verify
bash scripts/raspi-deploy.sh --no-build   # solo apply manifiestos
bash scripts/raspi-deploy.sh --only-build # solo rebuild imagen
bash scripts/raspi-deploy.sh --cleanup    # elimina recursos legacy
```

Detecta automáticamente si necesita `rollout restart`:
- Si cambió el ConfigMap nginx (nginx no recarga automáticamente)
- Si se reconstruyó la imagen del backend

---

## raspi-logs.sh

**Propósito:** Ver logs y verificar salud del captive portal.  
**Ejecutar en:** Raspberry Pi

```bash
bash scripts/raspi-logs.sh              # estado + logs de ambos contenedores
bash scripts/raspi-logs.sh --follow     # tail -f en vivo (nginx y backend)
bash scripts/raspi-logs.sh --backend    # solo logs del backend Python
bash scripts/raspi-logs.sh --nginx      # solo logs de nginx
bash scripts/raspi-logs.sh --test       # 5 tests funcionales automáticos
bash scripts/raspi-logs.sh --all        # logs + tests
bash scripts/raspi-logs.sh --lines=100  # cambiar número de líneas
```

Tests funcionales (`--test`):

| Test | Qué verifica |
|---|---|
| 1 | HTTP endpoints: `/portal` (200), `/accepted` (200), `/` (302) |
| 2 | Backend Python `:8080/health` dentro del pod |
| 3 | SSH desde el backend al router OpenWrt |
| 4 | Tabla `ip captive` con set `allowed_clients` en nftables |
| 5 | Conntrack accesible en el router |

---

## raspi-k8s-status.sh

**Propósito:** Diagnóstico completo del estado de k3s.  
**Ejecutar en:** Raspberry Pi  
**Salida:** `output/output_status_YYYYMMDD_HHMMss.md`

```bash
bash scripts/raspi-k8s-status.sh
```

Si k3s no está corriendo, lo **arranca automáticamente** y espera hasta 60s.
Vuelca YAML real del API server (no del repo):
deployments, services, configmaps, ingress, Traefik, imágenes, llaves SSH, HTTP.

---

## openwrt-allow-client.sh

**Propósito:** Autorizar manualmente una IP en el captive portal.  
**Ejecutar en:** Raspberry Pi

```bash
bash scripts/openwrt-allow-client.sh 192.168.1.55
```

---

## openwrt-block-client.sh

**Propósito:** Bloquear una IP (devuelve al portal).  
**Ejecutar en:** Raspberry Pi

```bash
bash scripts/openwrt-block-client.sh 192.168.1.55
```

> Nunca bloquea `192.168.1.128` (admin). Protección hardcodeada.

---

## openwrt-list-clients.sh

**Propósito:** Estado actual de clientes en el router.  
**Ejecutar en:** Raspberry Pi

```bash
bash scripts/openwrt-list-clients.sh
```

Muestra:
- IPs en el set `allowed_clients` (nftables)
- Leases DHCP activos (`/tmp/dhcp.leases`)
- Conexiones activas al puerto 80 (conntrack)
- Reglas nftables activas

---

## openwrt-reset-firewall.sh

**Propósito:** Emergencia — desactiva todo el captive portal.  
**Ejecutar en:** Raspberry Pi

```bash
bash scripts/openwrt-reset-firewall.sh
```

Pide confirmación antes de ejecutar. Elimina:
- Tabla `ip captive` (nftables)
- `/etc/nftables.d/captive-portal.nft`
- `/etc/dnsmasq.d/captive-portal.conf`
- Flush de conntrack

No toca la configuración base de `fw4`.

---

## lib/common.sh

Librería compartida cargada con `. scripts/lib/common.sh`.

| Función | Descripción |
|---|---|
| `log_info/ok/warn/error/die` | Logging |
| `validate_ip <ip>` | Valida formato A.B.C.D (POSIX sh) |
| `router_ssh <cmd>` | SSH al router con llave `/opt/keys/captive-portal` |
| `check_ssh_key` | Verifica que la llave existe |
| `test_router_ssh` | Prueba conectividad SSH al router |
| `router_table_exists` | Verifica si la tabla `ip captive` existe |
| `router_set_exists` | Verifica si el set `allowed_clients` existe |
| `router_ip_in_set <ip>` | Verifica si una IP está en el set |
| `router_add_ip <ip>` | Agrega IP al set |
| `router_del_ip <ip>` | Elimina IP del set |
