FROM python:3.11-slim

WORKDIR /app

# Instalar dependencias del sistema
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY analyzer.py .

EXPOSE 5000

ENV PYTHONUNBUFFERED=1 \
    LOG_LEVEL=INFO

CMD ["python3", "analyzer.py"]
