"""
sse.py — Broadcaster de Server-Sent Events.
Un queue asyncio por cliente conectado. broadcast() envía a todos.
"""
from __future__ import annotations

import asyncio
import json
import logging
from typing import Any

log = logging.getLogger("sse")

# Registro global de colas por cliente SSE
_queues: list[asyncio.Queue] = []
_lock = asyncio.Lock()


async def register() -> asyncio.Queue:
    q: asyncio.Queue = asyncio.Queue(maxsize=64)
    async with _lock:
        _queues.append(q)
    log.debug(f"SSE client conectado. Total: {len(_queues)}")
    return q


async def unregister(q: asyncio.Queue):
    async with _lock:
        try:
            _queues.remove(q)
        except ValueError:
            pass
    log.debug(f"SSE client desconectado. Total: {len(_queues)}")


async def broadcast(data: dict | str):
    """Envía evento a todos los clientes SSE conectados."""
    if isinstance(data, dict):
        payload = json.dumps(data, ensure_ascii=False)
    else:
        payload = data

    async with _lock:
        dead = []
        for q in _queues:
            try:
                q.put_nowait(payload)
            except asyncio.QueueFull:
                dead.append(q)

        for q in dead:
            _queues.remove(q)
            log.debug("SSE client eliminado (queue llena)")


def broadcast_sync(data: dict | str):
    """
    Versión síncrona para llamar desde threads (worker, MQTT).
    Crea una tarea en el event loop del main thread.
    """
    import threading
    payload = json.dumps(data, ensure_ascii=False) if isinstance(data, dict) else data

    # Thread-safe: publicar en el loop principal
    try:
        loop = asyncio.get_event_loop()
        if loop.is_running():
            asyncio.run_coroutine_threadsafe(broadcast(payload), loop)
    except Exception as exc:
        log.debug(f"broadcast_sync: {exc}")
