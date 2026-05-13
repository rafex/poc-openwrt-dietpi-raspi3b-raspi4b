"""
anomalies.py — Anomalías de tráfico detectadas por Z-score.
GET /api/anomalies?limit=50
GET /api/anomalies?device_ip=192.168.1.50&limit=50
"""
from __future__ import annotations

from fastapi import APIRouter, Query

from .. import database as db

router = APIRouter(prefix="/api")


@router.get("/anomalies")
async def list_anomalies(
    limit: int = Query(50, ge=1, le=500),
    device_ip: str | None = Query(None, description="Filtrar por IP del dispositivo"),
):
    """Devuelve anomalías detectadas, opcionalmente filtradas por dispositivo."""
    if device_ip:
        return db.anomaly_list_by_device(device_ip, limit)
    return db.anomaly_list_recent(limit)
