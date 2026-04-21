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
                │  nftables:
                │    • redirige HTTP (puerto 80) → Pi 192.168.1.167
                │    • bloquea forward excepto clientes autorizados
                │  dnsmasq:
                │    • resuelve dominios de detección → 192.168.1.167
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
         │       └── Ingress → Service captive-portal:80
         │
         ├── Pod: captive-portal  (2/2 Running)
         │       ├── [portal]   nginx:alpine      :80
         │       │     • sirve HTML del portal
         │       │     • redirige dominios de detección a /portal
         │       │     • proxy_pass /accept → 127.0.0.1:8080
         │       │
         │       └── [backend]  captive-backend   :8080
         │             • POST /accept: detecta IP via SSH+conntrack
         │             • autoriza IP via SSH+nft en el router
         │             • GET /health: healthcheck
         │
         ├── /opt/keys/captive-portal      (llave SSH ed25519)
         │   /opt/keys/captive-portal.pub  (llave pública → router)
         │
         └── llama.cpp  (pendiente — LLM local)

    Laptop admin  (192.168.1.128)
         • NUNCA bloqueada por las reglas nftables
         • Acceso SSH directo al router y a la Pi
```

---

## Flujo de un cliente nuevo

```
1. Cliente conecta al WiFi "INFINITUM MOVIL"
        │
        ▼
2. DHCP le asigna IP 192.168.1.x
        │
        ▼
3. SO detecta captive portal:
   Android/iOS/Windows/Linux → GET http://connectivitycheck.../
        │
        ▼  dnsmasq resuelve el dominio a 192.168.1.167
        ▼  nftables redirige el HTTP al port 80 de la Pi
        │
        ▼
4. nginx sirve la página del portal (index.html)
        │
        ▼
5. Cliente hace clic en "Entendido, quiero navegar"
   → fetch('POST /accept')
        │
        ▼
6. nginx proxy_pass → http://127.0.0.1:8080/accept
        │
        ▼
7. backend Python:
   a) SSH al router → lee /proc/net/nf_conntrack
      → encuentra src=192.168.1.X dport=80 ESTABLISHED
      → extrae la IP del cliente
   b) SSH al router → nft add element ip captive allowed_clients { 192.168.1.X }
        │
        ▼
8. Cliente puede navegar libremente
   (su IP está en allowed_clients, nftables permite el forward)
```

---

## Componentes de red — nftables en OpenWrt

```
table ip captive {
    set allowed_clients {
        type ipv4_addr
        # Siempre presentes:
        #   192.168.1.128  (admin — nunca bloqueado)
        #   192.168.1.167  (portal Pi)
        # Se agregan dinámicamente al aceptar el portal
    }

    chain prerouting {   # hook: nat/prerouting
        # Clientes autorizados → no redirigir
        iifname "phy0-ap0" tcp dport 80 ip saddr @allowed_clients accept
        # Resto → redirigir al portal
        iifname "phy0-ap0" tcp dport 80 dnat to 192.168.1.167:80
    }

    chain forward_captive {   # hook: filter/forward  priority -1
        iifname "phy0-ap0" ip saddr 192.168.1.128 accept  # admin
        iifname "phy0-ap0" ip daddr 192.168.1.167 accept  # portal
        iifname "phy0-ap0" udp dport { 67, 68 }   accept  # DHCP
        iifname "phy0-ap0" th  dport 53            accept  # DNS
        iifname "phy0-ap0" ip saddr @allowed_clients accept
        iifname "phy0-ap0" drop                            # bloquear resto
    }
}
```

---

## Componentes k8s en la Pi

| Recurso | Tipo | Detalle |
|---|---|---|
| `captive-portal` | Deployment | 1 réplica, 2 contenedores (nginx + backend) |
| `captive-portal` | Service | ClusterIP, ports 80 + 8080 |
| `captive-portal` | Ingress | Traefik → puerto 80, pathType Prefix `/` |
| `captive-portal-nginx-conf` | ConfigMap | nginx.conf + index.html + accepted.html |
| `traefik` | HelmChartConfig | forwardedHeaders.insecure, trustedIPs 0.0.0.0/0 |

### Volúmenes montados en el pod

| volumen | tipo | montado en |
|---|---|---|
| `nginx-conf` | ConfigMap | `/etc/nginx/conf.d/default.conf`, `/usr/share/nginx/html/*.html` |
| `ssh-keys` | hostPath `/opt/keys` | `/opt/keys` (ambos contenedores, readOnly) |

---

## Dispositivos

| Dispositivo | IP | OS | Acceso |
|---|---|---|---|
| Router OpenWrt | 192.168.1.1 | OpenWrt 25.12.2 (ath79/mips_24kc) | SSH root, Dropbear |
| Raspberry Pi 4 (RafexPi) | 192.168.1.167 | DietPi Debian trixie arm64 | SSH, k3s v1.34.6 |
| Laptop admin | 192.168.1.128 | — | **NUNCA bloquear** |
