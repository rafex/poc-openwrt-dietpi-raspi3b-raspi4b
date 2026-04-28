# nginx/frontend/Dockerfile
# Sirve el dist/ generado por Vite en un nginx Alpine
FROM nginx:1.27-alpine

# Eliminar configuración default
RUN rm -rf /usr/share/nginx/html/* \
    && rm /etc/nginx/conf.d/default.conf

COPY nginx.conf /etc/nginx/conf.d/frontend.conf
# El dist/ se copia en tiempo de build del script de despliegue
COPY dist/ /usr/share/nginx/html/

EXPOSE 3000
