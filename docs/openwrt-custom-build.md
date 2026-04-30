# Compilación personalizada de OpenWrt (CLI sin Luci)

## Resumen

Guía para compilar una imagen personalizada de OpenWrt **sin el frontend web Luci**, reduciendo el tamaño y complejidad. Usa **OpenWrt Image Builder** — no requiere compilar todo desde fuente.

---

## Requisitos previos

### Hardware
- Laptop/servidor x86-64 con al menos 10 GB de espacio libre
- ~30 min de tiempo de compilación (depende de CPU)

### Software
- `unzstd` para descomprimir archivos `.tar.zst`
- `tar`
- `make`
- `gcc`, `patch`, `bzip2` (pre-instalados en la mayoría de distros)

```bash
# Debian/Ubuntu
sudo apt install build-essential zstd

# macOS
brew install zstd
```

---

## Paso 1 — Descargar el Image Builder

**Ubicación oficial:** https://downloads.openwrt.org/releases/25.12.2/targets/ath79/generic/

Para el **TP-Link TL-WDR3600 v1** (ath79 MIPS 24kc):

```bash
# Crear directorio de trabajo
mkdir -p ~/openwrt-build && cd ~/openwrt-build

# Descargar el Image Builder (ver. 25.12.2 ath79 generic)
wget https://downloads.openwrt.org/releases/25.12.2/targets/ath79/generic/openwrt-imagebuilder-25.12.2-ath79-generic.Linux-x86_64.tar.zst

# Alternativa: si wget falla
curl -O https://downloads.openwrt.org/releases/25.12.2/targets/ath79/generic/openwrt-imagebuilder-25.12.2-ath79-generic.Linux-x86_64.tar.zst
```

---

## Paso 2 — Descomprimir el Image Builder

El archivo `.tar.zst` combina tar + zstandard compression. Existen dos métodos:

### Método A (recomendado) — Una sola línea
```bash
tar --use-compress-program=unzstd -xf openwrt-imagebuilder-25.12.2-ath79-generic.Linux-x86_64.tar.zst
```

### Método B — Dos pasos
```bash
# Primero descomprimir zstd
unzstd openwrt-imagebuilder-25.12.2-ath79-generic.Linux-x86_64.tar.zst

# Luego extraer tar
tar -xf openwrt-imagebuilder-25.12.2-ath79-generic.Linux-x86_64.tar
```

**Resultado:**
```
openwrt-imagebuilder-25.12.2-ath79-generic.Linux-x86_64/
├── Makefile
├── scripts/
├── target/
└── ...
```

---

## Paso 3 — Compilar imagen sin Luci

Entrar en el directorio y ejecutar `make image` con tu perfil de hardware y paquetes personalizados:

```bash
cd openwrt-imagebuilder-25.12.2-ath79-generic.Linux-x86_64

make image \
  PROFILE=tplink_tl-wdr3600-v1 \
  PACKAGES="\
dropbear \
dnsmasq \
firewall4 \
wpad-basic-mbedtls \
kmod-usb-core kmod-usb2 kmod-usb-ehci \
kmod-usb-storage kmod-usb-storage-uas \
kmod-scsi-core kmod-scsi-generic \
kmod-fs-ext4 block-mount e2fsprogs \
-luci -luci-base -luci-light -luci-theme-bootstrap \
-luci-app-firewall -luci-app-package-manager \
-luci-mod-admin-full -luci-mod-network -luci-mod-status -luci-mod-system \
-luci-proto-ipv6 -luci-proto-ppp \
-uhttpd -uhttpd-mod-ubus \
-rpcd -rpcd-mod-file -rpcd-mod-iwinfo -rpcd-mod-luci -rpcd-mod-rpcsys -rpcd-mod-rrdns -rpcd-mod-ucode"
```

---

## Paso 4 — Interpretar la salida

La compilación mostrará:
```
...
[compilando]
...
Image Name:  openwrt-ath79-generic-tplink_tl-wdr3600-v1-squashfs-sysupgrade.bin
...
```

**Imagen compilada ubicación:**
```
bin/targets/ath79/generic/openwrt-ath79-generic-tplink_tl-wdr3600-v1-squashfs-sysupgrade.bin
```

---

## Configuración — Paquetes incluidos

### Base (sistema operativo)
- `dropbear` — servidor SSH ligero
- `dnsmasq` — DHCP + DNS (captive portal)
- `firewall4` — nftables + reglas de firewall
- `wpad-basic-mbedtls` — soporte WiFi 802.11ac/n

### USB & Almacenamiento
- `kmod-usb-core` `kmod-usb2` `kmod-usb-ehci` — USB host
- `kmod-usb-storage` `kmod-usb-storage-uas` — almacenamiento USB
- `kmod-scsi-core` `kmod-scsi-generic` — soporte genérico SCSI
- `kmod-fs-ext4` `block-mount` `e2fsprogs` — ext4 + herramientas

---

## Configuración — Paquetes excluidos (Luci + WebUI)

Todos los paquetes comenzando con `-` se **eliminan**:

| Paquete | Propósito | Por qué se excluye |
|---|---|---|
| `luci*` | Frontend web Luci | Reduce tamaño; usaremos CLI/SSH |
| `uhttpd*` | Servidor HTTP | No necesario sin Luci |
| `rpcd*` | RPC daemon + módulos | Soporte para Luci y UI remota |
| `luci-proto-ipv6` `luci-proto-ppp` | Protocolos en UI | UI innecesaria |

**Beneficios:**
- ✅ Imagen ~8-10 MB más pequeña
- ✅ Menos procesos en memoria
- ✅ Superficie de ataque reducida
- ✅ Configuración únicamente por SSH (UCI)

---

## Paso 5 — Flashear la imagen

### Desde el router actual (si ya tiene OpenWrt)

```bash
# SSH a router
ssh root@192.168.1.1

# Ver espacio disponible
df -h /

# Copiar imagen (desde laptop)
scp bin/targets/ath79/generic/openwrt-ath79-generic-tplink_tl-wdr3600-v1-squashfs-sysupgrade.bin \
  root@192.168.1.1:/tmp/

# Flashear en router (SSH session)
sysupgrade -v /tmp/openwrt-ath79-generic-tplink_tl-wdr3600-v1-squashfs-sysupgrade.bin
```

### Desde cero (factory reset / TFTP)

1. Configurar TFTP server en laptop
2. Renombrar imagen a nombre corto: `wdr3600.bin`
3. Router en modo TFTP recovery (hold reset button 10s en boot)
4. TFTP push: `tftp 192.168.1.1`
5. Esperar ~3 min a que flashee

---

## Configuración post-instalación

### Acceso inicial (SSH)

```bash
# SSH a 192.168.1.1
ssh root@192.168.1.1

# Cambiar contraseña de root
passwd

# Ver versión
cat /etc/os-release
```

### Configurar con UCI (línea de comandos)

Sin Luci, toda configuración es **UCI** (Unified Configuration Interface):

```bash
# Ver configuración actual
uci show

# Configurar SSID WiFi
uci set wireless.@wifi-device[0].hwmode=11g
uci set wireless.@wifi-iface[0].ssid="MiRedWiFi"
uci set wireless.@wifi-iface[0].encryption=psk2
uci set wireless.@wifi-iface[0].key="contraseña_wifi"
uci commit wireless

# Restart WiFi
wifi

# Configurar IP estática LAN
uci set network.lan.ipaddr=192.168.1.1
uci set network.lan.netmask=255.255.255.0
uci commit network
```

---

## Troubleshooting

### Error: "zstd: not found"
```bash
# Instalar zstd
sudo apt install zstd    # Debian/Ubuntu
brew install zstd        # macOS
```

### Error: "IMAGE_PREFIX not set" durante make image
```bash
# Solución: estar en el directorio correcto
cd openwrt-imagebuilder-25.12.2-ath79-generic.Linux-x86_64
make image ...
```

### Error: "kmod-* not found"
Los módulos deben existir para tu arquitectura. Ver paquetes disponibles:
```bash
# En el Image Builder
make info  # lista perfiles y paquetes disponibles
```

### Imagen demasiado grande (>7.5 MB)
Algunos paquetes pueden no caber. Revisar `PACKAGES=` y eliminar opcionales:
- `e2fsprogs` es grande; si no usas ext4, eliminar
- `wpad-basic-mbedtls` puede reemplazarse por `wpad-mini` si no necesitas WPA3

---

## Referencias

- [OpenWrt Image Builder Docs](https://openwrt.org/docs/guide/user/imagerybuilder/start)
- [OpenWrt Packages](https://packages.openwrt.org/)
- [TP-Link TL-WDR3600 en OpenWrt](https://openwrt.org/toh/tp-link/tl-wdr3600)
- [UCI Docs](https://openwrt.org/docs/guide/user/uci/start)
