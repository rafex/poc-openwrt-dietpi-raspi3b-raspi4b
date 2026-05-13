"""
main.py — Punto de entrada FastAPI del AI Analyzer v2.

Ciclo de vida:
  startup  → init BD → start worker thread → start MQTT client
  shutdown → stop MQTT → (worker es daemon, termina solo)

Endpoints:
  GET  /                       → redirect /health
  GET  /health                 → estado del servicio
  GET  /events                 → SSE stream (dashboard en tiempo real)
  POST /api/ingest             → ingestión de batches vía HTTP
  GET  /api/analyses           → historial de análisis LLM
  GET  /api/alerts             → alertas de seguridad
  GET  /api/actions            → acciones de política ejecutadas
  GET  /api/anomalies          → anomalías de tráfico detectadas
  GET  /api/stats              → estadísticas del sistema
  GET  /api/profiles           → perfiles de dispositivos
  GET  /api/profiles/{ip}      → perfil de un dispositivo
  GET  /api/whitelist          → lista blanca de dominios
  POST /api/whitelist          → agregar dominio a lista blanca
  DEL  /api/whitelist/{domain} → quitar dominio de lista blanca
  POST /api/chat               → chat interactivo con LLM
  GET  /api/chat/history       → historial de sesión de chat
  DEL  /api/chat/session       → borrar sesión de chat
  GET  /api/portal/risk-message → mensaje de riesgo para portal cautivo
"""
from __future__ import annotations

import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from .config import LOG_LEVEL, PORT
from . import database as db
from .worker import start_worker
from .mqtt_consumer import start_mqtt, stop_mqtt

# ── Logging ───────────────────────────────────────────────────────────────────
logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format="%(asctime)s %(levelname)-8s %(name)s  %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
)
log = logging.getLogger("main")

# ── Routers ───────────────────────────────────────────────────────────────────
from .routes.health    import router as health_router
from .routes.ingest    import router as ingest_router
from .routes.analyses  import router as analyses_router
from .routes.alerts    import router as alerts_router
from .routes.actions   import router as actions_router
from .routes.anomalies import router as anomalies_router
from .routes.chat      import router as chat_router
from .routes.whitelist import router as whitelist_router
from .routes.profiles  import router as profiles_router
from .routes.stats     import router as stats_router
from .routes.portal    import router as portal_router
from .routes.sse_route import router as sse_router


# ── Lifespan ──────────────────────────────────────────────────────────────────
@asynccontextmanager
async def lifespan(app: FastAPI):
    """Inicialización y limpieza del ciclo de vida de la aplicación."""
    log.info("🚀 AI Analyzer v2 arrancando…")

    # 1. Inicializar base de datos
    log.info("Inicializando SQLite…")
    db.init_db()

    # 2. Arrancar worker en hilo de fondo
    log.info("Iniciando worker de análisis…")
    start_worker()

    # 3. Conectar al broker MQTT
    log.info("Conectando a MQTT…")
    start_mqtt()

    log.info(f"✅ Listo. Escuchando en :{PORT}")
    yield

    # Shutdown
    log.info("🛑 Deteniendo AI Analyzer v2…")
    stop_mqtt()
    log.info("Bye.")


# ── Aplicación FastAPI ────────────────────────────────────────────────────────
app = FastAPI(
    title="AI Analyzer v2",
    description=(
        "Backend de análisis de tráfico de red WiFi con LLM. "
        "Detecta amenazas, clasifica dispositivos y genera alertas en tiempo real."
    ),
    version="2.0.0",
    lifespan=lifespan,
    docs_url="/docs",
    redoc_url="/redoc",
)

# CORS — permitir frontend Vite en desarrollo y cualquier origen en producción
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

# ── Registrar rutas ───────────────────────────────────────────────────────────
app.include_router(health_router)
app.include_router(sse_router)
app.include_router(ingest_router)
app.include_router(analyses_router)
app.include_router(alerts_router)
app.include_router(actions_router)
app.include_router(anomalies_router)
app.include_router(chat_router)
app.include_router(whitelist_router)
app.include_router(profiles_router)
app.include_router(stats_router)
app.include_router(portal_router)

log.debug("Rutas registradas:")
for route in app.routes:
    if hasattr(route, "methods") and hasattr(route, "path"):
        log.debug(f"  {', '.join(route.methods):8s} {route.path}")
