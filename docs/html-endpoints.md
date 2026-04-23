# Inventario de HTMLs y Vistas Web

Estado al **22 de abril de 2026**.

## Resumen rápido

- **HTML físicos en repositorio:** **6**
- **Vistas HTML adicionales generadas en runtime (sin archivo .html):** **2**
- **Total de vistas HTML accesibles por HTTP:** **8**

---

## HTML físicos (archivos `.html`)

| # | Archivo | URL(s) de acceso | Servicio | Qué hace |
|---|---|---|---|---|
| 1 | `backend/captive-portal-lentium/portal.html` | `http://192.168.1.167/`, `http://192.168.1.167/portal`, `http://captive.localhost.com/portal` | Portal Lentium | Página principal de registro (cliente/invitado). Llama a `/api/register/client` y `/api/register/guest` (alias `/api/register/quest`). |
| 2 | `backend/captive-portal-lentium/services.html` | `http://192.168.1.167/services` | Portal Lentium | Panel operativo para estado/acciones de servicios de la PoC (LLM, colas, sensor, switch de portal, etc. vía API). |
| 3 | `backend/captive-portal-lentium/blocked.html` | `http://192.168.1.167/blocked` | Portal Lentium | Página de “sitio bloqueado por IA”; carga arte aleatorio desde `/blocked-art/`. |
| 4 | `backend/ai-analyzer/dashboard.html` | `http://192.168.1.167/dashboard` | AI Analyzer | Dashboard visual de análisis de tráfico y riesgo. |
| 5 | `backend/ai-analyzer/terminal.html` | `http://192.168.1.167/terminal` | AI Analyzer | Terminal en vivo con SSE (`/api/stream`) para observar eventos/análisis en tiempo real. |
| 6 | `backend/ai-analyzer/rulez.html` | `http://192.168.1.167/rulez` | AI Analyzer | Front para editar reglas/prompts persistidos en SQLite (`/api/rulez`). |

---

## Vistas HTML dinámicas (sin archivo `.html`)

| # | Ruta | Servicio | Qué hace |
|---|---|---|---|
| 7 | `http://192.168.1.167/people` (también `http://people.localhost.com/people`) | Portal Lentium | Dashboard de personas registradas y estado de conectividad (usa `/api/people/dashboard`). |
| 8 | `http://192.168.1.167/accepted` | Portal Lentium | Página simple de confirmación/compatibilidad para flujo clásico (`/accept`). |

> Compatibilidad legacy: `/demoDashboard` redirige/atiende la misma vista que `/people`.

---

## Recursos visuales de bloqueo IA

- Carpeta: `backend/captive-portal-lentium/blocked-art/`
- Archivos: `art-01.svg` a `art-10.svg`
- Uso: el HTML `/blocked` muestra **una imagen aleatoria** por usuario/evento para la pantalla de bloqueo.

---

## APIs relacionadas (sin HTML, pero críticas)

- Portal Lentium:
  - `POST /api/register/client`
  - `POST /api/register/guest` (alias `POST /api/register/quest`)
  - `GET /api/portal/context`
  - `GET /api/services/status`
  - `POST /api/services/action`
  - `GET /api/people/dashboard`
- AI Analyzer:
  - `GET /api/history`, `/api/stats`, `/api/queue`, `/api/policy`, `/api/prompt-logs`
  - `GET/POST /api/rulez`
  - `POST /api/ingest`

