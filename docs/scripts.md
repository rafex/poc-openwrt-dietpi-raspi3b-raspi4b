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

## openwrt-reserve-raspi.sh

**Propósito:** Reservar permanentemente la IP 192.168.1.167 para la Raspberry Pi en el DHCP del router.  
**Ejecutar en:** Raspberry Pi (conecta al router via SSH)  
**Idempotente:** Sí

```bash
# Modo recomendado: ejecutar desde la misma Pi que se quiere reservar
bash scripts/openwrt-reserve-raspi.sh --auto              # reserva 192.168.1.167
bash scripts/openwrt-reserve-raspi.sh --auto 192.168.1.167  # IP explícita

# Alternativas
bash scripts/openwrt-reserve-raspi.sh --mac DC:A6:32:XX:XX:XX          # MAC manual
bash scripts/openwrt-reserve-raspi.sh --mac DC:A6:32:XX:XX:XX --ip 192.168.1.167
bash scripts/openwrt-reserve-raspi.sh                                  # detecta MAC via ARP del router (legacy)
```

| Paso | Qué hace |
|---|---|
| 1 | **`--auto`**: lee la MAC de `eth0`/`eth1`/`wlan0` de esta máquina directamente |
| 1 | **`--mac`**: usa la MAC proporcionada |
| 1 | **sin flags**: consulta ARP/`dhcp.leases`/`arp -n` del router (modo legacy) |
| 2 | Detecta conflicto: si la IP ya está reservada para otra MAC → error claro |
| 3 | Crea o actualiza reserva UCI `dhcp.@host[N]` con `leasetime=infinite` |
| 4 | Verifica que la DHCP option 6 (DNS) apunte al router |
| 5 | Recarga dnsmasq |
| 6 | Muestra tabla de todas las reservas DHCP actuales y confirma con `uci show` |

> **Por qué es necesario:** Todos los scripts y manifiestos k8s usan `192.168.1.167` como IP fija.  
> Sin esta reserva, un reinicio de la Pi podría asignarle otra IP y el captive portal dejaría de funcionar.
>
> **`--auto` es el modo recomendado** porque la MAC se lee localmente — no depende de que el router tenga la Pi en el ARP (útil en el primer arranque antes de que la Pi haya hecho DHCP).

---

## openwrt-flush-clients.sh

**Propósito:** Resetear clientes autorizados — todos vuelven al portal.
**Ejecutar en:** Raspberry Pi

```bash
sh scripts/openwrt-flush-clients.sh              # pide confirmación
sh scripts/openwrt-flush-clients.sh --force      # sin confirmación (scripts)
```

Qué hace:
- `nft flush set ip captive allowed_clients` — vacía todos los clientes
- Restaura `192.168.1.128` (admin) y `192.168.1.167` (portal) con `timeout 0`
- `conntrack -F` — fuerza que conexiones existentes no bypaseen el bloqueo

**Diferencia con `openwrt-reset-firewall.sh`:**

| | `flush-clients` | `reset-firewall` |
|---|---|---|
| Elimina clientes autorizados | ✅ | ✅ |
| Mantiene nftables activo | ✅ | ❌ (elimina todo) |
| Portal sigue funcionando | ✅ | ❌ |
| Uso típico | Reset entre demos | Emergencia |

---

## openwrt-dns-spoof-enable.sh

**Propósito:** Activar la demo de DNS poisoning — suplantar dominios para que resuelvan a la Pi.  
**Ejecutar en:** Raspberry Pi  
**Idempotente:** Sí (elimina bloque anterior antes de escribir)

```bash
bash scripts/openwrt-dns-spoof-enable.sh                        # activa rafex.dev
bash scripts/openwrt-dns-spoof-enable.sh --domain otro.com      # dominio extra
bash scripts/openwrt-dns-spoof-enable.sh --domain a.com --domain b.com
```

Qué hace:
- Añade entradas `address=/dominio/192.168.1.167` en dnsmasq del router
- Recarga dnsmasq
- Verifica que la resolución está envenenada

Al visitar `http://rafex.dev` desde un dispositivo conectado al WiFi, nginx en la Pi
sirve [`dns-poison.html`](../k8s/captive-portal-configmap.yaml) — una página que explica
paso a paso qué acaba de ocurrir y qué es el DNS poisoning.

> ⚠️ Solo funciona con **HTTP** (puerto 80). Con HTTPS el navegador mostrará error de
> certificado — que en sí mismo es parte del aprendizaje.

---

## openwrt-dns-spoof-disable.sh

**Propósito:** Desactivar la demo de DNS poisoning — devolver resolución DNS normal.  
**Ejecutar en:** Raspberry Pi

```bash
bash scripts/openwrt-dns-spoof-disable.sh
```

Qué hace:
- Elimina el bloque de dnsmasq añadido por `openwrt-dns-spoof-enable.sh`
- Recarga dnsmasq
- Verifica que los dominios ya no resuelven a la Pi

**Flujo de uso en una demo:**

```
[antes de mostrar el ataque]
bash scripts/openwrt-dns-spoof-enable.sh

[audiencia visita http://rafex.dev → ve la página de explicación]

[al terminar la demo]
bash scripts/openwrt-dns-spoof-disable.sh
```

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
