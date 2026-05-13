"""
actions.py — Acciones de política ejecutadas por el worker.
GET /api/actions?limit=50
"""
from __future__ import annotations

from fastapi import APIRouter, Query

from .. import database as db

router = APIRouter(prefix="/api")


@router.get("/actions")
async def list_actions(limit: int = Query(50, ge=1, le=500)):
    """Devuelve las acciones de política más recientes."""
    return db.action_list_recent(limit)
