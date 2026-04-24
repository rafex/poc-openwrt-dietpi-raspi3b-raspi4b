# TODO AI Roadmap (No-Regressions)

## Principio base de no-regresión
1. No reemplazar endpoints existentes (`/dashboard`, `/api/history`, `/rulez`, etc.).
2. Todo lo nuevo entra detrás de flags (`FEATURE_*`) con default seguro.
3. Nuevas tablas SQLite separadas; no tocar las actuales salvo índices compatibles.
4. UI nueva en rutas nuevas (`/chat`, `/reports`) o paneles adicionales no intrusivos.
5. Validación por fases con checklist de rollback rápido.

## Fase 0: Hardening y compatibilidad
1. Agregar flags:
   - `FEATURE_HUMAN_EXPLAIN=true`
   - `FEATURE_DOMAIN_CLASSIFIER=true`
   - `FEATURE_PORTAL_RISK_MESSAGE=true`
   - `FEATURE_CHAT=true`
   - `FEATURE_DEVICE_PROFILING=true`
   - `FEATURE_AUTO_REPORTS=true`
2. Mantener `MODEL_FORMAT` actual y agregar perfil opcional `MODEL_PROFILE=qwen2-0.5b`.
3. No cambiar flujo MQTT/sensor actual.

## Fase 1: Interpretación humana + alertas (1,2,6,7)
1. En `ai-analyzer`, añadir pipeline de interpretación en lenguaje natural por batch.
2. Detectores simples adicionales:
   - explosión de dominios por ventana,
   - repetición anómala,
   - dominios raros.
3. Guardar en SQLite:
   - `human_explanations`
   - `network_alerts`
4. API nueva:
   - `GET /api/explanations/latest`
   - `GET /api/alerts?limit=...`
5. Dashboard: panel “Explicación IA” + “Alertas activas”.

## Fase 2: Clasificación de dominios (4)
1. Tabla `domain_categories` (cache local persistente).
2. Clasificación híbrida:
   - reglas rápidas (infra/social/stream/dev/etc.),
   - fallback LLM para desconocidos.
3. API:
   - `GET /api/domain-categories/top`
4. Dashboard:
   - gráfico de categorías (% tráfico).

## Fase 3: Resúmenes automáticos + reportes (5,10)
1. Job interno cada 60s (thread) que genera resumen.
2. Tabla `network_summaries` y `network_reports`.
3. APIs:
   - `GET /api/summaries/latest`
   - `GET /api/reports/latest`
   - `POST /api/reports/generate`
4. Ruta nueva `/reports` (HTML simple exportable).

## Fase 4: Mensajes dinámicos para portal cautivo (3)
1. `ai-analyzer` expone:
   - `GET /api/portal/risk-message?ip=...`
2. Portal Lentium consume ese endpoint y muestra advertencia dinámica.
3. Fallback si IA no responde: mensaje estático actual.

## Fase 5: Chat de red `/chat` (8)
1. Nueva UI `chat.html` (estilo widget).
2. API:
   - `POST /api/chat` (Q&A sobre estado de red)
3. Contexto acotado:
   - último resumen,
   - top dominios,
   - alertas recientes,
   - dispositivos detectados.
4. Guardar conversaciones en `chat_sessions` (opcional).

## Fase 6: Perfilado de dispositivos (9)
1. Motor heurístico + LLM opcional:
   - iPhone, Android, Smart TV, laptop, IoT.
2. Tabla `device_profiles` con score/confianza.
3. API:
   - `GET /api/devices/profile`
4. Dashboard:
   - panel “Qué dispositivo parece ser y por qué”.

## MCP
1. Extender MCP actual con:
   - recurso `whitelist` editable,
   - prompts operativos separados (`analysis`, `actions`, `chat`),
   - ejemplos markdown + json highlight.
2. Mantener SSH oculto detrás de tool MCP (sin exponer credenciales).

## Orden recomendado de ejecución
1. Fase 1
2. Fase 2
3. Fase 4
4. Fase 5
5. Fase 3
6. Fase 6
