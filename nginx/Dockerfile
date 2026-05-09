# nginx/Dockerfile — Imagen unificada: sirve el frontend Vite + proxy al backend Java
#
# Contexto de build: raíz del repositorio (no nginx/)
#   podman build -f nginx/Dockerfile -t ai-analyzer-web .
#
# Requisito previo — el frontend debe estar compilado:
#   cd frontend && npm ci && npm run build   # genera frontend/dist/
#
# Deploy en Pi4B (recomendado: host network para alcanzar el backend en :5000):
#   podman run -d \
#     --name  ai-analyzer-web \
#     --network host \
#     --restart unless-stopped \
#     ai-analyzer-web:latest
#
# El backend Java corre como servicio systemd en :5000 del host.
# Con --network=host, nginx puede hacer proxy_pass a http://localhost:5000.

FROM nginx:1.27-alpine

# Eliminar configuración default
RUN rm -f /etc/nginx/conf.d/default.conf

# Copiar configuración unificada
COPY nginx/nginx.conf /etc/nginx/conf.d/ai-analyzer.conf

# Copiar el dist/ generado por Vite (prebuild: npm run build)
COPY frontend/dist/ /usr/share/nginx/html/

EXPOSE 80

# Healthcheck interno
HEALTHCHECK --interval=15s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -qO- http://localhost/nginx-health || exit 1
