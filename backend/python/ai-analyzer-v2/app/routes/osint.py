"""
osint.py — Endpoints REST para enriquecimientos OSINT.
GET  /api/osint?limit=50&target=X  → lista sin campos raw voluminosos
GET  /api/osint/{id}               → detalle completo con phomber_raw + bing_raw + llm_result
POST /api/osint/enrich             → dispara enriquecimiento manual para IP o dominio
"""
from __future__ import annotations

import logging

from fastapi import APIRouter, HTTPException, Path, Query
from pydantic import BaseModel

from .. import database as db
from ..osint import get_orchestrator

log = logging.getLogger("routes.osint")
router = APIRouter(prefix="/api")


class EnrichRequest(BaseModel):
    source_ip: str | None = None
    domain:    str | None = None
    mac:       str | None = None
    batch_id:  int | None = None
    alert_id:  int | None = None


@router.get("/osint")
async def list_osint(
    limit: int = Query(50, ge=1, le=500),
    target: str | None = Query(None, description="Filtrar por IP o dominio"),
):
    """
    Devuelve los enriquecimientos OSINT más recientes.
    Los campos phomber_raw, bing_raw y llm_result se omiten para reducir tamaño.
    Usa GET /api/osint/{id} para el detalle completo.
    """
    return db.osint_list_recent(limit=limit, target=target)


@router.get("/osint/{enrichment_id}")
async def get_osint(
    enrichment_id: int = Path(..., description="ID del enriquecimiento"),
):
    """
    Devuelve el detalle completo de un enriquecimiento OSINT:
    - phomber_raw: stdout de PHOMBER limpio de ANSI
    - bing_raw:    snippets de Bing [{title, url, snippet}]
    - llm_result:  JSON extraído por el LLM con indicadores y hallazgos
    """
    data = db.osint_get_detail(enrichment_id)
    if not data:
        raise HTTPException(status_code=404, detail=f"Enriquecimiento {enrichment_id} no encontrado")
    return data


@router.post("/osint/enrich", status_code=202)
async def enrich_manual(body: EnrichRequest):
    """
    Dispara un enriquecimiento OSINT manual para una IP, dominio o MAC.
    El proceso corre en background — usa GET /api/osint para ver los resultados.
    """
    if not any([body.source_ip, body.domain, body.mac]):
        raise HTTPException(
            status_code=400,
            detail="Debes proporcionar al menos: source_ip, domain o mac",
        )

    orch = get_orchestrator()
    future = orch.enrich_async(
        batch_id  = body.batch_id,
        alert_id  = body.alert_id,
        source_ip = body.source_ip,
        domain    = body.domain,
        mac       = body.mac,
    )

    log.info(
        f"Enriquecimiento OSINT manual lanzado: "
        f"ip={body.source_ip} domain={body.domain} mac={body.mac}"
    )

    return {
        "status":    "queued",
        "message":   "Enriquecimiento OSINT iniciado en background",
        "source_ip": body.source_ip,
        "domain":    body.domain,
        "mac":       body.mac,
    }
