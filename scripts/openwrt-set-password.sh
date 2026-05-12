#!/bin/sh
# openwrt-set-password.sh — Establece/cambia la contraseña de root en OpenWrt
#
# Uso:
#   sh scripts/openwrt-set-password.sh
#   sh scripts/openwrt-set-password.sh --password 'NuevaClaveSegura'
#
# Notas:
#   - Requiere acceso SSH por llave al router (usa lib/common.sh).
#   - Si no se pasa --password, pide la contraseña en modo oculto.
#   - No imprime la contraseña en logs/salida.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

PASSWORD=""

print_usage() {
    cat <<EOF
Uso:
  sh scripts/openwrt-set-password.sh [opciones]

Opciones:
  --password <valor>   Contraseña nueva (evitar en shell history).
  -h, --help           Mostrar esta ayuda.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --password)
            [ -n "${2:-}" ] || die "Falta valor para --password"
            PASSWORD="$2"
            shift 2
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        *)
            die "Argumento no soportado: $1"
            ;;
    esac
done

prompt_password() {
    local p1 p2
    printf 'Nueva contraseña root para OpenWrt: ' >&2
    stty -echo
    IFS= read -r p1
    stty echo
    printf '\n' >&2

    printf 'Confirmar contraseña: ' >&2
    stty -echo
    IFS= read -r p2
    stty echo
    printf '\n' >&2

    [ -n "$p1" ] || die "La contraseña no puede estar vacía"
    [ "$p1" = "$p2" ] || die "Las contraseñas no coinciden"
    PASSWORD="$p1"
}

if [ -z "$PASSWORD" ]; then
    prompt_password
fi

# Mínimo básico para evitar contraseñas triviales por error.
[ "${#PASSWORD}" -ge 8 ] || die "La contraseña debe tener al menos 8 caracteres"

check_ssh_key
test_router_ssh

log_info "Aplicando nueva contraseña de root en el router..."
if printf '%s\n%s\n' "$PASSWORD" "$PASSWORD" | router_ssh "passwd root >/dev/null 2>&1"; then
    log_ok "Contraseña de root actualizada correctamente"
else
    die "No se pudo actualizar la contraseña de root"
fi

log_info "Verificando que el router sigue accesible por llave SSH..."
test_router_ssh
log_ok "Proceso completado"

