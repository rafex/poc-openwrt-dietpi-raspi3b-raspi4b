"""
sse_route.py — Endpoint de Server-Sent Events para el dashboard en tiempo real.
GET /events
"""
from __future__ import annotations

import asyncio
import logging

from fastapi import APIRouter
from sse_starlette.sse import EventSourceResponse

from ..sse import register, unregister

log = logging.getLogger("sse_route")
router = APIRouter()


async def _event_generator(queue: asyncio.Queue):
    """Genera eventos SSE desde la cola del cliente."""
    try:
        while True:
            payload = await queue.get()
            yield {"data": payload}
    except asyncio.CancelledError:
        log.debug("SSE stream cancelado por el cliente")
    finally:
        await unregister(queue)


@router.get("/events")
async def sse_stream():
    """
    Stream de Server-Sent Events.
    Cada mensaje es un JSON con campo 'event' que indica el tipo.

    Eventos disponibles:
    - batch_received   → llegó un nuevo batch del sensor
    - analysis_done    → análisis LLM completado
    - alert            → nueva alerta de seguridad
    - anomaly          → anomalía de tráfico detectada
    - action_executed  → política aplicada
    - worker_error     → error en el worker
    """
    queue = await register()
    return EventSourceResponse(_event_generator(queue))
