"""
config.py — Configuración centralizada vía variables de entorno.
Un solo lugar para todos los parámetros del backend.
"""
from __future__ import annotations
import os

def _bool(key: str, default: str = "true") -> bool:
    return os.environ.get(key, default).lower() in ("1", "true", "yes")

def _int(key: str, default: int) -> int:
    try:
        return int(os.environ.get(key, str(default)))
    except ValueError:
        return default

# ── Red y topología ───────────────────────────────────────────────────────────
MQTT_HOST          = os.environ.get("MQTT_HOST",      "192.168.1.167")
MQTT_PORT          = _int("MQTT_PORT",                1883)
MQTT_TOPIC         = os.environ.get("MQTT_TOPIC",     "rafexpi/sensor/batch")
PORT               = _int("PORT",                     5000)
ROUTER_IP          = os.environ.get("ROUTER_IP",      "192.168.1.1")
RASPI4B_IP         = os.environ.get("RASPI4B_IP",     "192.168.1.167")
RASPI3B_IP         = os.environ.get("RASPI3B_IP",     "192.168.1.181")
PORTAL_IP          = os.environ.get("PORTAL_IP",      "192.168.1.167")
ADMIN_IP           = os.environ.get("ADMIN_IP",       "192.168.1.113")
PORTAL_NODE_IP     = os.environ.get("PORTAL_NODE_IP", "192.168.1.182")
AP_EXTENDER_IP     = os.environ.get("AP_EXTENDER_IP", "192.168.1.183")

# IPs de infraestructura — nunca bloquear
PROTECTED_IPS: frozenset[str] = frozenset(filter(None, [
    ROUTER_IP, RASPI4B_IP, RASPI3B_IP, PORTAL_IP,
    ADMIN_IP, PORTAL_NODE_IP, AP_EXTENDER_IP,
]))

# ── Base de datos ─────────────────────────────────────────────────────────────
DB_PATH = os.environ.get("DB_PATH", "/data/sensor.db")

# ── LLM — llama.cpp local ─────────────────────────────────────────────────────
LLAMA_URL       = os.environ.get("LLAMA_URL",    "http://192.168.1.167:8081")
LLAMA_N_PREDICT = _int("N_PREDICT",              256)
LLAMA_TIMEOUT   = _int("LLAMA_TIMEOUT",          45)
MODEL_FORMAT    = os.environ.get("MODEL_FORMAT", "tinyllama")  # tinyllama | qwen | chatml

# ── LLM — Groq (prioridad si GROQ_API_KEY presente) ──────────────────────────
GROQ_API_KEY   = os.environ.get("GROQ_API_KEY", "")
GROQ_MODEL     = os.environ.get("GROQ_MODEL",   "llama-3.1-8b-instant")
GROQ_ENDPOINT  = "https://api.groq.com/openai/v1/chat/completions"
GROQ_MAX_TOKENS = _int("GROQ_MAX_TOKENS",        1024)
GROQ_TIMEOUT    = _int("GROQ_TIMEOUT",           30)
USE_GROQ        = bool(GROQ_API_KEY)

# ── Feature flags ─────────────────────────────────────────────────────────────
FEATURE_CHAT           = _bool("FEATURE_CHAT",           "true")
FEATURE_HUMAN_EXPLAIN  = _bool("FEATURE_HUMAN_EXPLAIN",  "true")
FEATURE_DEVICE_PROFILING = _bool("FEATURE_DEVICE_PROFILING", "true")
FEATURE_AUTO_ENFORCE   = _bool("FEATURE_AUTO_ENFORCE",   "false")  # SSH al router
FEATURE_DOMAIN_CLF     = _bool("FEATURE_DOMAIN_CLASSIFIER", "true")

# ── Políticas sociales ────────────────────────────────────────────────────────
SOCIAL_BLOCK_HOUR_START = _int("SOCIAL_POLICY_START_HOUR", 9)
SOCIAL_BLOCK_HOUR_END   = _int("SOCIAL_POLICY_END_HOUR",   17)
SOCIAL_MIN_HITS         = _int("SOCIAL_MIN_HITS",           3)

# ── Dominios de redes sociales ────────────────────────────────────────────────
SOCIAL_DOMAINS: frozenset[str] = frozenset({
    "facebook.com", "fbcdn.net", "messenger.com",
    "instagram.com", "cdninstagram.com",
    "twitter.com", "x.com", "twimg.com",
    "tiktok.com", "tiktokcdn.com", "byteoversea.com",
    "youtube.com", "youtu.be", "googlevideo.com", "ytimg.com",
    "linkedin.com", "licdn.com",
    "snapchat.com", "sc-cdn.net",
    "whatsapp.com", "whatsapp.net",
})

# ── Puertos de riesgo ─────────────────────────────────────────────────────────
RISKY_PORTS: frozenset[int] = frozenset({
    22, 23, 3389, 445, 1433, 3306, 5900, 5984, 6379, 27017
})

# ── Logging ───────────────────────────────────────────────────────────────────
LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO").upper()
