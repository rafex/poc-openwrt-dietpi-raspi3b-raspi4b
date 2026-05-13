"""
ingest.py — Ingestión HTTP de batches del sensor.
POST /api/ingest  → persiste batch y encola para el worker
"""
from __future__ import annotations

import json
import logging

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import JSONResponse

from .. import database as db
from ..worker import work_queue
from ..sse import broadcast

log = logging.getLogger("ingest")
router = APIRouter(prefix="/api")


@router.post("/ingest", status_code=202)
async def ingest(request: Request):
    """Recibe un batch JSON del sensor y lo encola para análisis LLM."""
    try:
        raw = await request.body()
        if not raw:
            raise HTTPException(status_code=400, detail="Body vacío")

        # Validar JSON
        try:
            parsed = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise HTTPException(status_code=400, detail=f"JSON inválido: {exc}")

        sensor_ip = (
            parsed.get("sensor_ip")
            or parsed.get("source")
            or request.client.host
            or "unknown"
        )

        batch_id = db.batch_insert(sensor_ip=sensor_ip, payload=raw.decode("utf-8"))
        work_queue.put(batch_id)
        log.info(f"Batch {batch_id} recibido vía HTTP (sensor={sensor_ip})")

        await broadcast({
            "event":     "batch_received",
            "batch_id":  batch_id,
            "sensor_ip": sensor_ip,
        })

        return JSONResponse(
            status_code=202,
            content={"batch_id": batch_id, "status": "queued"},
        )

    except HTTPException:
        raise
    except Exception as exc:
        log.error(f"Error en /api/ingest: {exc}", exc_info=True)
        raise HTTPException(status_code=500, detail=str(exc))
