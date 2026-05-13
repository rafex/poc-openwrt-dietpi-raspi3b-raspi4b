"""
portal.py — Mensaje de riesgo para el portal cautivo.
GET /api/portal/risk-message  → texto corto para mostrar en el portal WiFi
"""
from __future__ import annotations

from fastapi import APIRouter

from .. import database as db

router = APIRouter(prefix="/api")

_MESSAGES = {
    "ALTO":  ("HIGH",   "⚠️ Red con actividad sospechosa detectada. Úsala con precaución."),
    "MEDIO": ("MEDIUM", "🔶 Actividad moderada en la red. Navega con cuidado."),
    "BAJO":  ("LOW",    "✅ Red estable. Sin amenazas detectadas en este momento."),
}


@router.get("/portal/risk-message")
async def risk_message():
    """
    Devuelve el mensaje de riesgo actual para el portal cautivo.
    Basado en el último análisis LLM.
    """
    recent = db.analysis_list_recent(1)

    if not recent:
        return {
            "risk":    "UNKNOWN",
            "level":   "UNKNOWN",
            "message": "Sin datos de análisis aún.",
            "color":   "gray",
        }

    last  = recent[0]
    risk  = last.get("risk", "BAJO").upper()
    level, message = _MESSAGES.get(risk, _MESSAGES["BAJO"])

    colors = {"HIGH": "red", "MEDIUM": "orange", "LOW": "green"}

    return {
        "risk":      risk,
        "level":     level,
        "message":   message,
        "color":     colors.get(level, "gray"),
        "timestamp": last.get("timestamp"),
        "analysis":  last.get("analysis", "")[:200],
    }
