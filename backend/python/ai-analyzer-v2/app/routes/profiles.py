"""
profiles.py — Perfiles de dispositivos detectados en la red.
GET /api/profiles
GET /api/profiles/{ip}
"""
from __future__ import annotations

from fastapi import APIRouter, HTTPException, Path

from .. import database as db

router = APIRouter(prefix="/api")


@router.get("/profiles")
async def list_profiles():
    """Devuelve todos los perfiles de dispositivos conocidos."""
    return db.device_profile_list()


@router.get("/profiles/{ip}")
async def get_profile(ip: str = Path(..., description="IP del dispositivo")):
    """Devuelve el perfil de un dispositivo específico."""
    profiles = db.device_profile_list()
    for p in profiles:
        if p.get("ip") == ip:
            return p
    raise HTTPException(status_code=404, detail=f"Perfil para IP '{ip}' no encontrado")
