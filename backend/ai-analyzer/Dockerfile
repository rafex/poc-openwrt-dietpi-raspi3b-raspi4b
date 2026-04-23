FROM python:3.13-alpine3.23

WORKDIR /app

# Alpine no depende de systemd — compatible con DietPi/crun sin sd-bus
RUN apk add --no-cache curl openssh-client

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY analyzer.py .
COPY router_mcp.py .
COPY dashboard.html .
COPY terminal.html .
COPY rulez.html .
COPY chat.html .
COPY reports.html .

EXPOSE 5000

ENV PYTHONUNBUFFERED=1 \
    LOG_LEVEL=INFO

CMD ["python3", "analyzer.py"]
