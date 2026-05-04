#
# Wrapper for the migration demo. Install `just` from
# https://github.com/casey/just then run `just` to see targets.
#

set shell := ["bash", "-euo", "pipefail", "-c"]

# Default target: list available recipes.
default:
    @just --list

# Generate the demo TLS keystore + truststore. Idempotent: the script
# wipes certs/generated/ on each invocation. Uses hermit's keytool.
certs:
    KEYTOOL="${KEYTOOL:-./bin/keytool}" ./certs/generate-certs.sh

# Force-regenerate certs even if they already exist.
certs-clean:
    rm -rf certs/generated

# Bring up everything (Kafka clusters, proxies, producer, consumer).
# Generates certs first if missing.
up:
    ./step1-start.sh

# Migrate the producer to the destination cluster.
migrate-producer:
    ./step2-migrate-producer.sh

# Wait for the consumer to drain the source cluster.
check-lag:
    ./step3-check-lag.sh

# Migrate the consumer to the destination cluster.
migrate-consumer:
    ./step4-migrate-consumer.sh

# Tear everything down (containers + volumes).
down:
    ./stop.sh

# Tail consumer logs.
logs-consumer:
    docker compose logs -f consumer

# Tail producer logs.
logs-producer:
    docker compose logs -f producer
