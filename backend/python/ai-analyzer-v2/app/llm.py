"""
llm.py — Cliente LLM unificado: Groq (prioridad) o llama.cpp local (fallback).

Groq  → rápido (~1s), requiere GROQ_API_KEY e internet
llama → lento (~15-45s en Pi 4B), completamente local, sin API key

Temperatura:
  0.4  → análisis SOC (algo de variabilidad para detectar patrones distintos)
  0.1  → decisión de política (casi determinista)
  0.6  → explicación humana (lenguaje natural)
  0.75 → chat (respuestas naturales)
  0.05 → extracción OSINT (totalmente determinista)
"""
from __future__ import annotations

import logging
import re
from typing import Any

import requests

from .config import (
    GROQ_API_KEY, GROQ_ENDPOINT, GROQ_MODEL, GROQ_MAX_TOKENS, GROQ_TIMEOUT,
    LLAMA_URL, LLAMA_N_PREDICT, LLAMA_TIMEOUT, MODEL_FORMAT, USE_GROQ,
    PROTECTED_IPS,
)

log = logging.getLogger("llm")

# ── Prompts del sistema ───────────────────────────────────────────────────────

SYSTEM_SOC = (
    "Eres analista SOC para red WiFi pública. "
    f"IPs de infraestructura que NUNCA debes recomendar bloquear: {', '.join(sorted(PROTECTED_IPS))}. "
    "Analiza el tráfico de red y responde en español con: "
    "1) Riesgo (BAJO/MEDIO/ALTO) "
    "2) 2-3 hallazgos accionables "
    "3) Recomendación breve."
)

SYSTEM_POLICY = (
    "Eres motor de decisiones de seguridad. "
    "Tu salida debe ser ÚNICAMENTE JSON válido, sin markdown, sin explicaciones. "
    f"IPs protegidas que nunca debes bloquear: {', '.join(sorted(PROTECTED_IPS))}."
)

SYSTEM_HUMAN = (
    "Eres un experto en comunicar conceptos técnicos de seguridad de red "
    "en lenguaje sencillo para personas no técnicas. "
    "Responde en español en máximo 4 líneas."
)

SYSTEM_CHAT = (
    "Eres asistente de seguridad de red WiFi. "
    "Tienes acceso al contexto de la red actual. "
    "Responde en español de forma clara y concisa."
)

# ── Builders de prompt por formato de modelo ──────────────────────────────────

def _build_prompt(system: str, user: str) -> str:
    fmt = MODEL_FORMAT.lower()
    if fmt == "qwen":
        return (
            f"<|im_start|>system\n{system}<|im_end|>\n"
            f"<|im_start|>user\n{user}<|im_end|>\n"
            f"<|im_start|>assistant\n"
        )
    if fmt == "chatml":
        return (
            f"<|system|>\n{system}\n"
            f"<|user|>\n{user}\n"
            f"<|assistant|>\n"
        )
    # default: tinyllama / llama2
    return (
        f"<|system|>\n{system}<|end|>\n"
        f"<|user|>\n{user}<|end|>\n"
        f"<|assistant|>\n"
    )

# ── Groq ──────────────────────────────────────────────────────────────────────

def _groq_chat(messages: list[dict], temperature: float, max_tokens: int) -> str:
    try:
        resp = requests.post(
            GROQ_ENDPOINT,
            headers={
                "Authorization": f"Bearer {GROQ_API_KEY}",
                "Content-Type":  "application/json",
            },
            json={
                "model":       GROQ_MODEL,
                "temperature": temperature,
                "max_tokens":  max_tokens,
                "messages":    messages,
            },
            timeout=GROQ_TIMEOUT,
        )
        resp.raise_for_status()
        return resp.json()["choices"][0]["message"]["content"].strip()
    except Exception as exc:
        log.error(f"Groq error: {exc}")
        return f"[Error Groq: {exc}]"

# ── llama.cpp ─────────────────────────────────────────────────────────────────

def _llama_complete(prompt: str, temperature: float, n_predict: int) -> str:
    try:
        resp = requests.post(
            f"{LLAMA_URL}/completion",
            json={
                "prompt":      prompt,
                "temperature": temperature,
                "n_predict":   n_predict,
                "stop":        ["<|end|>", "<|user|>", "<|im_end|>", "</s>"],
            },
            timeout=LLAMA_TIMEOUT,
        )
        resp.raise_for_status()
        return resp.json().get("content", "").strip()
    except Exception as exc:
        log.error(f"llama.cpp error: {exc}")
        return f"[Error llama.cpp: {exc}]"

# ── API pública ───────────────────────────────────────────────────────────────

def analyze_traffic(traffic_summary: str) -> str:
    """Análisis SOC del tráfico de red. Temperatura 0.4."""
    if USE_GROQ:
        return _groq_chat([
            {"role": "system", "content": SYSTEM_SOC},
            {"role": "user",   "content": traffic_summary},
        ], temperature=0.4, max_tokens=512)
    return _llama_complete(
        _build_prompt(SYSTEM_SOC, traffic_summary),
        temperature=0.4, n_predict=LLAMA_N_PREDICT,
    )

def decide_policy(context: str) -> str:
    """Decisión de política (block/unblock/none). Temperatura 0.1."""
    if USE_GROQ:
        return _groq_chat([
            {"role": "system", "content": SYSTEM_POLICY},
            {"role": "user",   "content": context},
        ], temperature=0.1, max_tokens=128)
    return _llama_complete(
        _build_prompt(SYSTEM_POLICY, context),
        temperature=0.1, n_predict=64,
    )

def explain_human(traffic_summary: str) -> str:
    """Explicación en lenguaje humano. Temperatura 0.6."""
    user_prompt = (
        "Resume en español para humanos la actividad de red en máximo 4 líneas. "
        "Incluye: dispositivo principal, dominios dominantes, "
        "nivel de actividad y riesgo práctico.\n\n"
        f"Datos:\n{traffic_summary}"
    )
    if USE_GROQ:
        return _groq_chat([
            {"role": "system", "content": SYSTEM_HUMAN},
            {"role": "user",   "content": user_prompt},
        ], temperature=0.6, max_tokens=200)
    return _llama_complete(
        _build_prompt(SYSTEM_HUMAN, user_prompt),
        temperature=0.6, n_predict=150,
    )

def chat_answer(question: str, history: list[dict], context: str = "") -> str:
    """Respuesta de chat interactivo. Temperatura 0.75."""
    if USE_GROQ:
        messages = [{"role": "system", "content": SYSTEM_CHAT}]
        if context:
            messages.append({"role": "system", "content": f"Contexto de red:\n{context}"})
        for msg in history[-6:]:  # últimos 6 mensajes de historial
            messages.append({"role": msg["role"], "content": msg["content"]})
        messages.append({"role": "user", "content": question})
        return _groq_chat(messages, temperature=0.75, max_tokens=GROQ_MAX_TOKENS)

    # llama.cpp: construir historial como texto
    hist_text = "\n".join(
        f"{'Usuario' if m['role']=='user' else 'Asistente'}: {m['content']}"
        for m in history[-4:]
    )
    user_content = f"{hist_text}\nUsuario: {question}" if hist_text else question
    if context:
        user_content = f"Contexto:\n{context}\n\n{user_content}"
    return _llama_complete(
        _build_prompt(SYSTEM_CHAT, user_content),
        temperature=0.75, n_predict=LLAMA_N_PREDICT,
    )

# ── Extracción de risk del texto ──────────────────────────────────────────────

def extract_risk(text: str) -> str:
    upper = text.upper()
    if any(w in upper for w in ("ALTO", "HIGH", "CRÍTICO", "CRITICO", "CRITICAL")):
        return "ALTO"
    if any(w in upper for w in ("MEDIO", "MEDIUM", "MODERADO")):
        return "MEDIO"
    return "BAJO"

# ── Extracción de JSON del texto (para política) ──────────────────────────────

def extract_json(text: str) -> dict[str, Any]:
    match = re.search(r"\{[^{}]+\}", text, re.DOTALL)
    if match:
        try:
            import json
            return json.loads(match.group(0))
        except Exception:
            pass
    return {}
