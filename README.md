# Kafka Cluster Migration Demo — Kroxylicious Sidecar

Demonstrates Kafka workload migration using [Kroxylicious](https://github.com/kroxylicious/kroxylicious) as a per-workload
sidecar proxy. Each workload gets its own Kroxylicious instance with two
virtual clusters — one for source, one for destination. Migration is
achieved by re-pointing the client to the other virtual cluster.

Everything runs in Docker Compose. No host-side Kafka tools needed.

## Architecture

```
                     ┌─────────────────────────┐
  demo-producer ───▶ │  producer-proxy          │
                     │   :9192 → kafka-source   │
                     │   :9194 → kafka-dest     │
                     └─────────────────────────┘

                     ┌─────────────────────────┐
  demo-consumer ───▶ │  consumer-proxy          │
                     │   :9292 → kafka-source   │
                     │   :9294 → kafka-dest     │
                     └─────────────────────────┘
```

## Prerequisites

- Docker (or Podman) with Compose V2
- Java 21+ and Maven (build only — not needed at runtime)

## Build the proxy fat jar

Clone and build [Kroxylicious](https://github.com/kroxylicious/kroxylicious), then copy the fat jar into the `lib/` directory:

```bash
# Clone and build Kroxylicious
git clone https://github.com/kroxylicious/kroxylicious.git
cd kroxylicious
mvn package -Pdist -pl kroxylicious-app -am -Dquick -DskipTests

# Copy the fat jar into this repo
mkdir -p /path/to/kafka-cluster-migration/lib
cp kroxylicious-app/target/kroxylicious-app-*-jar-with-dependencies.jar \
   /path/to/kafka-cluster-migration/lib/kroxylicious-app.jar
```

## Run the demo

### Step 1 — Start everything

```bash
./step1-start.sh
```

Starts two KRaft Kafka clusters, two Kroxylicious sidecars, a producer
(1 msg/sec to `orders`), and a consumer reading `orders`. Watch output:

```bash
docker compose logs -f consumer
```

### Step 2 — Migrate the producer

```bash
./step2-migrate-producer.sh
```

Recreates the producer container pointing at `producer-proxy:9194` (the
dest virtual cluster). New messages now flow to `kafka-dest`.

### Step 3 — Wait for the consumer to drain source

```bash
./step3-check-lag.sh
```

Polls `demo-consumer` group lag on source. Exits when lag reaches 0.

### Step 4 — Migrate the consumer

```bash
./step4-migrate-consumer.sh
```

Recreates the consumer container pointing at `consumer-proxy:9294` (the
dest virtual cluster). Both workloads are now on `kafka-dest`.

### Tear down

```bash
./stop.sh
```

## What this demonstrates

1. **Zero producer downtime** — the container is recreated in seconds.
   In production, a Kubernetes ConfigMap change + sidecar restart does the same.

2. **Consumer drains before switching** — step 3 confirms no messages
   remain unread on source before the consumer moves.

3. **Per-workload isolation** — each workload has its own proxy instance.
   Migrating one does not affect the other.

4. **No code changes** — the producer and consumer are standard Kafka
   clients; only the bootstrap address changes.

5. **No custom filters needed** — routing is handled by standard
   Kroxylicious virtual cluster configuration. No PrincipalRouter, no SASL.
