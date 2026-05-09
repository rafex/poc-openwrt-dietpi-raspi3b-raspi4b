Bien, Raúl. Revisando tu lista de paquetes, tu sistema está bastante mínimo, lo cual es bueno para un router con 4 MB de flash. Pero aún podemos liberar algo de espacio sin romper el sistema ni la red.

Primero: no debemos tocar nada crítico como:

busybox
dnsmasq
dropbear
firewall4
netifd
procd
ubus
uci
kernel

ni los módulos WiFi (kmod-ath*, mac80211, hostapd*), porque el router dejaría de funcionar.

⸻

Paquetes que sí puedes eliminar con seguridad

1️⃣ Actualización automática del firmware

Si no la usas desde la interfaz web:

apk del attendedsysupgrade-common luci-app-attendedsysupgrade

Esto libera bastante porque incluye scripts y dependencias.

⸻

2️⃣ Soporte IPv6 (si no lo usas)

Muchos routers domésticos no lo necesitan.

apk del odhcp6c odhcpd-ipv6only luci-proto-ipv6

Esto suele liberar bastante espacio.

⸻

3️⃣ PPP si no usas PPPoE

Si tu router recibe internet por DHCP normal (no PPPoE):

apk del ppp ppp-mod-pppoe luci-proto-ppp

Si usas fibra con ONT o cable modem normalmente no necesitas PPP.

⸻

4️⃣ Herramientas de bootloader

Si no gestionas variables U-Boot:

apk del uboot-envtools

⸻

Lo que definitivamente debes mantener (para tu USB)

No borres:

block-mount
kmod-usb-storage
kmod-usb-storage-uas
kmod-usb-core
kmod-usb2
kmod-usb-ehci
kmod-scsi-core
kmod-fs-ext4

porque son los que permiten:

USB → disco → overlay (extroot)

⸻

Después de borrar

Ejecuta:

apk cache clean
df -h

Deberías intentar llegar a algo como:

overlay libre ≈ 400-600 KB

Eso ya nos permite crear fstab y activar extroot sin problemas.

⸻

Observación importante

Tu router con 4 MB flash + USB es una combinación interesante para tu demo:

OpenWrt
   ↓
USB (overlay)
   ↓
logs / dns / eventos wifi
   ↓
Raspberry Pi (IA)

Esto permite capturar tráfico o eventos sin saturar la flash interna.

⸻

✅ Siguiente paso cuando liberemos un poco más de espacio:

1. conectar la USB EXT4
2. montar /mnt/sda1
3. copiar /overlay
4. activar extroot

y tu router pasará de:

1 MB overlay

a

57 GB overlay

⸻

Si quieres, también puedo enseñarte un truco muy usado en routers de 4 MB que permite activar extroot con solo 2 archivos y casi sin ocupar espacio, evitando los problemas típicos de fstab.