#!/bin/bash
# Common utilities for Raspi4B setup scripts.

set -u

DRY_RUN=false
ONLY_VERIFY=false
FORCE=false
NO_BUILD=false
APT_CACHE_DIR=""
APT_CACHE_FILE=""

init_demo_cache() {
  local home_dir="${HOME:-/root}"
  local cache_base="${home_dir}/.cache"
  local cache_dir="${cache_base}/demo-openwrt"
  mkdir -p "$cache_dir" 2>/dev/null || true
  APT_CACHE_DIR="$cache_dir"
  APT_CACHE_FILE="${APT_CACHE_DIR}/apt-installed.txt"
  touch "$APT_CACHE_FILE" 2>/dev/null || true
}

init_log_dir() {
  local component="$1"
  local base="/var/log/demo-openwrt/${component}"
  if mkdir -p "$base" 2>/dev/null && [ -w "$base" ]; then
    LOG_DIR="${LOG_DIR:-$base}"
  else
    base="/tmp/demo-openwrt/${component}"
    mkdir -p "$base" 2>/dev/null || true
    LOG_DIR="${LOG_DIR:-$base}"
  fi
  mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR="/tmp/demo-openwrt/${component}"
  mkdir -p "$LOG_DIR"
  LOG_FILE="$LOG_DIR/$(basename "$0" .sh)-$(date '+%Y%m%d-%H%M%S').log"

  if [ -z "${SETUP_LOG_INITIALIZED:-}" ]; then
    SETUP_LOG_INITIALIZED=1
    export SETUP_LOG_INITIALIZED
    if command -v tee >/dev/null 2>&1 && command -v mkfifo >/dev/null 2>&1; then
      LOG_PIPE="/tmp/$(basename "$0" .sh)-$$.logpipe"
      mkfifo "$LOG_PIPE"
      tee -a "$LOG_FILE" < "$LOG_PIPE" &
      LOG_TEE_PID=$!
      exec > "$LOG_PIPE" 2>&1
      cleanup_common_logging() {
        rc=$?
        trap - EXIT INT TERM
        exec 1>&- 2>&-
        wait "$LOG_TEE_PID" 2>/dev/null || true
        rm -f "$LOG_PIPE"
        exit "$rc"
      }
      trap cleanup_common_logging EXIT INT TERM
    else
      exec >> "$LOG_FILE" 2>&1
    fi
  fi

  log_info "Log file: $LOG_FILE"
}

log_info()  { printf '[INFO]  %s\n' "$*"; }
log_ok()    { printf '[OK]    %s\n' "$*"; }
log_warn()  { printf '[WARN]  %s\n' "$*"; }
log_error() { printf '[ERROR] %s\n' "$*" >&2; }
die()       { log_error "$*"; exit 1; }

need_root() {
  [ "${EUID:-$(id -u)}" -eq 0 ] || die "Ejecutar como root"
}

ensure_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "Comando requerido no encontrado: $c"
  done
}

run_cmd() {
  if $DRY_RUN; then
    log_info "[dry-run] $*"
    return 0
  fi
  "$@"
}

APT_UPDATED=0
apt_update_once() {
  init_demo_cache
  [ "$APT_UPDATED" -eq 1 ] && return 0
  run_cmd env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none NEEDRESTART_MODE=a \
    apt-get -o Acquire::Retries=3 -o DPkg::Lock::Timeout=120 update
  APT_UPDATED=1
}

apt_install_pkgs() {
  init_demo_cache
  [ "$#" -gt 0 ] || return 0
  local pkg missing=() updated_cache=0

  for pkg in "$@"; do
    if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
      if [ -f "$APT_CACHE_FILE" ] && ! grep -qx "$pkg" "$APT_CACHE_FILE" 2>/dev/null; then
        printf '%s\n' "$pkg" >> "$APT_CACHE_FILE"
      fi
      continue
    fi
    missing+=("$pkg")
  done

  if [ "${#missing[@]}" -eq 0 ]; then
    log_info "apt cache hit: paquetes ya instalados (${#@}) en $APT_CACHE_DIR"
    return 0
  fi

  apt_update_once
  run_cmd env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none NEEDRESTART_MODE=a \
    apt-get -y -q --no-install-recommends \
      -o Acquire::Retries=3 \
      -o DPkg::Lock::Timeout=120 \
      -o Dpkg::Options::=--force-confdef \
      -o Dpkg::Options::=--force-confold \
      install "${missing[@]}"

  for pkg in "${missing[@]}"; do
    if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
      if [ -f "$APT_CACHE_FILE" ] && ! grep -qx "$pkg" "$APT_CACHE_FILE" 2>/dev/null; then
        printf '%s\n' "$pkg" >> "$APT_CACHE_FILE"
        updated_cache=1
      fi
    fi
  done
  if [ "$updated_cache" -eq 1 ]; then
    log_info "apt cache actualizado: $APT_CACHE_FILE"
  fi
}

parse_common_flags() {
  POSITIONAL=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) DRY_RUN=true ;;
      --only-verify) ONLY_VERIFY=true ;;
      --force) FORCE=true ;;
      --no-build) NO_BUILD=true ;;
      *) POSITIONAL+=("$1") ;;
    esac
    shift
  done
  set -- "${POSITIONAL[@]}"
  REM_ARGS=("$@")
}

ensure_k3s_ready() {
  local sock="/run/k3s/containerd/containerd.sock"
  local waited=0
  local max_s=90    # máx segundos esperando a containerd
  local max_k=120   # máx segundos esperando a kubectl

  # ── 1. Arrancar k3s si el servicio no está activo ──────────────────────────
  if ! systemctl is-active --quiet k3s 2>/dev/null; then
    log_warn "k3s no está activo — intentando arrancar el servicio..."
    systemctl start k3s 2>/dev/null || die "No se pudo arrancar k3s (systemctl start k3s falló)"
    sleep 3
  fi

  # ── 2. Esperar socket containerd (/run/k3s/containerd/containerd.sock) ─────
  # k3s embebe containerd propio; el socket solo existe mientras k3s corre.
  while [ ! -S "$sock" ] && [ "$waited" -lt "$max_s" ]; do
    log_info "  [${waited}s/${max_s}s] Esperando socket containerd..."
    sleep 5; waited=$((waited + 5))
  done
  if [ ! -S "$sock" ]; then
    log_error "Socket containerd no disponible tras ${max_s}s: $sock"
    log_error "Estado del servicio k3s:"
    systemctl status k3s --no-pager -l 2>/dev/null | tail -20 >&2 || true
    log_error "Si k3s no arranca, ejecuta: bash scripts/raspi4b-k3s-doctor.sh"
    die "k3s containerd no listo"
  fi
  log_ok "Socket containerd listo (${waited}s): $sock"

  # ── 3. Esperar a que kubectl responda ──────────────────────────────────────
  waited=0
  while ! k3s kubectl get nodes >/dev/null 2>&1 && [ "$waited" -lt "$max_k" ]; do
    log_info "  [${waited}s/${max_k}s] Esperando kubectl..."
    sleep 5; waited=$((waited + 5))
  done
  k3s kubectl get nodes >/dev/null 2>&1 || \
    die "kubectl no responde tras ${max_k}s — revisa: journalctl -u k3s -n 50"

  log_ok "k3s listo (nodo: $(k3s kubectl get nodes --no-headers 2>/dev/null | awk '{print $1}'))"
  run_cmd k3s kubectl get nodes
}

ensure_portal_ssh_key() {
  local key="/opt/keys/captive-portal"
  local pub="${key}.pub"
  run_cmd mkdir -p /opt/keys
  if [ ! -f "$key" ]; then
    run_cmd ssh-keygen -t ed25519 -f "$key" -N "" -C "captive-portal@rafexpi"
    log_ok "Llave SSH generada: $key"
  else
    log_info "Llave SSH ya existe: $key"
  fi
  run_cmd chmod 600 "$key"
  run_cmd chmod 644 "$pub"
}
