FROM python:3.12-slim

# ── Metadata ──────────────────────────────────────────────────────────────────
LABEL org.opencontainers.image.title="ai-analyzer-python"
LABEL org.opencontainers.image.description="AI Network Analyzer — Python/FastAPI backend"
LABEL org.opencontainers.image.source="https://github.com/rafex/poc-openwrt-dietpi-raspi3b-raspi4b"

# ── Sistema ───────────────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# ── Dependencias Python ───────────────────────────────────────────────────────
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# ── Código fuente ─────────────────────────────────────────────────────────────
COPY app/ ./app/

# ── Datos ─────────────────────────────────────────────────────────────────────
RUN mkdir -p /data && chmod 777 /data

# ── Usuario no-root ───────────────────────────────────────────────────────────
RUN useradd -m -u 1000 -s /bin/sh analyzer \
    && chown -R analyzer:analyzer /app /data
USER analyzer

# ── Healthcheck ───────────────────────────────────────────────────────────────
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -sf http://localhost:5000/health | grep -q '"status":"ok"' || exit 1

EXPOSE 5000

CMD ["uvicorn", "app.main:app", \
     "--host", "0.0.0.0", \
     "--port", "5000", \
     "--workers", "1", \
     "--log-level", "info"]
