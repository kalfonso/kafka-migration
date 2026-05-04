package com.example.kafkamigration;

import java.util.Properties;

import org.apache.kafka.clients.CommonClientConfigs;
import org.apache.kafka.common.config.SslConfigs;

final class TlsProps {

    private TlsProps() {}

    static Properties load() {
        Properties props = new Properties();
        String bootstrap = required("BOOTSTRAP");
        props.put(CommonClientConfigs.BOOTSTRAP_SERVERS_CONFIG, bootstrap);
        props.put(CommonClientConfigs.SECURITY_PROTOCOL_CONFIG, "SSL");

        String truststore = required("TRUSTSTORE_LOCATION");
        String truststorePassword = required("TRUSTSTORE_PASSWORD");
        props.put(SslConfigs.SSL_TRUSTSTORE_LOCATION_CONFIG, truststore);
        props.put(SslConfigs.SSL_TRUSTSTORE_PASSWORD_CONFIG, truststorePassword);
        props.put(SslConfigs.SSL_TRUSTSTORE_TYPE_CONFIG, "PKCS12");
        props.put(SslConfigs.SSL_ENDPOINT_IDENTIFICATION_ALGORITHM_CONFIG, "https");
        return props;
    }

    private static String required(String key) {
        String v = System.getenv(key);
        if (v == null || v.isBlank()) {
            throw new IllegalStateException("Missing required env var: " + key);
        }
        return v;
    }
}
