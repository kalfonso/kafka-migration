#
# Wrapper for the migration demo. Install `just` from
# https://github.com/casey/just then run `just` to see targets.
#
# Override the container orchestrator with podman:
#   CONTAINER_CMD=podman just up
#

set shell := ["bash", "-euo", "pipefail", "-c"]

container_cmd := env_var_or_default("CONTAINER_CMD", "docker")

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
    CONTAINER_CMD={{container_cmd}} ./scripts/step1-start.sh

# Migrate the producer to the destination cluster.
migrate-producer:
    CONTAINER_CMD={{container_cmd}} ./scripts/step2-migrate-producer.sh

# Wait for the consumer to drain the source cluster.
check-lag:
    CONTAINER_CMD={{container_cmd}} ./scripts/step3-check-lag.sh

# Migrate the consumer to the destination cluster.
migrate-consumer:
    CONTAINER_CMD={{container_cmd}} ./scripts/step4-migrate-consumer.sh

# Verify the migration end-state.
verify:
    CONTAINER_CMD={{container_cmd}} ./scripts/step5-verify.sh

# Tear everything down (containers + volumes).
down:
    CONTAINER_CMD={{container_cmd}} ./scripts/stop.sh

# Tail consumer logs.
logs-consumer:
    {{container_cmd}} compose logs -f consumer

# Tail producer logs.
logs-producer:
    {{container_cmd}} compose logs -f producer

# Show the dashboard
dashboard:
    CONTAINER_CMD={{container_cmd}} ./scripts/dashboard.sh
