#!/bin/sh
# openwrt-list-clients.sh — Muestra el estado de clientes en el captive portal
#
# Uso: sh scripts/openwrt-list-clients.sh
#
# Muestra:
#   1. IPs autorizadas en el set allowed_clients (nftables)
#   2. Clientes con lease DHCP activo (/tmp/dhcp.leases)
#   3. Conexiones activas al puerto 80 (conntrack)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

# =============================================================================
# Pre-flight checks
# =============================================================================
check_ssh_key
test_router_ssh

# =============================================================================
# 1. Clientes autorizados en nftables
# =============================================================================
printf '\n'
printf '=%.0s' $(seq 1 60); printf '\n'
printf ' CLIENTES AUTORIZADOS en nftables (%s)\n' "$NFT_SET"
printf '=%.0s' $(seq 1 60); printf '\n'

if router_set_exists; then
    # Extraer solo las IPs del set (sin metadata de nft)
    router_ssh "nft list set $NFT_TABLE $NFT_SET 2>/dev/null" | \
        grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | sort | \
        while read -r ip; do
            if [ "$ip" = "$ADMIN_IP" ]; then
                printf '  %-18s  [ADMIN - nunca bloqueado]\n' "$ip"
            elif [ "$ip" = "$PORTAL_IP" ]; then
                printf '  %-18s  [PORTAL]\n' "$ip"
            else
                printf '  %-18s  [autorizado]\n' "$ip"
            fi
        done || printf '  (set vacio)\n'
else
    printf '  [AVISO] El set %s no existe.\n' "$NFT_SET"
    printf '  Ejecuta: sh scripts/setup-openwrt.sh\n'
fi

# =============================================================================
# 2. Leases DHCP activos
# =============================================================================
printf '\n'
printf '=%.0s' $(seq 1 60); printf '\n'
printf ' LEASES DHCP ACTIVOS (/tmp/dhcp.leases)\n'
printf '=%.0s' $(seq 1 60); printf '\n'

# Formato de /tmp/dhcp.leases: <timestamp_expira> <mac> <ip> <hostname> <client-id>
LEASES=$(router_ssh "cat /tmp/dhcp.leases 2>/dev/null" || echo "")

if [ -z "$LEASES" ]; then
    printf '  (sin leases activos o archivo no disponible)\n'
else
    printf '  %-16s  %-18s  %-20s  %s\n' "IP" "MAC" "HOSTNAME" "EXPIRA"
    printf '  %-16s  %-18s  %-20s  %s\n' "----------------" "------------------" "--------------------" "----------"
    printf '%s\n' "$LEASES" | while IFS=' ' read -r expires mac ip hostname cid; do
        # Convertir timestamp a fecha legible (busybox date)
        exp_date=$(router_ssh "date -d @$expires '+%H:%M:%S' 2>/dev/null || echo $expires" 2>/dev/null || echo "$expires")
        printf '  %-16s  %-18s  %-20s  %s\n' "$ip" "$mac" "${hostname:-*}" "$exp_date"
    done
fi

# =============================================================================
# 3. Conexiones activas al puerto 80 (conntrack)
# =============================================================================
printf '\n'
printf '=%.0s' $(seq 1 60); printf '\n'
printf ' CONEXIONES ACTIVAS AL PUERTO 80 (conntrack)\n'
printf '=%.0s' $(seq 1 60); printf '\n'

CONNTRACK_OUT=$(router_ssh "
    if command -v conntrack > /dev/null 2>&1; then
        conntrack -L -p tcp --dport 80 2>/dev/null
    elif [ -f /proc/net/nf_conntrack ]; then
        grep 'dport=80' /proc/net/nf_conntrack 2>/dev/null
    else
        echo 'conntrack_not_available'
    fi
" 2>/dev/null || echo "conntrack_not_available")

if [ "$CONNTRACK_OUT" = "conntrack_not_available" ] || [ -z "$CONNTRACK_OUT" ]; then
    printf '  (conntrack no disponible o sin conexiones activas al puerto 80)\n'
else
    # Parsear y mostrar de forma legible
    printf '  %-18s  %-18s  %-12s  %s\n' "IP ORIGEN" "IP DESTINO" "ESTADO" "PROTO"
    printf '  %-18s  %-18s  %-12s  %s\n' "------------------" "------------------" "------------" "-----"
    printf '%s\n' "$CONNTRACK_OUT" | head -20 | while read -r line; do
        # Extraer campos relevantes de la linea conntrack
        src=$(printf '%s' "$line" | grep -oE 'src=[0-9.]+' | head -1 | cut -d= -f2)
        dst=$(printf '%s' "$line" | grep -oE 'dst=[0-9.]+' | head -1 | cut -d= -f2)
        state=$(printf '%s' "$line" | grep -oE 'ESTABLISHED|SYN_SENT|TIME_WAIT|CLOSE_WAIT|FIN_WAIT' | head -1)
        proto=$(printf '%s' "$line" | awk '{print $1}')
        [ -n "$src" ] && printf '  %-18s  %-18s  %-12s  %s\n' \
            "${src:-(desconocido)}" "${dst:-(desconocido)}" "${state:-UNKNOWN}" "${proto:-tcp}"
    done
fi

# =============================================================================
# 4. Resumen rapido de reglas activas
# =============================================================================
printf '\n'
printf '=%.0s' $(seq 1 60); printf '\n'
printf ' ESTADO NFTABLES (tabla %s)\n' "$NFT_TABLE"
printf '=%.0s' $(seq 1 60); printf '\n'

if router_table_exists; then
    router_ssh "nft list table $NFT_TABLE 2>/dev/null" | grep -E 'chain|hook|policy|drop|dnat|@'
else
    printf '  [AVISO] La tabla %s no existe — captive portal no activo\n' "$NFT_TABLE"
fi

printf '\n'
