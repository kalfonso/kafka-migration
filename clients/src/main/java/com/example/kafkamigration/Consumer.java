package com.example.kafkamigration;

import java.time.Duration;
import java.util.List;
import java.util.Properties;
import java.util.concurrent.atomic.AtomicReference;

import org.apache.kafka.clients.consumer.ConsumerConfig;
import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.apache.kafka.clients.consumer.ConsumerRecords;
import org.apache.kafka.clients.consumer.KafkaConsumer;
import org.apache.kafka.common.errors.WakeupException;
import org.apache.kafka.common.serialization.StringDeserializer;

public final class Consumer {

    public static void main(String[] args) {
        String topic = envOr("TOPIC", "orders");
        String group = envOr("GROUP_ID", "demo-consumer");

        Properties props = TlsProps.load();
        props.put(ConsumerConfig.KEY_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class.getName());
        props.put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class.getName());
        props.put(ConsumerConfig.GROUP_ID_CONFIG, group);
        props.put(ConsumerConfig.AUTO_OFFSET_RESET_CONFIG, "earliest");
        props.put(ConsumerConfig.ENABLE_AUTO_COMMIT_CONFIG, "true");
        props.put(ConsumerConfig.CLIENT_ID_CONFIG, "demo-consumer");

        // SIGTERM (e.g. step4's container recreate) must let close() commit
        // pending offsets and send a LeaveGroup, so the next instance doesn't
        // wait for session.timeout.ms to expire before it can start consuming.
        Thread mainThread = Thread.currentThread();
        AtomicReference<KafkaConsumer<String, String>> consumerRef = new AtomicReference<>();
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            System.err.println("consumer: shutdown signal, leaving group...");
            KafkaConsumer<String, String> c = consumerRef.get();
            if (c != null) {
                c.wakeup();
            }
            try {
                mainThread.join();
            } catch (InterruptedException ignored) {
            }
        }));

        try (KafkaConsumer<String, String> consumer = new KafkaConsumer<>(props)) {
            consumerRef.set(consumer);
            consumer.subscribe(List.of(topic));
            try {
                while (true) {
                    ConsumerRecords<String, String> records = consumer.poll(Duration.ofMillis(500));
                    for (ConsumerRecord<String, String> r : records) {
                        System.out.println("recv: " + r.value() + " (" + r.topic() + "-" + r.partition() + "@" + r.offset() + ")");
                    }
                }
            } catch (WakeupException expectedOnShutdown) {
            }
        }
        System.err.println("consumer: clean exit");
    }

    private static String envOr(String key, String def) {
        String v = System.getenv(key);
        return v == null || v.isBlank() ? def : v;
    }
}
