# Visión general — ¿Qué es y qué demuestra esta PoC?

## En una oración

> Un sistema completo de WiFi público con portal cautivo, análisis de tráfico y toma de
> decisiones de seguridad — todo corriendo en Raspberry Pis con software libre,
> **sin nube, sin APIs de pago, sin enviar datos a ningún tercero**.

---

## El problema que resuelve

La narrativa dominante en la industria tecnológica dice que para tener Inteligencia Artificial
necesitas:

- Cuenta en AWS, Azure o Google Cloud
- Presupuesto mensual en APIs (OpenAI, Anthropic, Gemini…)
- Conectividad permanente a internet
- Ingenieros especializados y costosos

Esta PoC demuestra que **ninguna de esas afirmaciones es cierta**.

---

## ¿Qué hace el sistema?

```
Un cliente se conecta al WiFi
        ↓
Ve un portal cautivo → se registra (nombre, teléfono, contraseña, dirección OSM, redes sociales)
        ↓
Mientras navega, un sensor captura su tráfico de red (sin leer contenido)
        ↓
Cada 30 segundos, un LLM local analiza el tráfico y produce:
  • Nivel de riesgo (BAJO / MEDIO / ALTO)
  • Hallazgos accionables en español
  • Clasificación de dominios visitados
  • Perfilado del tipo de dispositivo
  • Alertas si hay comportamiento sospechoso
        ↓
Si detecta tráfico de redes sociales en horario laboral →
el LLM decide si bloquear y ejecuta la regla en el router
        ↓
Todo queda en SQLite local, visible en un dashboard en tiempo real
```

---

## Lo que esta PoC demuestra

### 1. IA sin nube es posible y práctica

TinyLlama 1.1B corriendo en el CPU de una Raspberry Pi 4B analiza tráfico de red,
toma decisiones de seguridad y mantiene conversaciones en español — sin internet,
sin tokens que pagar, sin latencia de red.

### 2. El software libre es infraestructura de producción

Cada componente del stack tiene décadas de madurez y uso masivo:
OpenWrt en millones de routers, nginx sirviendo el 30% de la web, SQLite
la base de datos más desplegada del planeta, Python el lenguaje de IA más usado.

### 3. Hardware accesible es suficiente

| Dispositivo | Precio aprox. |
|---|---|
| Raspberry Pi 4B (8 GB) | ~$60 USD |
| 2× Raspberry Pi 3B | ~$35 USD c/u |
| TP-Link TL-WDR3600 (usado) | ~$30 USD |
| **Total** | **~$160 USD** |

Menos que un mes de suscripción a un proveedor cloud de IA empresarial.

### 4. La privacidad es una decisión de arquitectura

Cuando el procesamiento ocurre localmente, la privacidad no depende de las políticas
de uso de un tercero. Los datos de la red **nunca salen del edificio**.

---

## ¿A quién va dirigida?

- **Comunidades de software libre** — para mostrar el estado del arte con herramientas abiertas
- **Estudiantes de redes y seguridad** — como laboratorio real y reproducible
- **Administradores de redes** — como referencia de implementación
- **Cualquier persona curiosa** — que quiera entender cómo funciona un portal cautivo con IA

---

## Relación con la presentación

Esta PoC acompaña la charla **"La IA no es solo de las Big Tech"**.
El objetivo no es impresionar con métricas de benchmark sino mostrar que con herramientas
libres y hardware accesible se puede construir un sistema de IA funcional y útil.

---

← [Índice](../README.md) | [Hardware →](hardware.md)
