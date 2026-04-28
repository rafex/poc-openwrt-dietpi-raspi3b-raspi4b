#!/bin/bash
# lib/raspi4b-deps.sh — Funciones de instalación de dependencias para Raspi4B
#
# USAGE (como librería en otro script):
#   . "$SCRIPT_DIR/lib/raspi4b-common.sh"   # debe sourciarse ANTES
#   . "$SCRIPT_DIR/lib/raspi4b-deps.sh"
#
#   install_raspi4b_base       # curl wget git ca-certs gnupg jq python3 ...
#   install_raspi4b_podman     # podman uidmap slirp4netns fuse-overlayfs
#   install_raspi4b_mosquitto  # mosquitto mosquitto-clients
#   install_raspi4b_age_sops   # age (apt) + sops (binario arm64 GitHub)
#   install_raspi4b_node       # Node.js 20 LTS via NodeSource
#   install_raspi4b_all_deps   # llama todas las anteriores
#
# Depende de: apt_install_pkgs, apt_update_once, run_cmd, log_info, log_ok, log_warn
# (definidas en lib/raspi4b-common.sh)

# Versiones fijadas (actualizar aquí cuando sea necesario)
_SOPS_VERSION="${SOPS_VERSION:-3.9.1}"
_AGE_VERSION="${AGE_VERSION:-1.1.1}"
_NODE_MAJOR="${NODE_MAJOR:-20}"

# ─── Base del sistema ─────────────────────────────────────────────────────────

install_raspi4b_base() {
    log_info "[deps/pi4b] Paquetes base del sistema"
    apt_install_pkgs \
        apt-transport-https \
        ca-certificates \
        curl \
        wget \
        git \
        gnupg \
        lsb-release \
        jq \
        python3 \
        python3-minimal \
        openssh-client \
        cron \
        make \
        systemd-sysv \
        iproute2 \
        net-tools \
        dnsutils \
        iputils-ping \
        less \
        procps \
        htop
    log_ok "[deps/pi4b] Paquetes base OK"
}

# ─── podman ──────────────────────────────────────────────────────────────────

install_raspi4b_podman() {
    log_info "[deps/pi4b] podman"
    if command -v podman &>/dev/null; then
        log_info "[deps/pi4b] podman ya instalado: $(podman --version 2>/dev/null)"
        return 0
    fi
    apt_install_pkgs podman uidmap slirp4netns fuse-overlayfs
    if ! $DRY_RUN; then
        podman info &>/dev/null 2>&1 \
            && log_ok "[deps/pi4b] podman: $(podman --version 2>/dev/null)" \
            || log_warn "[deps/pi4b] podman instalado pero 'podman info' falla"
    fi
}

# ─── Mosquitto MQTT ───────────────────────────────────────────────────────────

install_raspi4b_mosquitto() {
    log_info "[deps/pi4b] mosquitto"
    apt_install_pkgs mosquitto mosquitto-clients
    log_ok "[deps/pi4b] mosquitto OK"
}

# ─── age + sops (secretos) ────────────────────────────────────────────────────

install_raspi4b_age() {
    log_info "[deps/pi4b] age"
    if command -v age &>/dev/null; then
        log_info "[deps/pi4b] age ya instalado: $(age --version 2>/dev/null | head -1)"
        return 0
    fi

    # Intentar desde los repos primero
    if apt_install_pkgs age 2>/dev/null && command -v age &>/dev/null; then
        log_ok "[deps/pi4b] age (apt): $(age --version 2>/dev/null | head -1)"
        return 0
    fi

    # Fallback — binario oficial arm64
    log_warn "[deps/pi4b] age no en repos — descargando binario arm64 v${_AGE_VERSION}"
    if ! $DRY_RUN; then
        run_cmd curl -fsSL \
            "https://github.com/FiloSottile/age/releases/download/v${_AGE_VERSION}/age-v${_AGE_VERSION}-linux-arm64.tar.gz" \
            -o /tmp/age.tar.gz
        tar -xzf /tmp/age.tar.gz -C /usr/local/bin --strip-components=1 age/age age/age-keygen
        rm -f /tmp/age.tar.gz
        chmod 755 /usr/local/bin/age /usr/local/bin/age-keygen
    else
        log_info "[dry-run] descargar age ${_AGE_VERSION} arm64"
    fi
    command -v age &>/dev/null \
        && log_ok "[deps/pi4b] age (binario): $(age --version 2>/dev/null | head -1)" \
        || log_warn "[deps/pi4b] age no pudo instalarse"
}

install_raspi4b_sops() {
    log_info "[deps/pi4b] sops"
    if command -v sops &>/dev/null; then
        log_info "[deps/pi4b] sops ya instalado: $(sops --version 2>/dev/null | head -1)"
        return 0
    fi
    if ! $DRY_RUN; then
        run_cmd curl -fsSL \
            "https://github.com/getsops/sops/releases/download/v${_SOPS_VERSION}/sops-v${_SOPS_VERSION}.linux.arm64" \
            -o /usr/local/bin/sops
        run_cmd chmod +x /usr/local/bin/sops
    else
        log_info "[dry-run] descargar sops ${_SOPS_VERSION} arm64"
    fi
    command -v sops &>/dev/null \
        && log_ok "[deps/pi4b] sops: $(sops --version 2>/dev/null | head -1)" \
        || log_warn "[deps/pi4b] sops no pudo instalarse"
}

install_raspi4b_age_sops() {
    install_raspi4b_age
    install_raspi4b_sops
}

# ─── Node.js 20 LTS ───────────────────────────────────────────────────────────

_raspi4b_node_version_ok() {
    command -v node &>/dev/null || return 1
    local ver; ver="$(node --version 2>/dev/null)"
    [[ "$ver" =~ ^v(${_NODE_MAJOR}|[2-9][0-9])\. ]] || return 1
}

install_raspi4b_node() {
    log_info "[deps/pi4b] Node.js ${_NODE_MAJOR} LTS"
    if _raspi4b_node_version_ok; then
        log_info "[deps/pi4b] Node.js ya instalado: $(node --version 2>/dev/null) (npm $(npm --version 2>/dev/null))"
        return 0
    fi

    if ! $DRY_RUN; then
        log_info "[deps/pi4b] Configurando repositorio NodeSource ${_NODE_MAJOR}.x"
        run_cmd curl -fsSL "https://deb.nodesource.com/setup_${_NODE_MAJOR}.x" \
            | env DEBIAN_FRONTEND=noninteractive bash -
        apt_install_pkgs nodejs
        _raspi4b_node_version_ok \
            && log_ok "[deps/pi4b] node: $(node --version 2>/dev/null) | npm: $(npm --version 2>/dev/null)" \
            || log_warn "[deps/pi4b] Node.js instalado pero versión puede no ser >= ${_NODE_MAJOR}"
    else
        log_info "[dry-run] instalar Node.js ${_NODE_MAJOR} via NodeSource"
    fi
}

# ─── Instalador completo ──────────────────────────────────────────────────────

install_raspi4b_all_deps() {
    local skip_mosquitto="${1:-false}"
    local skip_node="${2:-false}"

    install_raspi4b_base
    install_raspi4b_podman
    install_raspi4b_age_sops
    $skip_mosquitto || install_raspi4b_mosquitto
    $skip_node      || install_raspi4b_node
}
