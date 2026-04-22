FROM python:3.11-alpine

WORKDIR /app
COPY backend.py portal.html services.html ./

RUN mkdir -p /data /opt/keys

ENV ROUTER_IP=192.168.1.1 \
    ROUTER_USER=root \
    SSH_KEY=/opt/keys/captive-portal \
    PORTAL_IP=192.168.1.167 \
    DB_PATH=/data/lentium.db \
    PORT=8080 \
    LOG_LEVEL=INFO

EXPOSE 8080

RUN apk add --no-cache openssh-client

CMD ["python", "-u", "backend.py"]
