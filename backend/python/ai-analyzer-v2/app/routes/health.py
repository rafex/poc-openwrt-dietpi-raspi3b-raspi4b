"""
health.py — Endpoints de estado del servicio.
GET /        → redirect a /health
GET /health  → JSON con estado, versión y conteos básicos
"""
from __future__ import annotations

from fastapi import APIRouter
from fastapi.responses import RedirectResponse

from .. import database as db
from ..worker import work_queue

router = APIRouter()

_VERSION = "2.0.0"


@router.get("/", include_in_schema=False)
async def root():
    return RedirectResponse(url="/health")


@router.get("/health")
async def health():
    try:
        batches   = db.batch_count()
        analyses  = db.analysis_count()
        pending   = db.batch_count_pending()
        queue_len = work_queue.qsize()
        status    = "ok"
    except Exception as exc:
        return {
            "status": "error",
            "error":  str(exc),
            "version": _VERSION,
        }

    return {
        "status":           status,
        "version":          _VERSION,
        "batches_total":    batches,
        "analyses_total":   analyses,
        "batches_pending":  pending,
        "queue_length":     queue_len,
    }
