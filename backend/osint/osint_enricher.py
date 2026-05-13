#!/usr/bin/env python3
"""
osint_enricher.py — Sidecar OSINT para ai-analyzer (Raspberry Pi 4B)

Estrategia de integración:
  PHOMBER corre como subprocess → stdout capturado → strip ANSI → texto limpio.
  Ese texto (tablas ASCII legibles) + contexto de alerta → LLM.
  El LLM lee el formato natural de PHOMBER y extrae JSON estructurado.
  No hay parser frágil: si PHOMBER cambia su formato, el LLM se adapta solo.

Pipeline:
  network_alerts (SQLite) ── poll cada POLL_INTERVAL s ──►
    [alertas HIGH/CRITICAL sin enriquecer]
      └─► PhomberRunner (ip / mac / whois / dns)  ──► texto limpio
      └─► BingDorker    (opcional, SearchAPI.io)   ──► snippets web
      └─► OsintLlm      (Groq o llama.cpp local)  ──► JSON estructurado
      └─► OsintStore     (SQLite osint_enrichments) ──► caché TTL

Variables de entorno:
  DB_PATH            ruta a sensor.db              (default: /data/sensor.db)
  GROQ_API_KEY       clave Groq para LLM           (si vacío → llama.cpp)
  GROQ_MODEL         modelo Groq                   (default: llama-3.1-8b-instant)
  LLAMA_URL          URL llama.cpp local            (default: http://127.0.0.1:8081)
  BING_API_KEY       clave SearchAPI.io (opcional)
  BING_ENDPOINT      URL SearchAPI.io               (default: https://www.searchapi.io/api/v1/search)
  POLL_INTERVAL      segundos entre polls           (default: 30)
  MIN_SEVERITY       severidad mínima para enriquecer (default: high)
  PHOMBER_TIMEOUT    timeout por scan PHOMBER       (default: 25)
  LLM_TIMEOUT        timeout llamada LLM            (default: 60)
  DRY_RUN            solo muestra qué haría         (default: false)

Uso:
  pip install phomber requests
  python3 osint_enricher.py
  DB_PATH=/data/sensor.db GROQ_API_KEY=gsk_... python3 osint_enricher.py

Instalación como servicio systemd:
  sudo cp osint_enricher.py /opt/osint/osint_enricher.py
  sudo cp osint_enricher.service /etc/systemd/system/
  sudo systemctl enable --now osint_enricher
"""

from __future__ import annotations

import json
import logging
import os
import re
import sqlite3
import subprocess
import sys
import time
from contextlib import contextmanager
from datetime import datetime, timezone, timedelta
from typing import Optional

import requests

# ── Configuración ──────────────────────────────────────────────────────────────

DB_PATH        = os.environ.get("DB_PATH",        "/data/sensor.db")
GROQ_API_KEY   = os.environ.get("GROQ_API_KEY",   "")
GROQ_MODEL     = os.environ.get("GROQ_MODEL",     "llama-3.1-8b-instant")
GROQ_ENDPOINT  = "https://api.groq.com/openai/v1/chat/completions"
LLAMA_URL      = os.environ.get("LLAMA_URL",      "http://127.0.0.1:8081")
BING_API_KEY   = os.environ.get("BING_API_KEY",   "")
BING_ENDPOINT  = os.environ.get("BING_ENDPOINT",  "https://www.searchapi.io/api/v1/search")
POLL_INTERVAL  = int(os.environ.get("POLL_INTERVAL",  "30"))
MIN_SEVERITY   = os.environ.get("MIN_SEVERITY",   "high").lower()
PHOMBER_TIMEOUT = int(os.environ.get("PHOMBER_TIMEOUT", "25"))
LLM_TIMEOUT    = int(os.environ.get("LLM_TIMEOUT",    "60"))
DRY_RUN        = os.environ.get("DRY_RUN", "").lower() in ("1", "true", "yes")

# IPs LAN — nunca se consultan a APIs externas
LAN_PREFIXES = ("10.", "172.16.", "172.17.", "172.18.", "172.19.", "172.20.",
                "172.21.", "172.22.", "172.23.", "172.24.", "172.25.", "172.26.",
                "172.27.", "172.28.", "172.29.", "172.30.", "172.31.",
                "192.168.", "127.", "169.254.", "::1", "fc", "fd")

# Severidades que disparan enriquecimiento
SEVERITY_RANK = {"low": 1, "medium": 2, "high": 3, "critical": 4}
MIN_RANK      = SEVERITY_RANK.get(MIN_SEVERITY, 3)

# TTL de caché por fuente (segundos)
TTL = {
    "phomber-ip":    60 * 60 * 24,       # 24h  (geoloc estable)
    "phomber-mac":   60 * 60 * 24 * 30,  # 30d  (vendor permanente)
    "phomber-whois": 60 * 60 * 72,       # 72h  (WHOIS cambia poco)
    "phomber-dns":   60 * 60 * 6,        # 6h   (DNS puede cambiar)
    "bing-dork":     60 * 60 * 24 * 7,   # 7d   (reputación estable)
}

# ── Logging ────────────────────────────────────────────────────────────────────

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [OSINT] %(levelname)s %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
    stream=sys.stdout,
)
log = logging.getLogger("osint")

# ── Helpers ────────────────────────────────────────────────────────────────────

_ANSI_RE = re.compile(r"\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])")

def strip_ansi(text: str) -> str:
    """Elimina códigos de escape ANSI del output de PHOMBER."""
    return _ANSI_RE.sub("", text)

def is_lan_ip(ip: str) -> bool:
    return any(ip.startswith(p) for p in LAN_PREFIXES)

def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()

def expires_at(source: str) -> str:
    ttl_s = TTL.get(source, 86400)
    return (datetime.now(timezone.utc) + timedelta(seconds=ttl_s)).isoformat()

# ── PhomberRunner ──────────────────────────────────────────────────────────────

class PhomberRunner:
    """
    Ejecuta PHOMBER como subprocess piping comandos a stdin.
    Retorna el stdout limpio (sin ANSI) para que el LLM lo lea.

    PHOMBER es un shell interactivo: enviamos el comando + 'exit\n' a stdin
    y capturamos todo el stdout. No necesitamos parsear la salida — el LLM lo hace.
    """

    SUPPORTED = {"ip", "mac", "whois", "dns"}

    def __init__(self, timeout: int = PHOMBER_TIMEOUT):
        self.timeout = timeout
        self._available = self._check_available()

    def _check_available(self) -> bool:
        try:
            result = subprocess.run(
                ["phomber", "--version"],
                capture_output=True, text=True, timeout=5
            )
            return True
        except (FileNotFoundError, subprocess.TimeoutExpired):
            pass
        # Intentar con python3 -m phomber
        try:
            subprocess.run(
                ["python3", "-c", "import phomber"],
                capture_output=True, timeout=5
            )
            return True
        except Exception:
            pass
        log.warning("PHOMBER no encontrado — instala con: pip install phomber")
        return False

    @property
    def available(self) -> bool:
        return self._available

    def run(self, command: str, target: str) -> str:
        """
        Ejecuta: phomber  →  stdin: '<command> <target>\nexit\n'
        Retorna el stdout completo, limpio de ANSI.
        """
        if command not in self.SUPPORTED:
            return f"[Error] Comando '{command}' no soportado. Usa: {self.SUPPORTED}"

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
            stdin_payload = f"{command} {target}\nexit\n"
            stdout, stderr = proc.communicate(
                input=stdin_payload,
                timeout=self.timeout,
            )
            clean = strip_ansi(stdout).strip()
            if not clean:
                clean = f"[Sin output de PHOMBER para {command} {target}]"
            return clean

        except subprocess.TimeoutExpired:
            proc.kill()
            log.warning(f"PHOMBER timeout en {command} {target}")
            return f"[Timeout] phomber {command} {target} excedió {self.timeout}s"

        except Exception as exc:
            log.error(f"PHOMBER error: {exc}")
            return f"[Error] phomber {command} {target}: {exc}"

    def scan_ip(self, ip: str) -> str:
        if is_lan_ip(ip):
            return f"[Omitido] {ip} es IP privada — sin lookup externo"
        return self.run("ip", ip)

    def scan_mac(self, mac: str) -> str:
        return self.run("mac", mac)

    def scan_whois(self, domain: str) -> str:
        return self.run("whois", domain)

    def scan_dns(self, target: str) -> str:
        return self.run("dns", target)


# ── BingDorker ─────────────────────────────────────────────────────────────────

class BingDorker:
    """
    Búsquedas Bing vía SearchAPI.io (reemplaza la Bing API retirada en agosto 2025).
    Retorna snippets de texto para que el LLM los interprete.

    El operador 'ip:X.X.X.X' es exclusivo de Bing — revela dominios co-hospedados
    y menciones en páginas web indexadas.
    """

    DORK_TEMPLATES = {
        "ip_reputation": "ip:{target} malware OR botnet OR scanner OR \"tor exit\" OR \"abuse report\"",
        "ip_cohost":     "ip:{target}",
        "domain_rep":    "\"{target}\" malware OR phishing OR \"command and control\" OR IOC OR \"threat report\"",
        "domain_paste":  "site:pastebin.com OR site:github.com \"{target}\"",
        "domain_sec":    "site:abuse.ch OR site:virustotal.com OR site:urlhaus.abuse.ch \"{target}\"",
    }

    def __init__(self, api_key: str = BING_API_KEY, endpoint: str = BING_ENDPOINT):
        self.api_key  = api_key
        self.endpoint = endpoint
        self.available = bool(api_key)
        if not self.available:
            log.info("Bing dorks deshabilitados (BING_API_KEY no configurado)")

    def search(self, query: str, count: int = 5) -> list[dict]:
        """Retorna lista de {title, url, snippet}."""
        if not self.available:
            return []
        try:
            params = {
                "engine": "bing",
                "q":      query,
                "count":  count,
                "api_key": self.api_key,
            }
            resp = requests.get(
                self.endpoint, params=params,
                timeout=15, headers={"Accept": "application/json"}
            )
            resp.raise_for_status()
            data = resp.json()
            results = []
            for r in data.get("organic_results", data.get("webPages", {}).get("value", []))[:count]:
                results.append({
                    "title":   r.get("title", r.get("name", "")),
                    "url":     r.get("link",  r.get("url", "")),
                    "snippet": r.get("snippet", r.get("snippet", "")),
                })
            return results
        except Exception as exc:
            log.warning(f"Bing dork error: {exc}")
            return []

    def dork_ip(self, ip: str) -> list[dict]:
        if is_lan_ip(ip):
            return []
        results = self.search(self.DORK_TEMPLATES["ip_reputation"].format(target=ip))
        if not results:
            results = self.search(self.DORK_TEMPLATES["ip_cohost"].format(target=ip), count=3)
        return results

    def dork_domain(self, domain: str) -> list[dict]:
        results  = self.search(self.DORK_TEMPLATES["domain_rep"].format(target=domain))
        results += self.search(self.DORK_TEMPLATES["domain_sec"].format(target=domain), count=3)
        seen = set()
        unique = []
        for r in results:
            if r["url"] not in seen:
                seen.add(r["url"])
                unique.append(r)
        return unique[:7]


# ── OsintLlm ──────────────────────────────────────────────────────────────────

class OsintLlm:
    """
    Envía al LLM:
      - Contexto de la alerta
      - Output limpio de PHOMBER (tablas ASCII — el LLM las lee perfectamente)
      - Snippets de Bing (si disponibles)

    El LLM retorna JSON estructurado con risk + hallazgos + acción recomendada.
    Temperatura 0.05 → extracción determinista de hechos.
    """

    SYSTEM_PROMPT = (
        "Eres un analista SOC experto en OSINT. "
        "Recibirás datos de herramientas OSINT en formato texto y debes extraer "
        "información de seguridad relevante. "
        "Responde SIEMPRE con JSON válido, sin markdown, sin explicaciones adicionales."
    )

    JSON_SCHEMA = """{
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
  "key_findings": ["hallazgo 1", "hallazgo 2"],
  "recommended_action": "block|monitor|alert|none",
  "confidence": 0.0,
  "summary_es": "resumen en español de 2-3 oraciones"
}"""

    def __init__(self, timeout: int = LLM_TIMEOUT):
        self.timeout   = timeout
        self.use_groq  = bool(GROQ_API_KEY)

    def analyze(self, alert: dict, phomber_outputs: dict, bing_snippets: list) -> dict:
        """
        Construye el prompt con todo el contexto OSINT y llama al LLM.
        Retorna el JSON parseado o un dict de error.
        """
        prompt = self._build_prompt(alert, phomber_outputs, bing_snippets)
        raw = self._call_llm(prompt)
        return self._parse_response(raw)

    def _build_prompt(self, alert: dict, phomber_outputs: dict, bing_snippets: list) -> str:
        lines = [
            "Analiza los datos OSINT siguientes y extrae información de seguridad.\n",
            "═══ ALERTA DETECTADA ═══",
            f"Tipo      : {alert.get('alert_type', 'unknown')}",
            f"Severidad : {alert.get('severity', 'unknown')}",
            f"Fuente IP : {alert.get('source_ip', 'N/A')}",
            f"Dominio   : {alert.get('details_domain', 'N/A')}",
            f"Timestamp : {alert.get('timestamp', 'N/A')}",
            f"Descripción: {alert.get('description', 'N/A')}",
            "",
        ]

        # Output de PHOMBER — texto tal como sale (limpio de ANSI)
        # El LLM lee las tablas ASCII directamente, sin parseo intermedio
        for scan_type, output in phomber_outputs.items():
            if output and not output.startswith("[Omitido]"):
                lines.append(f"═══ PHOMBER {scan_type.upper()} ═══")
                lines.append(output)
                lines.append("")

        # Snippets de Bing — texto plano
        if bing_snippets:
            lines.append("═══ BING DORKS (reputación web) ═══")
            for s in bing_snippets:
                lines.append(f"· [{s.get('title','')}]")
                lines.append(f"  {s.get('url','')}")
                lines.append(f"  {s.get('snippet','')}")
            lines.append("")

        lines.append("═══ RESPUESTA REQUERIDA ═══")
        lines.append("Extrae la información y responde ÚNICAMENTE con este JSON:")
        lines.append(self.JSON_SCHEMA)

        return "\n".join(lines)

    def _call_llm(self, prompt: str) -> str:
        if self.use_groq:
            return self._call_groq(prompt)
        return self._call_llama(prompt)

    def _call_groq(self, prompt: str) -> str:
        try:
            payload = {
                "model":       GROQ_MODEL,
                "temperature": 0.05,
                "max_tokens":  512,
                "messages": [
                    {"role": "system", "content": self.SYSTEM_PROMPT},
                    {"role": "user",   "content": prompt},
                ],
            }
            resp = requests.post(
                GROQ_ENDPOINT,
                headers={
                    "Authorization": f"Bearer {GROQ_API_KEY}",
                    "Content-Type": "application/json",
                },
                json=payload,
                timeout=self.timeout,
            )
            resp.raise_for_status()
            return resp.json()["choices"][0]["message"]["content"].strip()
        except Exception as exc:
            log.error(f"Groq error: {exc}")
            return ""

    def _call_llama(self, prompt: str) -> str:
        try:
            full_prompt = (
                f"<|system|>\n{self.SYSTEM_PROMPT}<|end|>\n"
                f"<|user|>\n{prompt}<|end|>\n"
                f"<|assistant|>\n"
            )
            payload = {
                "prompt":      full_prompt,
                "temperature": 0.05,
                "n_predict":   512,
                "stop":        ["<|end|>", "<|user|>"],
            }
            resp = requests.post(
                f"{LLAMA_URL}/completion",
                json=payload,
                timeout=self.timeout,
            )
            resp.raise_for_status()
            return resp.json().get("content", "").strip()
        except Exception as exc:
            log.error(f"llama.cpp error: {exc}")
            return ""

    def _parse_response(self, raw: str) -> dict:
        if not raw:
            return {"error": "LLM no retornó respuesta", "risk": "BAJO"}

        # Extraer JSON del texto (puede tener texto antes/después)
        match = re.search(r"\{[\s\S]*\}", raw)
        if not match:
            log.warning(f"LLM no retornó JSON válido: {raw[:200]}")
            return {"error": "JSON no encontrado en respuesta LLM", "risk": "BAJO", "raw": raw[:500]}

        try:
            return json.loads(match.group(0))
        except json.JSONDecodeError as exc:
            log.warning(f"JSON inválido del LLM: {exc} — raw: {raw[:200]}")
            return {"error": str(exc), "risk": "BAJO", "raw": raw[:500]}


# ── OsintStore ─────────────────────────────────────────────────────────────────

class OsintStore:
    """
    Lee alertas de SQLite y guarda enriquecimientos OSINT.
    Usa la misma base de datos que el backend Java (WAL mode para concurrencia).
    """

    INIT_SQL = """
    CREATE TABLE IF NOT EXISTS osint_enrichments (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        alert_id    INTEGER,
        target      TEXT NOT NULL,
        target_type TEXT NOT NULL,
        source      TEXT NOT NULL,
        phomber_raw TEXT,
        bing_raw    TEXT,
        llm_result  TEXT,
        risk        TEXT,
        summary_es  TEXT,
        queried_at  TEXT NOT NULL,
        expires_at  TEXT NOT NULL,
        UNIQUE(target, target_type, source)
    );
    CREATE INDEX IF NOT EXISTS idx_osint_target
        ON osint_enrichments(target, expires_at);
    CREATE INDEX IF NOT EXISTS idx_osint_alert
        ON osint_enrichments(alert_id);
    """

    def __init__(self, db_path: str = DB_PATH):
        self.db_path = db_path
        self._init_schema()

    @contextmanager
    def _conn(self):
        conn = sqlite3.connect(self.db_path, timeout=10)
        conn.execute("PRAGMA journal_mode=WAL")
        conn.row_factory = sqlite3.Row
        try:
            yield conn
            conn.commit()
        finally:
            conn.close()

    def _init_schema(self):
        with self._conn() as conn:
            conn.executescript(self.INIT_SQL)
        log.info(f"SQLite schema OK: {self.db_path}")

    def pending_alerts(self) -> list[dict]:
        """
        Retorna alertas HIGH/CRITICAL que aún no tienen enriquecimiento vigente.
        """
        severity_list = [s for s, r in SEVERITY_RANK.items() if r >= MIN_RANK]
        placeholders = ",".join("?" * len(severity_list))
        sql = f"""
            SELECT a.id, a.timestamp, a.alert_type, a.severity,
                   a.source_ip, a.description, a.details
            FROM network_alerts a
            WHERE a.severity IN ({placeholders})
              AND NOT EXISTS (
                SELECT 1 FROM osint_enrichments e
                WHERE e.alert_id = a.id
                  AND e.expires_at > ?
              )
            ORDER BY a.id DESC
            LIMIT 20
        """
        with self._conn() as conn:
            rows = conn.execute(sql, severity_list + [now_iso()]).fetchall()
        return [dict(r) for r in rows]

    def is_cached(self, target: str, source: str) -> bool:
        sql = """
            SELECT 1 FROM osint_enrichments
            WHERE target = ? AND source = ? AND expires_at > ?
            LIMIT 1
        """
        with self._conn() as conn:
            row = conn.execute(sql, (target, source, now_iso())).fetchone()
        return row is not None

    def save(self, alert_id: int, target: str, target_type: str, source: str,
             phomber_raw: str, bing_raw: str, llm_result: dict):
        risk       = llm_result.get("risk", "BAJO")
        summary_es = llm_result.get("summary_es", "")
        llm_json   = json.dumps(llm_result, ensure_ascii=False)
        bing_json  = json.dumps(bing_raw,   ensure_ascii=False)
        sql = """
            INSERT OR REPLACE INTO osint_enrichments
                (alert_id, target, target_type, source,
                 phomber_raw, bing_raw, llm_result,
                 risk, summary_es, queried_at, expires_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?)
        """
        with self._conn() as conn:
            conn.execute(sql, (
                alert_id, target, target_type, source,
                phomber_raw, bing_json, llm_json,
                risk, summary_es, now_iso(), expires_at(source),
            ))
        log.info(f"[OSINT] Guardado: {target_type}={target} source={source} risk={risk}")


# ── Extracción de indicadores de alertas ──────────────────────────────────────

def extract_indicators(alert: dict) -> dict[str, list[str]]:
    """
    Extrae IP, MAC y dominio de una alerta.
    Retorna: {'ip': [...], 'mac': [...], 'domain': [...]}
    """
    indicators: dict[str, list[str]] = {"ip": [], "mac": [], "domain": []}

    # IP origen de la alerta
    src = alert.get("source_ip", "")
    if src and not is_lan_ip(src):
        indicators["ip"].append(src)

    # Parsear campo 'details' (JSON o texto)
    details_raw = alert.get("details", "")
    details: dict = {}
    if details_raw:
        try:
            details = json.loads(details_raw)
        except Exception:
            pass

    # IP de destino (top_destinations tienen IPs externas)
    for key in ("destination_ip", "target_ip", "dest_ip"):
        val = details.get(key, "")
        if val and not is_lan_ip(val) and val not in indicators["ip"]:
            indicators["ip"].append(val)

    # MAC
    for key in ("mac", "mac_address", "eth_src"):
        val = details.get(key, "")
        if val:
            indicators["mac"].append(val)

    # Dominio
    domain = details.get("domain", details.get("host", ""))
    if domain and domain not in indicators["domain"]:
        indicators["domain"].append(domain)

    # Extraer dominio del campo description (ej: "dga:a4f2k.ru")
    description = alert.get("description", "")
    dga_match = re.search(r"dga:([a-zA-Z0-9._-]+\.[a-zA-Z]{2,})", description)
    if dga_match:
        d = dga_match.group(1)
        if d not in indicators["domain"]:
            indicators["domain"].append(d)

    # También buscar dominios en el alert_type
    alert_type = alert.get("alert_type", "")
    if "domain" in alert_type:
        domain_in_type = re.search(r"([a-zA-Z0-9-]+\.[a-zA-Z]{2,})", description)
        if domain_in_type:
            d = domain_in_type.group(1)
            if d not in indicators["domain"]:
                indicators["domain"].append(d)

    return indicators


# ── Pipeline principal ─────────────────────────────────────────────────────────

class OsintPipeline:
    """
    Orquesta el flujo:
      alerta → indicadores → PHOMBER + Bing → LLM → SQLite
    """

    def __init__(self):
        self.phomber = PhomberRunner()
        self.bing    = BingDorker()
        self.llm     = OsintLlm()
        self.store   = OsintStore()

    def process_alert(self, alert: dict):
        alert_id    = alert["id"]
        alert_type  = alert.get("alert_type", "")
        severity    = alert.get("severity", "")
        log.info(f"[Alert #{alert_id}] tipo={alert_type} severidad={severity}")

        indicators = extract_indicators(alert)
        log.debug(f"  Indicadores: {indicators}")

        # ── Enriquecer IPs externas ────────────────────────────────────────────
        for ip in indicators["ip"]:
            source = "phomber-ip"
            if self.store.is_cached(ip, source):
                log.debug(f"  [caché] {ip} {source}")
                continue

            log.info(f"  PHOMBER ip {ip}")
            phomber_out: dict[str, str] = {}

            if not DRY_RUN:
                phomber_out["ip"]  = self.phomber.scan_ip(ip)
                phomber_out["dns"] = self.phomber.scan_dns(ip)
            else:
                phomber_out["ip"]  = "[dry-run] phomber ip " + ip
                phomber_out["dns"] = "[dry-run] phomber dns " + ip

            bing_snippets = []
            if self.bing.available and not DRY_RUN:
                bing_snippets = self.bing.dork_ip(ip)
                if bing_snippets:
                    log.info(f"  Bing: {len(bing_snippets)} resultados para ip:{ip}")

            result = {}
            if not DRY_RUN:
                result = self.llm.analyze(alert, phomber_out, bing_snippets)
                log.info(f"  LLM risk={result.get('risk','?')} "
                         f"action={result.get('recommended_action','?')}")

            self.store.save(alert_id, ip, "ip", source,
                            "\n\n".join(phomber_out.values()),
                            bing_snippets, result)

        # ── Enriquecer MACs ────────────────────────────────────────────────────
        for mac in indicators["mac"]:
            source = "phomber-mac"
            if self.store.is_cached(mac, source):
                log.debug(f"  [caché] {mac} {source}")
                continue

            log.info(f"  PHOMBER mac {mac}")
            phomber_out = {}

            if not DRY_RUN:
                phomber_out["mac"] = self.phomber.scan_mac(mac)
            else:
                phomber_out["mac"] = "[dry-run] phomber mac " + mac

            result = {}
            if not DRY_RUN:
                result = self.llm.analyze(alert, phomber_out, [])

            self.store.save(alert_id, mac, "mac", source,
                            phomber_out.get("mac", ""), [], result)

        # ── Enriquecer dominios sospechosos ───────────────────────────────────
        for domain in indicators["domain"]:
            source = "phomber-whois"
            if self.store.is_cached(domain, source):
                log.debug(f"  [caché] {domain} {source}")
                continue

            log.info(f"  PHOMBER whois {domain}")
            phomber_out = {}

            if not DRY_RUN:
                phomber_out["whois"] = self.phomber.scan_whois(domain)
                phomber_out["dns"]   = self.phomber.scan_dns(domain)
            else:
                phomber_out["whois"] = "[dry-run] phomber whois " + domain
                phomber_out["dns"]   = "[dry-run] phomber dns "   + domain

            bing_snippets = []
            if self.bing.available and not DRY_RUN:
                bing_snippets = self.bing.dork_domain(domain)
                if bing_snippets:
                    log.info(f"  Bing: {len(bing_snippets)} resultados para {domain}")

            result = {}
            if not DRY_RUN:
                result = self.llm.analyze(alert, phomber_out, bing_snippets)
                log.info(f"  LLM risk={result.get('risk','?')} domain={domain}")

            self.store.save(alert_id, domain, "domain", source,
                            "\n\n".join(phomber_out.values()),
                            bing_snippets, result)


# ── Main loop ──────────────────────────────────────────────────────────────────

def main():
    log.info("═══════════════════════════════════════════")
    log.info("  OSINT Enricher — ai-analyzer sidecar")
    log.info("═══════════════════════════════════════════")
    log.info(f"  DB          : {DB_PATH}")
    log.info(f"  LLM         : {'Groq (' + GROQ_MODEL + ')' if GROQ_API_KEY else 'llama.cpp local'}")
    log.info(f"  Bing dorks  : {'habilitados (SearchAPI.io)' if BING_API_KEY else 'deshabilitados'}")
    log.info(f"  Severidad   : >= {MIN_SEVERITY}")
    log.info(f"  Poll        : cada {POLL_INTERVAL}s")
    log.info(f"  Dry-run     : {DRY_RUN}")
    log.info("═══════════════════════════════════════════")

    pipeline = OsintPipeline()

    if not pipeline.phomber.available:
        log.warning("PHOMBER no disponible — instala: pip install phomber")
        log.warning("Continuando sin PHOMBER (solo Bing si está configurado)")

    log.info("Iniciando poll de alertas...")

    while True:
        try:
            alerts = pipeline.store.pending_alerts()
            if alerts:
                log.info(f"Encontradas {len(alerts)} alertas pendientes de enriquecimiento")
                for alert in alerts:
                    try:
                        pipeline.process_alert(alert)
                    except Exception as exc:
                        log.error(f"Error procesando alerta #{alert.get('id')}: {exc}")
            else:
                log.debug("Sin alertas nuevas")

        except KeyboardInterrupt:
            log.info("Deteniendo OSINT enricher (Ctrl+C)")
            break
        except Exception as exc:
            log.error(f"Error en loop principal: {exc}")

        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()
