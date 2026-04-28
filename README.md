# La IA no es solo de las Big Tech

> PoC educativa: Portal Cautivo + Análisis de Tráfico con IA Local en Raspberry Pi  
> 100% software libre y código abierto — sin nube, sin APIs de pago, sin telemetría

---

## Stack tecnológico

| Componente | Tecnología |
|---|---|
| AI Backend | Java 21 · GraalVM Native Image arm64 · Rust (SQLite cdylib) |
| LLM local | llama.cpp + Qwen2.5-0.5B GGUF |
| LLM cloud (opcional) | Groq API (Qwen/QwQ) via `GROQ_API_KEY` |
| Frontend | Vite 5 · Pug · Sass · Animate.css · TypeScript (sin framework JS) |
| Contenedores web | nginx Alpine en podman (frontend + reverse proxy) |
| MQTT | Mosquitto 2.x |
| Secretos | age + sops |
| Build | Makefile (artefactos) + Justfile (operaciones) |
| CI/CD | GitHub Actions → GitHub Releases |

---

## Documentación

| Documento | Descripción |
|---|---|
| [Visión general](docs/vision-general.md) | Qué es la PoC, qué demuestra y por qué importa |
| [Hardware](docs/hardware.md) | Los 4 dispositivos: Raspis, router y sus roles |
| [Portales cautivos](docs/portales.md) | Los 2 portales (Lentium y clásico), diferencias y cómo intercambiarlos |
| [Arquitectura](docs/arquitectura.md) | Diagramas MermaidJS, flujos y conexiones entre componentes |
| [Analizador IA y LLM](docs/llm.md) | TinyLlama/Qwen, llama.cpp, casos de uso, Groq API |
| [Software libre](docs/software-libre.md) | Stack completo con licencias y reflexión sobre el ecosistema |
| [Hitos](docs/hitos.md) | Los 10 hitos del proyecto con línea de tiempo |
| [**Setup**](docs/setup.md) | **Instalación y configuración paso a paso** |
| [**Scripts**](docs/scripts.md) | **Referencia de todos los scripts** |
| [Endpoints HTTP](docs/html-endpoints.md) | API REST y rutas web de todos los servicios |
| [Troubleshooting](docs/troubleshooting.md) | Problemas comunes y cómo resolverlos |
| [Plan de mejoras](PLAN.md) | Mejoras implementadas |
| [Agentes IA](AGENTS.md) | Guía para agentes que contribuyen al proyecto |
| [Changelog](CHANGELOG.md) | Historial de cambios |

---

## Inicio rápido

### 1. Instalar dependencias del SO en Pi4B

```bash
sudo bash scripts/setup-raspi4b-deps.sh
```

### 2. Setup completo Pi4B

```bash
sudo bash scripts/setup-raspi4b-all.sh
```

### 3. Acceder al sistema

```
http://192.168.1.167/           → Dashboard
http://192.168.1.167/chat.html  → Chat IA (Groq/Qwen)
http://192.168.1.167/health     → Health API
```

---

## Compilación local (laptop admin)

```bash
# Prerequisitos: Rust + JDK 21 GraalVM + Node.js 20 + gcc-aarch64-linux-gnu
make all           # Rust arm64 + fat JAR + Vite frontend
make frontend      # solo frontend dist/
make rust-arm64    # solo .so arm64
```

---

## Operaciones frecuentes con Justfile

```bash
just --list                     # ver todas las recetas disponibles

# Despliegue
just setup-java                 # ai-analyzer Java en Pi4B
just setup-frontend             # frontend nginx/podman en Pi4B

# Diagnóstico
just health-pi4b                # health completo
just logs                       # journalctl ai-analyzer en vivo
just logs-proxy                 # logs nginx proxy

# OpenWrt
just router-clients             # clientes WiFi activos
just portal-reset               # reset demo captive portal

# Secretos
just secrets-init               # inicializar age+sops
just secrets-edit               # editar secretos cifrados
```

---

*Todo el código es libre, auditable y modificable. Fork it, mejóralo, compártelo.*
