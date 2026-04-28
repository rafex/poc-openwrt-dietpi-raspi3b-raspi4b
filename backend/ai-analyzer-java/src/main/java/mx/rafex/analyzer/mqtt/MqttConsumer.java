package mx.rafex.analyzer.mqtt;

import mx.rafex.analyzer.config.Config;
import mx.rafex.analyzer.db.DatabaseClient;
import mx.rafex.analyzer.worker.AnalysisWorker;

import org.eclipse.paho.client.mqttv3.*;
import org.eclipse.paho.client.mqttv3.persist.MemoryPersistence;

import java.time.Instant;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.logging.Logger;

/**
 * Consumidor MQTT para el topic {@code rafexpi/sensor/batch}.
 *
 * <p>Cada mensaje recibido se guarda como batch en SQLite y se encola en
 * {@link AnalysisWorker} para su análisis asíncrono con el LLM.
 *
 * <p>Usa la librería Eclipse Paho (única dependencia externa del proyecto).
 * El reconectado es automático gracias a {@code setAutomaticReconnect(true)}.
 */
public final class MqttConsumer implements MqttCallback {

    private static final Logger LOG = Logger.getLogger(MqttConsumer.class.getName());
    private static final DateTimeFormatter ISO = DateTimeFormatter.ISO_INSTANT.withZone(ZoneOffset.UTC);
    private static final String CLIENT_ID = "ai-analyzer-java";

    private final DatabaseClient db;
    private final AnalysisWorker worker;
    private final AtomicBoolean connected = new AtomicBoolean(false);

    private MqttClient client;

    public MqttConsumer(DatabaseClient db, AnalysisWorker worker) {
        this.db     = db;
        this.worker = worker;
    }

    /** Conecta al broker y se suscribe al topic configurado. */
    public void start() {
        var broker = "tcp://%s:%d".formatted(Config.MQTT_HOST, Config.MQTT_PORT);
        LOG.info("Conectando a MQTT: %s topic=%s".formatted(broker, Config.MQTT_TOPIC));

        try {
            client = new MqttClient(broker, CLIENT_ID, new MemoryPersistence());
            client.setCallback(this);

            var opts = new MqttConnectOptions();
            opts.setCleanSession(true);
            opts.setAutomaticReconnect(true);
            opts.setConnectionTimeout(10);
            opts.setKeepAliveInterval(30);

            client.connect(opts);
            client.subscribe(Config.MQTT_TOPIC, 1);  // QoS 1 = al menos una vez

            connected.set(true);
            LOG.info("MQTT conectado y suscrito a: " + Config.MQTT_TOPIC);

        } catch (MqttException e) {
            LOG.warning("MQTT no disponible (%s) — arrancando sin MQTT. Paho reintentará.".formatted(e.getMessage()));
            // No es fatal: el servidor HTTP funciona y el endpoint /api/ingest acepta HTTP POST
        }
    }

    /** Desconecta limpiamente. */
    public void stop() {
        if (client != null && client.isConnected()) {
            try {
                client.disconnect(1000);
                client.close();
            } catch (MqttException e) {
                LOG.warning("Error al cerrar MQTT: " + e.getMessage());
            }
        }
    }

    public boolean isConnected() {
        return client != null && client.isConnected();
    }

    // ─── MqttCallback ────────────────────────────────────────────────────────

    @Override
    public void connectionLost(Throwable cause) {
        connected.set(false);
        LOG.warning("MQTT desconectado: " + cause.getMessage() + " (reconectando automáticamente)");
    }

    @Override
    public void messageArrived(String topic, MqttMessage message) {
        var payload = new String(message.getPayload(), java.nio.charset.StandardCharsets.UTF_8);
        var receivedAt = ISO.format(Instant.now());

        // Extraer sensor_ip del payload JSON si está disponible
        String sensorIp = null;
        try {
            sensorIp = mx.rafex.analyzer.util.Json.extractString(payload, "sensor_ip");
        } catch (Exception ignored) {}

        // Guardar en SQLite via Rust
        long batchId = db.batchInsert(receivedAt, sensorIp, payload);
        if (batchId <= 0) {
            LOG.warning("No se pudo insertar batch (MQTT message ignorado)");
            return;
        }

        // Encolar para análisis asíncrono
        if (!worker.enqueue(batchId)) {
            LOG.warning("Cola llena — batch %d descartado del análisis".formatted(batchId));
            db.batchSetStatus(batchId, "skipped");
        } else {
            LOG.fine("Batch %d encolado para análisis".formatted(batchId));
        }
    }

    @Override
    public void deliveryComplete(IMqttDeliveryToken token) {
        // Solo relevante si publicamos; no lo hacemos desde aquí
    }
}
