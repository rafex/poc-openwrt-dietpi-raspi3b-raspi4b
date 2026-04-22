FROM python:3.11-alpine

WORKDIR /app

# Alpine no depende de systemd — compatible con DietPi/crun sin sd-bus
RUN apk add --no-cache curl

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY analyzer.py .

EXPOSE 5000

ENV PYTHONUNBUFFERED=1 \
    LOG_LEVEL=INFO

CMD ["python3", "analyzer.py"]
