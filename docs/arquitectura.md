# Arquitectura del PoC — Captive Portal con IA Local

## Visión general

PoC educativo que demuestra cómo funciona un captive portal en redes WiFi públicas,
combinando hardware real (Raspberry Pi + router OpenWrt) con un LLM local.

```
Internet
    │
    ▼
Router OpenWrt 25.12.2  (192.168.1.1)
    │  ath79/mips_24kc — hardware TP-Link o similar
    │
    ├── WAN:  phy1-sta0  → conectado al WiFi "netup" (5 GHz, upstream)
    │
    └── AP:   phy0-ap0   → WiFi "INFINITUM MOVIL" (2.4 GHz, clientes)
                │
                │  nftables (matching por subred, NO por interfaz):
                │    • forward_captive: bloquea ip saddr 192.168.1.0/24
                │      excepto admin, portal, DHCP, DNS y allowed_clients
                │    • prerouting: DNAT HTTP de la subred → Pi :80
                │  dnsmasq:
                │    • resuelve dominios de detección → 192.168.1.167
                │    • DHCP lease time: 30 minutos
                │
                ▼
         Clientes WiFi (192.168.1.x)
                │
                ▼
    Raspberry Pi 4 — RafexPi  (192.168.1.167)
         │  DietPi Debian trixie arm64
         │  k3s v1.34.6+k3s1
         │
         ├── Traefik 3.6.10  (LoadBalancer :80/:443)
         │       externalTrafficPolicy: Local  ← sin SNAT, preserva IP real
         │       └── Ingress → Service captive-portal:80
         │
         ├── Pod: captive-portal  (2/2 Running)
         │       ├── [portal]   nginx:alpine      :80
         │       │     • set_real_ip_from 10.42.0.0/16 (confía en Traefik)
         │       │     • real_ip_header X-Forwarded-For → $remote_addr = IP real
         │       │     • sirve HTML del portal y página de aceptado
         │       │     • redirige dominios de detección a /portal
         │       │     • proxy_pass /accept → 127.0.0.1:8080 con X-Real-IP=$remote_addr
         │       │
         │       └── [backend]  captive-backend   :8080
         │             • POST /accept:
         │               1. Lee X-Real-IP header (IP real del cliente WiFi)
         │               2. Fallback: X-Forwarded-For primera IP 192.168.1.X
         │               3. Fallback: SSH+conntrack al router
         │               4. SSH+nft → agrega IP a allowed_clients
         │             • GET /health: verifica SSH al router
         │
         ├── /opt/keys/captive-portal      (llave SSH ed25519)
         │   /opt/keys/captive-portal.pub  (llave pública → router)
         │
         └── llama.cpp  (pendiente — LLM local)

    Laptop admin  (192.168.1.113)
         • NUNCA bloqueada — timeout 0s en el set allowed_clients
         • Acceso SSH directo al router y a la Pi
```

---

## Flujo completo de un cliente nuevo

```
1. Cliente conecta al WiFi "INFINITUM MOVIL"
        │
        ▼
2. DHCP le asigna IP 192.168.1.x (lease 30 minutos)
        │
        ▼
3. SO detecta captive portal:
   Android/iOS/Windows/Linux → GET http://connectivitycheck.../
        │
        ▼  dnsmasq resuelve el dominio a 192.168.1.167
        ▼  nftables prerouting: DNAT ip saddr 192.168.1.0/24 tcp dport 80 → 192.168.1.167:80
        │
        ▼
4. Traefik (externalTrafficPolicy:Local) recibe la petición con IP real del cliente
        │
        ▼
5. nginx (set_real_ip_from 10.42.0.0/16) extrae IP real de X-Forwarded-For
   → $remote_addr = 192.168.1.X (IP del cliente, no de k3s)
   → sirve index.html (portal)
        │
        ▼
6. Cliente hace clic en "Entendido, quiero navegar"
   → fetch('POST /accept')
        │
        ▼
7. nginx proxy_pass → http://127.0.0.1:8080/accept
   con header X-Real-IP: 192.168.1.X
        │
        ▼
8. backend Python lee X-Real-IP → client_ip = 192.168.1.X
   → SSH al router → nft add element ip captive allowed_clients { 192.168.1.X }
        │
        ▼
9. Cliente puede navegar libremente
   (su IP está en allowed_clients con timeout 30m)
        │
        ▼
10. Tras 30 minutos: el elemento expira del set Y el lease DHCP expira
    → al reconectar obtiene nueva IP → vuelve al portal automáticamente
```

---

## Componentes de red — nftables en OpenWrt

```nft
table ip captive {
    set allowed_clients {
        type ipv4_addr
        flags dynamic, timeout
        timeout 30m                    # clientes WiFi: 30 min
        # elementos permanentes (timeout 0s):
        #   192.168.1.113  (admin — nunca bloqueado)
        #   192.168.1.167  (portal Pi — siempre accesible)
    }

    # Redireccion HTTP: matching por subred (NO por interfaz)
    # Razón: clientes WiFi pasan por bridge br-lan, no por phy0-ap0
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        ip daddr 192.168.1.167 accept              # ya va al portal: no DNAT
        ip saddr @allowed_clients accept            # autorizado: no DNAT
        ip saddr 192.168.1.0/24 tcp dport 80       # resto de LAN HTTP → portal
            dnat to 192.168.1.167:80
    }

    # Bloqueo de forward — priority -1 (antes que fw4)
    chain forward_captive {
        type filter hook forward priority filter - 1; policy accept;
        ip saddr != 192.168.1.0/24 accept          # tráfico fuera de LAN: pasar
        ip saddr 192.168.1.113 accept              # admin: siempre pasa
        ip saddr 192.168.1.167 accept              # portal: siempre pasa
        ip daddr 192.168.1.167 accept              # hacia portal: siempre pasa
        udp dport { 67, 68 } accept                # DHCP
        tcp dport 53 accept                        # DNS TCP
        udp dport 53 accept                        # DNS UDP
        ip saddr @allowed_clients accept           # cliente autorizado: pasa
        ip saddr 192.168.1.0/24 drop               # resto de LAN: bloqueado
    }
}
```

---

## Por qué matching por subred y no por interfaz

En OpenWrt, los clientes WiFi se agregan al bridge `br-lan`. El kernel ve
el tráfico con `iifname = "br-lan"` en el hook forward, **no** `"phy0-ap0"`.
Si las reglas usan `iifname "phy0-ap0"`, nunca hacen match y todo pasa libre.

Solución: filtrar por `ip saddr 192.168.1.0/24` (la subred LAN), que identifica
correctamente a todos los clientes independientemente de cómo lleguen al bridge.

---

## Por qué externalTrafficPolicy: Local en Traefik

Con `externalTrafficPolicy: Cluster` (default), kube-proxy hace SNAT al reenviar
el tráfico al pod de Traefik — la IP real del cliente (192.168.1.X) se reemplaza
por la IP del gateway CNI (10.42.0.1). Traefik propaga ese valor en `X-Forwarded-For`.

Con `externalTrafficPolicy: Local`, kube-proxy no hace SNAT y Traefik recibe
la IP real del cliente directamente.

En un cluster de 1 nodo (esta Pi) no hay desventajas de usar `Local`.

---

## Por qué set_real_ip_from en nginx

Aunque Traefik ya envía `X-Forwarded-For` con la IP real, nginx necesita
configurarse explícitamente para usarla como `$remote_addr`:

```nginx
set_real_ip_from 10.42.0.0/16;   # confiar en requests del cluster k3s
real_ip_header X-Forwarded-For;
real_ip_recursive on;
# Resultado: $remote_addr = 192.168.1.X (IP real del cliente WiFi)
```

Sin esto, `$remote_addr` sería la IP de Traefik (10.42.0.X) y el backend
recibiría una IP interna que no existe en nftables.

---

## Componentes k8s en la Pi

| Recurso | Tipo | Detalle |
|---|---|---|
| `captive-portal` | Deployment | 1 réplica, 2 contenedores (nginx + backend) |
| `captive-portal` | Service | ClusterIP, ports 80 + 8080 |
| `captive-portal` | Ingress | Traefik → puerto 80, pathType Prefix `/` |
| `captive-portal-nginx-conf` | ConfigMap | nginx.conf + index.html + accepted.html |
| `traefik` | HelmChartConfig | `externalTrafficPolicy:Local` + `forwardedHeaders.insecure` |

### Volúmenes montados en el pod

| Volumen | Tipo | Montado en |
|---|---|---|
| `nginx-conf` | ConfigMap | `/etc/nginx/conf.d/default.conf`, `/usr/share/nginx/html/*.html` |
| `ssh-keys` | hostPath `/opt/keys` | `/opt/keys` (ambos contenedores, readOnly) |

---

## Dispositivos

| Dispositivo | IP | OS | Acceso |
|---|---|---|---|
| Router OpenWrt | 192.168.1.1 | OpenWrt 25.12.2 (ath79/mips_24kc) | SSH root, Dropbear |
| Raspberry Pi 4 (RafexPi) | 192.168.1.167 | DietPi Debian trixie arm64 | SSH, k3s v1.34.6 |
| Laptop admin | 192.168.1.113 | — | **NUNCA bloquear** |
