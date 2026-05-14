"""
osint.py — Enriquecimiento OSINT integrado en el backend Python.

Pipeline por cada alerta HIGH/CRITICAL:
  1. PhomberRunner  → ejecuta phomber via subprocess, captura stdout, strip ANSI
  2. BingDorker     → búsquedas via SearchAPI.io con operadores Bing exclusivos (ip:X)
  3. OsintLLM       → pasa texto PHOMBER + snippets Bing al LLM (temp=0.05)
                      El LLM extrae JSON estructurado — no hace falta parser frágil
  4. OsintStore     → persiste en SQLite con TTL por fuente
  5. broadcast_sync → notifica dashboard via SSE

Decisión de diseño — LLM como parser:
  PHOMBER retorna tablas ASCII. Tras strip ANSI son texto plano legible.
  El LLM (incluso TinyLlama 1.1B) entiende estas tablas perfectamente.
  Temperatura 0.05 → extracción de hechos determinista, sin "creatividad".
  Si PHOMBER cambia su formato, el LLM se adapta solo — cero mantenimiento.

Bing via SearchAPI.io:
  La Bing Web Search API fue retirada en agosto 2025.
  SearchAPI.io actúa como proxy y acepta todos los operadores Bing en 'q',
  incluyendo el exclusivo 'ip:X.X.X.X' (reverse-IP lookup de Bing).
  Sin SEARCH_API_TOKEN → sólo PHOMBER (modo degradado, completamente funcional).

Uso:
  from app.osint import OsintOrchestrator
  orchestrator = OsintOrchestrator()
  orchestrator.enrich(batch_id=1, alert_id=5, source_ip="185.220.101.47",
                       domain="malware.cc", mac=None)

  # Test desde línea de comandos (modo standalone):
  python3 -m app.osint --ip 185.220.101.47 --domain malware.cc
"""
from __future__ import annotations

import json
import logging
import re
import subprocess
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from typing import Any

import requests

from .config import (
    BING_API_KEY, BING_ENDPOINT,
    GROQ_API_KEY, GROQ_ENDPOINT, GROQ_MODEL, GROQ_TIMEOUT,
    LLAMA_URL, LLAMA_TIMEOUT, MODEL_FORMAT,
    OSINT_LLM_TIMEOUT, OSINT_MAX_WORKERS, OSINT_MIN_SEVERITY,
    PHOMBER_TIMEOUT, PROTECTED_IPS, USE_GROQ,
)
from . import database as db
from .sse import broadcast_sync

log = logging.getLogger("osint")

# ── Constantes ────────────────────────────────────────────────────────────────

# Prefijos de IPs privadas — nunca se consultan a APIs externas
_LAN_PREFIXES = (
    "10.", "172.16.", "172.17.", "172.18.", "172.19.", "172.20.",
    "172.21.", "172.22.", "172.23.", "172.24.", "172.25.", "172.26.",
    "172.27.", "172.28.", "172.29.", "172.30.", "172.31.",
    "192.168.", "127.", "169.254.", "::1", "fc", "fd",
)

# TTL de caché por fuente (segundos)
_TTL: dict[str, int] = {
    "phomber-ip":    60 * 60 * 24,       # 24 h  (geoloc/ASN estable)
    "phomber-mac":   60 * 60 * 24 * 30,  # 30 d  (vendor MAC permanente)
    "phomber-dns":   60 * 60 * 6,        # 6 h   (DNS puede cambiar)
    "phomber-whois": 60 * 60 * 72,       # 72 h  (WHOIS cambia poco)
    "bing-dork":     60 * 60 * 24 * 7,   # 7 d   (reputación web estable)
}

# Rango de severidades para trigger OSINT
_SEVERITY_RANK = {"LOW": 1, "MEDIUM": 2, "HIGH": 3, "CRITICAL": 4}

# Elimina códigos de escape ANSI del stdout de PHOMBER
_ANSI_RE = re.compile(r"\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])")

# Pool de hilos compartido para tareas OSINT concurrentes
_executor = ThreadPoolExecutor(max_workers=OSINT_MAX_WORKERS, thread_name_prefix="osint")


# ── Helpers ───────────────────────────────────────────────────────────────────

def _strip_ansi(text: str) -> str:
    return _ANSI_RE.sub("", text)

def _is_private_ip(ip: str) -> bool:
    """Devuelve True si la IP es privada/loopback — no consultar APIs externas."""
    return any(ip.startswith(p) for p in _LAN_PREFIXES)

def _is_protected(ip: str) -> bool:
    return ip in PROTECTED_IPS

def _expires_at(source: str) -> str:
    ttl = _TTL.get(source, 86400)
    return (datetime.now(timezone.utc) + timedelta(seconds=ttl)).isoformat()

def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


# ── PhomberRunner ─────────────────────────────────────────────────────────────

class PhomberRunner:
    """
    Ejecuta PHOMBER como subprocess, piping comandos a stdin.
    Retorna el stdout limpio (sin ANSI) para pasarlo directamente al LLM.

    PHOMBER es un shell interactivo. Protocolo:
      stdin  → "<command> <target>\\nexit\\n"
      stdout ← tablas ASCII con info de la herramienta
      No necesitamos parsear — el LLM lee tablas ASCII perfectamente.
    """

    SUPPORTED = frozenset({"ip", "mac", "whois", "dns"})

    def __init__(self, timeout: int = PHOMBER_TIMEOUT):
        self.timeout    = timeout
        self._available = self._detect()

    def _detect(self) -> bool:
        for cmd in (["phomber", "--version"], ["python3", "-m", "phomber", "--version"]):
            try:
                subprocess.run(cmd, capture_output=True, text=True, timeout=5)
                log.info("PHOMBER detectado")
                return True
            except (FileNotFoundError, subprocess.TimeoutExpired, OSError):
                pass
        log.warning("PHOMBER no encontrado. Instala con: pip install phomber")
        return False

    @property
    def available(self) -> bool:
        return self._available

    def run(self, command: str, target: str) -> str:
        """
        Envía '<command> <target>\\nexit\\n' a stdin de phomber.
        Retorna stdout completo limpio de ANSI.
        """
        if command not in self.SUPPORTED:
            return f"[Error] Comando no soportado: {command!r}. Usa: {sorted(self.SUPPORTED)}"
        if not self._available:
            return "[Error] PHOMBER no disponible en este sistema"

        log.debug(f"PHOMBER {command} {target}")
        try:
            proc = subprocess.Popen(
                ["phomber"],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                encoding="utf-8",
                errors="replace",
            )
            stdout, _ = proc.communicate(
                input=f"{command} {target}\nexit\n",
                timeout=self.timeout,
            )
            clean = _strip_ansi(stdout).strip()
            return clean or f"[Sin output de PHOMBER para {command} {target}]"

        except subprocess.TimeoutExpired:
            proc.kill()
            log.warning(f"PHOMBER timeout {command} {target} ({self.timeout}s)")
            return f"[Timeout] phomber {command} {target} excedió {self.timeout}s"
        except Exception as exc:
            log.error(f"PHOMBER error: {exc}")
            return f"[Error] phomber {command} {target}: {exc}"

    # ── Métodos de alto nivel ──────────────────────────────────────────────────

    def scan_ip(self, ip: str) -> str:
        if _is_private_ip(ip) or _is_protected(ip):
            return f"[Omitido] {ip} es IP privada/protegida"
        return self.run("ip", ip)

    def scan_mac(self, mac: str) -> str:
        return self.run("mac", mac)

    def scan_whois(self, domain: str) -> str:
        return self.run("whois", domain)

    def scan_dns(self, target: str) -> str:
        return self.run("dns", target)


# ── BingDorker ────────────────────────────────────────────────────────────────

class BingDorker:
    """
    Búsquedas Bing vía SearchAPI.io.
    La Bing Web Search API fue retirada en agosto 2025.
    SearchAPI.io soporta todos los operadores Bing (incluyendo 'ip:X.X.X.X').
    Sin SEARCH_API_TOKEN → devuelve listas vacías (modo degradado).

    El operador 'ip:X.X.X.X' es EXCLUSIVO de Bing — revela todos los dominios
    co-hospedados en esa IP y menciones en páginas web indexadas.
    """

    # Templates de búsqueda por tipo de indicador
    _TEMPLATES: dict[str, str] = {
        "ip_reputation": 'ip:{target} malware OR botnet OR scanner OR "tor exit" OR "abuse report"',
        "ip_cohost":     "ip:{target}",
        "domain_rep":    '"{target}" malware OR phishing OR "command and control" OR IOC OR "threat report"',
        "domain_sec":    'site:abuse.ch OR site:urlhaus.abuse.ch OR site:virustotal.com "{target}"',
        "domain_paste":  'site:pastebin.com OR site:github.com "{target}"',
    }

    def __init__(self):
        self.api_key   = BING_API_KEY
        self.endpoint  = BING_ENDPOINT
        self.available = bool(BING_API_KEY)
        if not self.available:
            log.info("Bing dorks deshabilitados — configura SEARCH_API_TOKEN (SearchAPI.io)")

    def _search(self, query: str, count: int = 5) -> list[dict]:
        """Llama a SearchAPI.io y retorna lista de {title, url, snippet}."""
        if not self.available:
            return []
        try:
            resp = requests.get(
                self.endpoint,
                params={"engine": "bing", "q": query, "count": count, "api_key": self.api_key},
                timeout=15,
                headers={"Accept": "application/json"},
            )
            resp.raise_for_status()
            data = resp.json()
            # SearchAPI.io puede devolver 'organic_results' o formato Bing nativo
            raw = data.get("organic_results") or data.get("webPages", {}).get("value", [])
            return [
                {
                    "title":   r.get("title") or r.get("name", ""),
                    "url":     r.get("link")  or r.get("url",  ""),
                    "snippet": r.get("snippet", ""),
                }
                for r in raw[:count]
            ]
        except Exception as exc:
            log.warning(f"Bing dork error ({query[:60]}): {exc}")
            return []

    def dork_ip(self, ip: str) -> list[dict]:
        """Busca reputación de una IP pública usando operadores Bing."""
        if _is_private_ip(ip) or _is_protected(ip):
            return []
        results = self._search(self._TEMPLATES["ip_reputation"].format(target=ip))
        if not results:
            # Fallback: co-hosting puro (sin palabras clave de malware)
            results = self._search(self._TEMPLATES["ip_cohost"].format(target=ip), count=3)
        return results

    def dork_domain(self, domain: str) -> list[dict]:
        """Busca reputación de un dominio en fuentes de threat intelligence."""
        results  = self._search(self._TEMPLATES["domain_rep"].format(target=domain))
        results += self._search(self._TEMPLATES["domain_sec"].format(target=domain), count=3)
        # Deduplicar por URL
        seen, unique = set(), []
        for r in results:
            if r["url"] not in seen:
                seen.add(r["url"])
                unique.append(r)
        return unique[:7]


# ── OsintLLM ─────────────────────────────────────────────────────────────────

class OsintLLM:
    """
    Envía al LLM:
      - Contexto de la alerta (tipo, severidad, IP, dominio)
      - Texto limpio de PHOMBER (tablas ASCII) — el LLM las lee sin parser
      - Snippets de Bing (opcional)

    Retorna JSON estructurado con risk, indicators, findings y summary_es.
    Temperatura 0.05 → extracción de hechos determinista.

    Compatible con llama.cpp local (TinyLlama 1.1B) y Groq.
    Para llama.cpp: el prompt usa el formato del modelo configurado en MODEL_FORMAT.
    """

    _SYSTEM = (
        "Eres un analista SOC experto en OSINT (Open Source Intelligence). "
        "Recibirás datos en texto plano de herramientas de reconocimiento. "
        "Tu tarea es extraer información de seguridad relevante. "
        "Responde SIEMPRE con JSON válido, sin markdown, sin explicaciones adicionales."
    )

    _JSON_SCHEMA = """{
  "risk": "BAJO|MEDIO|ALTO|CRÍTICO",
  "indicators": {
    "ip_country": null,
    "ip_isp": null,
    "ip_org": null,
    "ip_is_tor": false,
    "ip_is_datacenter": false,
    "mac_vendor": null,
    "domain_age_days": null,
    "domain_registrar": null,
    "domain_country": null,
    "dns_reverse": null,
    "known_malicious": false
  },
  "bing_findings": [],
  "key_findings": ["hallazgo clave 1", "hallazgo clave 2"],
  "recommended_action": "block|monitor|alert|none",
  "confidence": 0.75,
  "summary_es": "Resumen en español de 2-3 oraciones con los hallazgos principales."
}"""

    def analyze(self, alert: dict, phomber_outputs: dict[str, str],
                bing_snippets: list[dict]) -> dict[str, Any]:
        """
        Construye el prompt con todo el contexto OSINT y llama al LLM.
        Retorna el JSON parseado o un dict de error.
        """
        user_prompt = self._build_prompt(alert, phomber_outputs, bing_snippets)
        raw = self._call_llm(user_prompt)
        return self._parse(raw)

    def _build_prompt(self, alert: dict, phomber_outputs: dict[str, str],
                      bing_snippets: list[dict]) -> str:
        lines = [
            "Analiza los datos OSINT siguientes y extrae información de seguridad.\n",
            "═══ ALERTA DETECTADA ═══",
            f"Tipo       : {alert.get('alert_type', 'unknown')}",
            f"Severidad  : {alert.get('severity', 'unknown')}",
            f"Fuente IP  : {alert.get('source_ip', 'N/A')}",
            f"Dominio    : {alert.get('domain', 'N/A')}",
            f"Timestamp  : {alert.get('timestamp', 'N/A')}",
            f"Descripción: {alert.get('message', 'N/A')}",
            "",
        ]

        # Output de PHOMBER — texto tal como sale tras strip ANSI.
        # El LLM lee las tablas ASCII directamente. No hace falta parseador.
        for scan_type, output in phomber_outputs.items():
            if output and not output.startswith("[Omitido]") and not output.startswith("[Error]"):
                lines.append(f"═══ PHOMBER {scan_type.upper()} ═══")
                lines.append(output)
                lines.append("")

        # Snippets Bing — texto plano con title, URL y extracto
        if bing_snippets:
            lines.append("═══ BING OSINT (reputación web) ═══")
            for s in bing_snippets:
                lines.append(f"· {s.get('title', '')}")
                lines.append(f"  URL     : {s.get('url', '')}")
                lines.append(f"  Extracto: {s.get('snippet', '')}")
            lines.append("")

        lines.append("═══ INSTRUCCIÓN ═══")
        lines.append("Extrae la información de seguridad y responde ÚNICAMENTE con este JSON:")
        lines.append(self._JSON_SCHEMA)

        return "\n".join(lines)

    def _call_llm(self, user_prompt: str) -> str:
        if USE_GROQ:
            return self._call_groq(user_prompt)
        return self._call_llama(user_prompt)

    def _call_groq(self, user_prompt: str) -> str:
        try:
            resp = requests.post(
                GROQ_ENDPOINT,
                headers={
                    "Authorization": f"Bearer {GROQ_API_KEY}",
                    "Content-Type": "application/json",
                },
                json={
                    "model":       GROQ_MODEL,
                    "temperature": 0.05,
                    "max_tokens":  512,
                    "messages": [
                        {"role": "system", "content": self._SYSTEM},
                        {"role": "user",   "content": user_prompt},
                    ],
                },
                timeout=GROQ_TIMEOUT,
            )
            resp.raise_for_status()
            return resp.json()["choices"][0]["message"]["content"].strip()
        except Exception as exc:
            log.error(f"Groq OSINT error: {exc}")
            return ""

    def _call_llama(self, user_prompt: str) -> str:
        """
        Llama a llama.cpp local con el formato de prompt del modelo configurado.
        Compatible con TinyLlama, Qwen, ChatML.
        Temperatura 0.05 → extracción determinista (no creatividad).
        """
        fmt = MODEL_FORMAT.lower()
        if fmt == "qwen":
            full = (
                f"<|im_start|>system\n{self._SYSTEM}<|im_end|>\n"
                f"<|im_start|>user\n{user_prompt}<|im_end|>\n"
                f"<|im_start|>assistant\n"
            )
            stop = ["<|im_end|>", "<|im_start|>"]
        elif fmt == "chatml":
            full = (
                f"<|system|>\n{self._SYSTEM}\n"
                f"<|user|>\n{user_prompt}\n"
                f"<|assistant|>\n"
            )
            stop = ["<|user|>", "<|system|>"]
        else:
            # tinyllama / llama2 default
            full = (
                f"<|system|>\n{self._SYSTEM}<|end|>\n"
                f"<|user|>\n{user_prompt}<|end|>\n"
                f"<|assistant|>\n"
            )
            stop = ["<|end|>", "<|user|>", "</s>"]

        try:
            resp = requests.post(
                f"{LLAMA_URL}/completion",
                json={
                    "prompt":      full,
                    "temperature": 0.05,
                    "n_predict":   512,
                    "stop":        stop,
                },
                timeout=OSINT_LLM_TIMEOUT,
            )
            resp.raise_for_status()
            return resp.json().get("content", "").strip()
        except Exception as exc:
            log.error(f"llama.cpp OSINT error: {exc}")
            return ""

    def _parse(self, raw: str) -> dict[str, Any]:
        if not raw:
            return {"error": "LLM no retornó respuesta", "risk": "BAJO"}
        # Buscar el primer objeto JSON completo en el texto
        match = re.search(r"\{[\s\S]*\}", raw)
        if not match:
            log.warning(f"LLM OSINT no retornó JSON: {raw[:200]}")
            return {"error": "JSON no encontrado", "risk": "BAJO", "raw": raw[:500]}
        try:
            return json.loads(match.group(0))
        except json.JSONDecodeError as exc:
            log.warning(f"JSON inválido del LLM OSINT: {exc}")
            return {"error": str(exc), "risk": "BAJO", "raw": raw[:500]}


# ── OsintOrchestrator ─────────────────────────────────────────────────────────

class OsintOrchestrator:
    """
    Orquesta el pipeline completo: PHOMBER → Bing → LLM → SQLite → SSE.

    Uso desde el worker:
        orchestrator = OsintOrchestrator()
        orchestrator.enrich(batch_id=1, alert_id=5,
                            source_ip="185.220.101.47",
                            domain="malware.cc",
                            mac=None)

    El método `enrich()` se llama de forma síncrona desde un hilo del ThreadPoolExecutor,
    por lo que no bloquea el worker principal.
    """

    def __init__(self):
        self._phomber = PhomberRunner()
        self._bing    = BingDorker()
        self._llm     = OsintLLM()

    @property
    def phomber_available(self) -> bool:
        return self._phomber.available

    def enrich(self, batch_id: int | None, alert_id: int | None,
               source_ip: str | None, domain: str | None,
               mac: str | None) -> dict[str, Any]:
        """
        Ejecuta el pipeline completo OSINT para un conjunto de indicadores.
        Persiste en BD y notifica al dashboard via SSE.
        Retorna el dict del LLM o {} si no hay nada que enriquecer.
        """
        # Construir alerta sintética para el LLM (puede venir de análisis o alert)
        alert_ctx: dict = {
            "alert_type": "osint_enrichment",
            "severity":   "HIGH",
            "source_ip":  source_ip or "",
            "domain":     domain or "",
            "message":    f"Enriquecimiento OSINT batch={batch_id} alert={alert_id}",
            "timestamp":  _now_iso(),
        }
        if alert_id:
            alerts = db.osint_pending_alerts(OSINT_MIN_SEVERITY)
            match  = next((a for a in alerts if a["id"] == alert_id), None)
            if match:
                alert_ctx.update(match)

        phomber_outputs: dict[str, str] = {}
        bing_snippets:   list[dict]     = []

        # ── Scans PHOMBER ──────────────────────────────────────────────────────
        if source_ip and not _is_private_ip(source_ip) and not _is_protected(source_ip):
            source_key = "phomber-ip"
            if not db.osint_is_cached(source_ip, source_key):
                phomber_outputs["ip"]  = self._phomber.scan_ip(source_ip)
                phomber_outputs["dns"] = self._phomber.scan_dns(source_ip)
                self._save(alert_id, batch_id, source_ip, "ip", source_key,
                           phomber_raw=phomber_outputs.get("ip", ""),
                           bing_raw=[], llm_result={})
            if self._bing.available and not db.osint_is_cached(source_ip, "bing-dork"):
                bing_snippets += self._bing.dork_ip(source_ip)

        if domain:
            whois_key = "phomber-whois"
            if not db.osint_is_cached(domain, whois_key):
                phomber_outputs["whois"] = self._phomber.scan_whois(domain)
                phomber_outputs["dns"]   = phomber_outputs.get("dns") or self._phomber.scan_dns(domain)
            if self._bing.available and not db.osint_is_cached(domain, "bing-dork"):
                bing_snippets += self._bing.dork_domain(domain)

        if mac:
            mac_key = "phomber-mac"
            if not db.osint_is_cached(mac, mac_key):
                phomber_outputs["mac"] = self._phomber.scan_mac(mac)

        if not phomber_outputs and not bing_snippets:
            log.debug(f"OSINT: todo en caché batch={batch_id} alert={alert_id}")
            return {}

        # ── LLM: extrae JSON del contexto OSINT ───────────────────────────────
        log.info(f"OSINT LLM: {list(phomber_outputs.keys())} + {len(bing_snippets)} snippets Bing")
        llm_result = self._llm.analyze(alert_ctx, phomber_outputs, bing_snippets)

        risk       = llm_result.get("risk", "BAJO")
        summary_es = llm_result.get("summary_es", "")

        # ── Persistir resultados por indicador ────────────────────────────────
        primary_target = source_ip or domain or mac or "unknown"
        primary_type   = "ip" if source_ip else ("domain" if domain else "mac")
        primary_source = f"phomber-{primary_type}"

        self._save(
            alert_id   = alert_id,
            batch_id   = batch_id,
            target     = primary_target,
            target_type= primary_type,
            source     = primary_source,
            phomber_raw= "\n\n".join(
                f"[{k.upper()}]\n{v}" for k, v in phomber_outputs.items() if v
            ),
            bing_raw   = bing_snippets,
            llm_result = llm_result,
        )

        # Guardar Bing dork por separado si hubo snippets
        if bing_snippets and source_ip and not _is_private_ip(source_ip):
            self._save(alert_id, batch_id, source_ip, "ip", "bing-dork",
                       phomber_raw="", bing_raw=bing_snippets, llm_result={})
        if bing_snippets and domain:
            self._save(alert_id, batch_id, domain, "domain", "bing-dork",
                       phomber_raw="", bing_raw=bing_snippets, llm_result={})

        # ── Notificar dashboard ───────────────────────────────────────────────
        broadcast_sync({
            "event":      "osint_done",
            "batch_id":   batch_id,
            "alert_id":   alert_id,
            "target":     primary_target,
            "risk":       risk,
            "summary_es": summary_es,
            "timestamp":  _now_iso(),
        })

        log.info(
            f"OSINT completado: target={primary_target} risk={risk} "
            f"batch={batch_id} alert={alert_id}"
        )
        return llm_result

    def _save(self, alert_id, batch_id, target, target_type, source,
              phomber_raw, bing_raw, llm_result):
        try:
            db.osint_insert(
                alert_id   = alert_id,
                batch_id   = batch_id,
                target     = target,
                target_type= target_type,
                source     = source,
                phomber_raw= phomber_raw,
                bing_raw   = bing_raw,
                llm_result = llm_result,
                risk       = llm_result.get("risk", "BAJO") if isinstance(llm_result, dict) else "BAJO",
                summary_es = llm_result.get("summary_es", "") if isinstance(llm_result, dict) else "",
                expires_at = _expires_at(source),
            )
        except Exception as exc:
            log.error(f"Error guardando OSINT: {exc}")

    # ── API de enriquecimiento asíncrono (fire-and-forget) ────────────────────

    def enrich_async(self, batch_id: int | None, alert_id: int | None,
                     source_ip: str | None, domain: str | None,
                     mac: str | None = None):
        """
        Lanza el enriquecimiento en el ThreadPoolExecutor.
        No bloquea — retorna Future inmediatamente.
        """
        return _executor.submit(
            self.enrich,
            batch_id=batch_id,
            alert_id=alert_id,
            source_ip=source_ip,
            domain=domain,
            mac=mac,
        )


# ── Singleton ─────────────────────────────────────────────────────────────────
# Instancia compartida por el worker y los endpoints REST
_orchestrator: OsintOrchestrator | None = None

def get_orchestrator() -> OsintOrchestrator:
    global _orchestrator
    if _orchestrator is None:
        _orchestrator = OsintOrchestrator()
    return _orchestrator


# ── CLI para testing standalone ───────────────────────────────────────────────

if __name__ == "__main__":
    import argparse, sys

    logging.basicConfig(
        level=logging.DEBUG,
        format="%(asctime)s [%(name)s] %(levelname)s %(message)s",
        stream=sys.stdout,
    )

    parser = argparse.ArgumentParser(description="Test OSINT pipeline standalone")
    parser.add_argument("--ip",     help="IP pública a enriquecer")
    parser.add_argument("--domain", help="Dominio a enriquecer")
    parser.add_argument("--mac",    help="MAC a enriquecer")
    args = parser.parse_args()

    if not any([args.ip, args.domain, args.mac]):
        parser.print_help()
        sys.exit(1)

    db.init_db()
    orch = OsintOrchestrator()
    result = orch.enrich(
        batch_id  = None,
        alert_id  = None,
        source_ip = args.ip,
        domain    = args.domain,
        mac       = args.mac,
    )
    print("\n═══ RESULTADO LLM ═══")
    print(json.dumps(result, ensure_ascii=False, indent=2))
