# nginx/proxy/Dockerfile
# Reverse proxy: / → frontend container  |  /api/* /health /events → Java :5000
FROM nginx:1.27-alpine

RUN rm /etc/nginx/conf.d/default.conf
COPY nginx.conf /etc/nginx/conf.d/proxy.conf

EXPOSE 80
