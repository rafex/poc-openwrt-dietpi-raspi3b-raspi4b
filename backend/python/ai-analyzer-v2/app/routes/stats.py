"""
stats.py — Estadísticas agregadas del sistema.
GET /api/stats
"""
from __future__ import annotations

from fastapi import APIRouter

from .. import database as db
from ..worker import work_queue

router = APIRouter(prefix="/api")


@router.get("/stats")
async def get_stats():
    """Devuelve conteos y estadísticas generales para el dashboard."""
    risk_counts  = db.analysis_count_by_risk()
    alert_counts = db.alert_count_by_severity()

    return {
        "batches": {
            "total":   db.batch_count(),
            "pending": db.batch_count_pending(),
        },
        "analyses": {
            "total":   db.analysis_count(),
            "by_risk": risk_counts,
        },
        "alerts": {
            "by_severity": alert_counts,
            "total":       sum(alert_counts.values()),
        },
        "anomalies": {
            "total": len(db.anomaly_list_recent(1000)),
        },
        "profiles": {
            "total": len(db.device_profile_list()),
        },
        "actions": {
            "total": len(db.action_list_recent(1000)),
        },
        "worker": {
            "queue_length": work_queue.qsize(),
        },
    }
