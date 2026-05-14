"""
whitelist.py — Gestión de dominios en lista blanca.
GET    /api/whitelist
POST   /api/whitelist           body: {"domain": "example.com", "reason": "..."}
DELETE /api/whitelist/{domain}
"""
from __future__ import annotations

import re

from fastapi import APIRouter, HTTPException, Path
from pydantic import BaseModel, field_validator

from .. import database as db

router = APIRouter(prefix="/api")

_DOMAIN_RE = re.compile(
    r"^(?:[a-zA-Z0-9](?:[a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$"
)


class WhitelistEntry(BaseModel):
    domain: str
    reason: str = ""

    @field_validator("domain")
    @classmethod
    def validate_domain(cls, v: str) -> str:
        v = v.strip().lower()
        if not _DOMAIN_RE.match(v):
            raise ValueError(f"Dominio inválido: {v!r}")
        return v


@router.get("/whitelist")
async def list_whitelist():
    """Devuelve todos los dominios en la lista blanca."""
    return db.whitelist_list()


@router.post("/whitelist", status_code=201)
async def add_to_whitelist(entry: WhitelistEntry):
    """Agrega un dominio a la lista blanca."""
    db.whitelist_add(domain=entry.domain, reason=entry.reason)
    return {"status": "ok", "domain": entry.domain}


@router.delete("/whitelist/{domain}")
async def remove_from_whitelist(
    domain: str = Path(..., description="Dominio a eliminar"),
):
    """Elimina un dominio de la lista blanca."""
    domain = domain.strip().lower()
    existing = db.whitelist_list()
    if not any(e["domain"] == domain for e in existing):
        raise HTTPException(status_code=404, detail=f"Dominio '{domain}' no encontrado")
    db.whitelist_remove(domain)
    return {"status": "ok", "domain": domain}
