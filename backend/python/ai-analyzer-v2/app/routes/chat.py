"""
chat.py — Chat interactivo con el LLM sobre el estado de la red.
POST   /api/chat
GET    /api/chat/history?session_id=X&limit=20
DELETE /api/chat/session?session_id=X
"""
from __future__ import annotations

import logging
import uuid

from fastapi import APIRouter, HTTPException, Query
from pydantic import BaseModel

from .. import database as db
from ..llm import chat_answer
from ..config import FEATURE_CHAT

log = logging.getLogger("chat")
router = APIRouter(prefix="/api")


class ChatRequest(BaseModel):
    question: str
    session_id: str | None = None
    include_context: bool = True


@router.post("/chat")
async def chat(body: ChatRequest):
    """Responde preguntas sobre el estado de la red usando el LLM."""
    if not FEATURE_CHAT:
        raise HTTPException(status_code=503, detail="Chat deshabilitado (FEATURE_CHAT=false)")

    if not body.question or not body.question.strip():
        raise HTTPException(status_code=400, detail="La pregunta no puede estar vacía")

    session_id = body.session_id or str(uuid.uuid4())
    db.chat_session_upsert(session_id)

    # Historial de mensajes previos
    history = db.chat_history(session_id, limit=10)

    # Contexto de red actual (últimos análisis)
    context = ""
    if body.include_context:
        recent = db.analysis_list_recent(3)
        if recent:
            parts = []
            for r in recent:
                parts.append(
                    f"- [{r['timestamp']}] Riesgo: {r['risk']} | {r['analysis'][:300]}"
                )
            context = "Últimos análisis de red:\n" + "\n".join(parts)

    try:
        answer = chat_answer(
            question=body.question.strip(),
            history=history,
            context=context,
        )
    except Exception as exc:
        log.error(f"Error LLM chat: {exc}", exc_info=True)
        raise HTTPException(status_code=502, detail=f"Error LLM: {exc}")

    # Persistir pregunta y respuesta
    db.chat_message_insert(session_id, "user",      body.question.strip())
    db.chat_message_insert(session_id, "assistant", answer)

    return {
        "session_id": session_id,
        "answer":     answer,
        "question":   body.question.strip(),
    }


@router.get("/chat/history")
async def chat_history(
    session_id: str = Query(..., description="ID de sesión"),
    limit: int = Query(20, ge=1, le=100),
):
    """Devuelve el historial de mensajes de una sesión."""
    if not FEATURE_CHAT:
        raise HTTPException(status_code=503, detail="Chat deshabilitado")
    return db.chat_history(session_id, limit)


@router.delete("/chat/session")
async def clear_session(session_id: str = Query(..., description="ID de sesión a borrar")):
    """Borra el historial de una sesión de chat."""
    if not FEATURE_CHAT:
        raise HTTPException(status_code=503, detail="Chat deshabilitado")
    db.chat_session_clear(session_id)
    return {"status": "ok", "session_id": session_id}
