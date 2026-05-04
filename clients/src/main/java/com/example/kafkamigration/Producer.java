package com.example.kafkamigration;

import java.time.Duration;
import java.time.Instant;
import java.util.Properties;

import org.apache.kafka.clients.producer.KafkaProducer;
import org.apache.kafka.clients.producer.ProducerConfig;
import org.apache.kafka.clients.producer.ProducerRecord;
import org.apache.kafka.common.serialization.StringSerializer;

public final class Producer {

    public static void main(String[] args) throws InterruptedException {
        String topic = envOr("TOPIC", "orders");

        Properties props = TlsProps.load();
        props.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG, StringSerializer.class.getName());
        props.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, StringSerializer.class.getName());
        props.put(ProducerConfig.ACKS_CONFIG, "all");
        props.put(ProducerConfig.ENABLE_IDEMPOTENCE_CONFIG, "true");
        props.put(ProducerConfig.CLIENT_ID_CONFIG, "demo-producer");

        try (KafkaProducer<String, String> producer = new KafkaProducer<>(props)) {
            long i = 0;
            while (!Thread.currentThread().isInterrupted()) {
                String value = "msg-" + i + " " + Instant.now();
                producer.send(new ProducerRecord<>(topic, value), (md, ex) -> {
                    if (ex != null) {
                        System.err.println("send failed: " + ex.getMessage());
                    } else {
                        System.out.println("sent: " + value + " -> " + md.topic() + "-" + md.partition() + "@" + md.offset());
                    }
                });
                i++;
                Thread.sleep(Duration.ofSeconds(1));
            }
        }
    }

    private static String envOr(String key, String def) {
        String v = System.getenv(key);
        return v == null || v.isBlank() ? def : v;
    }
}
