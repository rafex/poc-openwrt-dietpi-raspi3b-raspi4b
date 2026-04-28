#!/bin/bash
# lib/raspi3b-deps.sh — Funciones de instalación de dependencias para Raspi3B
#
# USAGE (como librería en otro script):
#   . "$SCRIPT_DIR/lib/raspi3b-deps.sh"
#
#   install_raspi3b_base      # curl wget git ca-certs gnupg jq python3 openssh-client
#   install_raspi3b_capture   # tshark tcpdump iproute2 net-tools
#   install_raspi3b_python    # python3 python3-pip + paho-mqtt requests
#   install_raspi3b_podman    # podman (para topología split_portal)
#   install_raspi3b_all_deps  # llama todas las anteriores
#
# Esta librería NO depende de raspi4b-common.sh — puede sourciarse independientemente.
# Define sus propios helpers mínimos si no están disponibles.

# ─── Helpers mínimos (si no viene de raspi4b-common.sh) ──────────────────────

_r3b_log_info()  { printf '[INFO]  %s\n' "$*"; }
_r3b_log_ok()    { printf '[OK]    %s\n' "$*"; }
_r3b_log_warn()  { printf '[WARN]  %s\n' "$*"; }

# Respetar DRY_RUN si está definido en el entorno del padre
_DRY_RUN="${DRY_RUN:-false}"

_r3b_run() {
    if $_DRY_RUN; then
        _r3b_log_info "[dry-run] $*"
        return 0
    fi
    "$@"
}

_R3B_APT_UPDATED=0
_r3b_apt_update_once() {
    [ "$_R3B_APT_UPDATED" -eq 1 ] && return 0
    _r3b_run env DEBIAN_FRONTEND=noninteractive \
        apt-get -o Acquire::Retries=3 -o DPkg::Lock::Timeout=120 update -q
    _R3B_APT_UPDATED=1
}

_r3b_apt_install() {
    [ "$#" -gt 0 ] || return 0
    local pkg missing=()
    for pkg in "$@"; do
        dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed" \
            || missing+=("$pkg")
    done
    [ "${#missing[@]}" -eq 0 ] && return 0
    _r3b_apt_update_once
    _r3b_run env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none NEEDRESTART_MODE=a \
        apt-get -y -q --no-install-recommends \
            -o Acquire::Retries=3 \
            -o DPkg::Lock::Timeout=120 \
            -o Dpkg::Options::=--force-confdef \
            -o Dpkg::Options::=--force-confold \
            install "${missing[@]}"
}

# Si raspi4b-common.sh ya fue sourciado, reutilizar sus funciones
_apt_install_pkgs_fn() {
    if declare -f apt_install_pkgs &>/dev/null; then
        apt_install_pkgs "$@"
    else
        _r3b_apt_install "$@"
    fi
}
_run_cmd_fn() {
    if declare -f run_cmd &>/dev/null; then
        run_cmd "$@"
    else
        _r3b_run "$@"
    fi
}
_log_info_fn()  { declare -f log_info  &>/dev/null && log_info  "$@" || _r3b_log_info  "$@"; }
_log_ok_fn()    { declare -f log_ok    &>/dev/null && log_ok    "$@" || _r3b_log_ok    "$@"; }
_log_warn_fn()  { declare -f log_warn  &>/dev/null && log_warn  "$@" || _r3b_log_warn  "$@"; }

# ─── Base del sistema ─────────────────────────────────────────────────────────

install_raspi3b_base() {
    _log_info_fn "[deps/pi3b] Paquetes base del sistema"
    _apt_install_pkgs_fn \
        ca-certificates \
        curl \
        wget \
        git \
        gnupg \
        jq \
        python3 \
        python3-minimal \
        openssh-client \
        iproute2 \
        net-tools \
        dnsutils \
        iputils-ping \
        cron \
        less \
        procps
    _log_ok_fn "[deps/pi3b] Paquetes base OK"
}

# ─── Captura de red ───────────────────────────────────────────────────────────

install_raspi3b_capture() {
    _log_info_fn "[deps/pi3b] Herramientas de captura de red"
    _apt_install_pkgs_fn tshark tcpdump
    _log_ok_fn "[deps/pi3b] tshark + tcpdump OK"

    # Permitir a usuarios no-root capturar (DietPi lo necesita)
    if ! $_DRY_RUN && command -v dpkg-reconfigure &>/dev/null; then
        # dumpcap group para captura sin root
        if getent group wireshark &>/dev/null 2>&1; then
            _log_info_fn "[deps/pi3b] grupo wireshark ya existe"
        else
            _r3b_run groupadd -r wireshark 2>/dev/null || true
        fi
        # Dar permisos al binario dumpcap si existe
        if [ -x /usr/bin/dumpcap ]; then
            _r3b_run chgrp wireshark /usr/bin/dumpcap 2>/dev/null || true
            _r3b_run chmod 750 /usr/bin/dumpcap 2>/dev/null || true
        fi
    fi
}

# ─── Python + dependencias del sensor ─────────────────────────────────────────

install_raspi3b_python() {
    _log_info_fn "[deps/pi3b] Python3 + pip + dependencias del sensor"
    _apt_install_pkgs_fn python3 python3-pip python3-requests

    # paho-mqtt — preferir pip si no está en repos como paquete del sistema
    if ! python3 -c "import paho.mqtt" &>/dev/null 2>&1; then
        _log_info_fn "[deps/pi3b] Instalando paho-mqtt via pip3"
        if ! $_DRY_RUN; then
            pip3 install --quiet paho-mqtt \
                || _log_warn_fn "[deps/pi3b] pip3 install paho-mqtt falló — verifica manualmente"
        else
            _log_info_fn "[dry-run] pip3 install paho-mqtt"
        fi
    else
        _log_info_fn "[deps/pi3b] paho-mqtt ya disponible"
    fi

    # requests — también puede estar en el sistema
    if ! python3 -c "import requests" &>/dev/null 2>&1; then
        _log_info_fn "[deps/pi3b] Instalando requests via pip3"
        ! $_DRY_RUN && pip3 install --quiet requests \
            || _log_info_fn "[dry-run] pip3 install requests"
    fi

    _log_ok_fn "[deps/pi3b] Python + paho-mqtt + requests OK"
}

# ─── podman (para topología split_portal — portal en Pi3B) ───────────────────

install_raspi3b_podman() {
    _log_info_fn "[deps/pi3b] podman (topología split_portal)"
    if command -v podman &>/dev/null; then
        _log_info_fn "[deps/pi3b] podman ya instalado: $(podman --version 2>/dev/null)"
        return 0
    fi
    _apt_install_pkgs_fn podman uidmap slirp4netns fuse-overlayfs
    command -v podman &>/dev/null \
        && _log_ok_fn "[deps/pi3b] podman: $(podman --version 2>/dev/null)" \
        || _log_warn_fn "[deps/pi3b] podman no pudo instalarse"
}

# ─── Instalador completo ──────────────────────────────────────────────────────

install_raspi3b_all_deps() {
    local with_podman="${1:-false}"

    install_raspi3b_base
    install_raspi3b_capture
    install_raspi3b_python
    $with_podman && install_raspi3b_podman || true
}
