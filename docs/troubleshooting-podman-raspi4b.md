# Troubleshooting Podman en Raspi4B

## Caso: overlay atascado + imagen local no encontrada

### Síntomas

1. Al borrar/reemplazar contenedor:
- `directory not empty`
- `replacing mount point .../merged: directory not empty`

2. Al iniciar contenedor con imagen local:
- `Trying to pull localhost/ai-analyzer-web:latest...`
- `pinging container registry localhost ... connect: connection refused`

3. Frontend no responde:
- `curl -I http://127.0.0.1/nginx-health` -> `Failed to connect`

---

### Causa raíz

- Estado inconsistente del storage overlay de Podman (locks o restos de mount).
- La imagen local `ai-analyzer-web:latest` ya no existe (o quedó corrupta), entonces Podman intenta hacer pull remoto de `localhost/...`.

---

### Operativa de recuperación (estándar)

1. Reiniciar host para liberar locks:

```bash
sudo reboot
```

2. Después del reinicio, ejecutar:

```bash
cd /opt/repository/poc-openwrt-dietpi-raspi3b-raspi4b

# Reset completo de podman (destructivo de contenedores/imágenes locales)
sudo systemctl stop podman podman.socket 2>/dev/null || true
sudo podman system reset -f
sudo systemctl start podman.socket 2>/dev/null || true

# Reconstruir imagen frontend
sudo podman build -t ai-analyzer-web:latest -f nginx/Dockerfile .

# Levantar contenedor
sudo podman run --replace --name ai-analyzer-web --network host -d ai-analyzer-web:latest

# Verificar
curl -I http://127.0.0.1/nginx-health
curl -I http://127.0.0.1/dashboard
```

---

### Verificaciones rápidas

```bash
sudo podman ps -a --format "table {{.ID}}\t{{.Names}}\t{{.Status}}"
sudo podman images | grep ai-analyzer-web
ss -ltnp | grep ':80'
```

---

### Prevención

- En instalaciones/reinstalaciones, usar `--replace` en `podman run`.
- Hacer limpieza explícita previa:

```bash
sudo podman rm -f ai-analyzer-web || true
```

- Si aparece `directory not empty`, reiniciar y aplicar `podman system reset -f` antes de redeploy.
