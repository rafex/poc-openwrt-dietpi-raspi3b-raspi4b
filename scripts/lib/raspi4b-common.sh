#!/bin/bash
# Common utilities for Raspi4B setup scripts.

set -u

DRY_RUN=false
ONLY_VERIFY=false
FORCE=false
NO_BUILD=false

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
  [ "$APT_UPDATED" -eq 1 ] && return 0
  run_cmd env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none NEEDRESTART_MODE=a \
    apt-get -o Acquire::Retries=3 -o DPkg::Lock::Timeout=120 update
  APT_UPDATED=1
}

apt_install_pkgs() {
  [ "$#" -gt 0 ] || return 0
  apt_update_once
  run_cmd env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none NEEDRESTART_MODE=a \
    apt-get -y -q --no-install-recommends \
      -o Acquire::Retries=3 \
      -o DPkg::Lock::Timeout=120 \
      -o Dpkg::Options::=--force-confdef \
      -o Dpkg::Options::=--force-confold \
      install "$@"
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
  if ! ps aux | grep -q '[k]3s server'; then
    die "k3s no está corriendo"
  fi
  run_cmd k3s kubectl get nodes >/dev/null
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
