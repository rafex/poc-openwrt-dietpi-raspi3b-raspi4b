"""
analyses.py — Historial de análisis LLM.
GET /api/analyses?limit=20
"""
from __future__ import annotations

from fastapi import APIRouter, Query

from .. import database as db

router = APIRouter(prefix="/api")


@router.get("/analyses")
async def list_analyses(limit: int = Query(20, ge=1, le=200)):
    """Devuelve los análisis más recientes ordenados por más nuevo primero."""
    return db.analysis_list_recent(limit)
