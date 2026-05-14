"""
mqtt_consumer.py — Suscriptor MQTT.
Recibe batches JSON del sensor, los persiste en SQLite y los encola para el worker.
"""
from __future__ import annotations

import json
import logging
import threading

import paho.mqtt.client as mqtt

from .config import MQTT_HOST, MQTT_PORT, MQTT_TOPIC
from . import database as db
from .worker import work_queue
from .sse import broadcast_sync

log = logging.getLogger("mqtt")

_client: mqtt.Client | None = None
_lock = threading.Lock()


def _on_connect(client: mqtt.Client, userdata, flags, rc, properties=None):
    if rc == 0:
        log.info(f"MQTT conectado a {MQTT_HOST}:{MQTT_PORT}")
        client.subscribe(MQTT_TOPIC, qos=1)
        log.info(f"Suscrito a '{MQTT_TOPIC}'")
    else:
        log.error(f"MQTT conexión rechazada rc={rc}")


def _on_disconnect(client: mqtt.Client, userdata, rc, properties=None):
    log.warning(f"MQTT desconectado rc={rc}. Reconectando…")


def _on_message(client: mqtt.Client, userdata, msg: mqtt.MQTTMessage):
    try:
        raw = msg.payload.decode("utf-8", errors="replace")
        # Validar que sea JSON válido
        parsed = json.loads(raw)
    except Exception as exc:
        log.warning(f"Payload MQTT inválido: {exc}")
        return

    try:
        sensor_ip = parsed.get("sensor_ip", "") or parsed.get("source", "unknown")
        batch_id = db.batch_insert(sensor_ip=sensor_ip, payload=raw)
        work_queue.put(batch_id)
        log.debug(f"Batch {batch_id} encolado (sensor={sensor_ip})")

        # Notificar al dashboard que llegó un batch nuevo
        broadcast_sync({
            "event": "batch_received",
            "batch_id": batch_id,
            "sensor_ip": sensor_ip,
        })
    except Exception as exc:
        log.error(f"Error procesando mensaje MQTT: {exc}", exc_info=True)


def start_mqtt() -> mqtt.Client:
    """Inicia el cliente MQTT en un hilo de fondo. Devuelve el cliente."""
    global _client

    with _lock:
        if _client is not None:
            return _client

        client = mqtt.Client(
            client_id="ai-analyzer-v2",
            protocol=mqtt.MQTTv5,
        )
        client.on_connect    = _on_connect
        client.on_disconnect = _on_disconnect
        client.on_message    = _on_message

        try:
            client.connect(MQTT_HOST, MQTT_PORT, keepalive=60)
        except Exception as exc:
            log.error(f"No se pudo conectar al broker MQTT ({MQTT_HOST}:{MQTT_PORT}): {exc}")
            # Continuar de todas formas — el modo HTTP-only sigue funcionando

        client.loop_start()   # hilo de red interno de paho
        _client = client
        return client


def stop_mqtt():
    global _client
    with _lock:
        if _client:
            _client.loop_stop()
            _client.disconnect()
            _client = None
            log.info("MQTT detenido")
