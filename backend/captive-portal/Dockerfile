FROM python:3.13-alpine3.23
RUN apk add --no-cache openssh-client
WORKDIR /app
COPY backend.py .
CMD ["python", "backend.py"]
