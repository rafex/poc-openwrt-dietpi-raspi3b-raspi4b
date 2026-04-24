# La IA no es solo de las Big Tech

> PoC educativa: Portal Cautivo + Análisis de Tráfico con IA Local en Raspberry Pi  
> 100% software libre y código abierto — sin nube, sin APIs de pago, sin telemetría

---

## Documentación

| Documento | Descripción |
|---|---|
| [Visión general](docs/vision-general.md) | Qué es la PoC, qué demuestra y por qué importa |
| [Hardware](docs/hardware.md) | Los 4 dispositivos: Raspis, router y sus roles |
| [Portales cautivos](docs/portales.md) | Los 2 portales (Lentium y clásico), diferencias y cómo intercambiarlos |
| [Arquitectura](docs/arquitectura.md) | Diagramas MermaidJS, flujos y conexiones entre componentes |
| [Analizador IA y LLM](docs/llm.md) | TinyLlama, llama.cpp, 5 casos de uso, temperaturas diferenciadas |
| [Software libre](docs/software-libre.md) | Stack completo con licencias y reflexión sobre el ecosistema |
| [Hitos](docs/hitos.md) | Los 10 hitos del proyecto con línea de tiempo |
| [Setup](docs/setup.md) | Instalación y configuración paso a paso |
| [Scripts](docs/scripts.md) | Referencia de scripts de despliegue y operación |
| [Endpoints HTTP](docs/html-endpoints.md) | API REST y rutas web de todos los servicios |
| [Troubleshooting](docs/troubleshooting.md) | Problemas comunes y cómo resolverlos |
| [Plan de mejoras](PLAN.md) | Mejoras implementadas al sensor y analizador IA |
| [Agentes IA](AGENTS.md) | Guía para agentes que contribuyen al proyecto |
| [Changelog](CHANGELOG.md) | Historial de cambios |

---

## Inicio rápido

```bash
# Desplegar todo al clúster k3s
./scripts/raspi-deploy.sh

# Ver qué portal está activo
./scripts/portal-switch.sh status

# Dashboard del analizador IA
# http://192.168.1.167/dashboard
```

---

*Todo el código es libre, auditable y modificable. Fork it, mejóralo, compártelo.*
