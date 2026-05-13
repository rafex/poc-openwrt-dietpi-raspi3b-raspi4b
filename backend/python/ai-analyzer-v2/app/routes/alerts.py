"""
alerts.py — Alertas de red detectadas.
GET /api/alerts?limit=50&severity=HIGH
"""
from __future__ import annotations

from fastapi import APIRouter, Query

from .. import database as db

router = APIRouter(prefix="/api")


@router.get("/alerts")
async def list_alerts(
    limit: int = Query(50, ge=1, le=500),
    severity: str | None = Query(None, description="Filtrar por severidad: LOW, MEDIUM, HIGH, CRITICAL"),
):
    """Devuelve alertas de red recientes, opcionalmente filtradas por severidad."""
    alerts = db.alert_list_recent(limit)
    if severity:
        alerts = [a for a in alerts if a.get("severity", "").upper() == severity.upper()]
    return alerts
