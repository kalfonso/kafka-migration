# Kafka Cluster Migration Demo - Kroxylicious Sidecar

Demonstrates Kafka workload migration using [Kroxylicious](https://github.com/kroxylicious/kroxylicious) as a per-workload
sidecar proxy. Each workload gets its own Kroxylicious instance with two
virtual clusters - one for source, one for destination. Migration is
achieved by re-pointing the client at the other virtual cluster.

Clients are Java (Kafka 4.1 client). Traffic between clients and proxies is
TLS, and the two virtual clusters on each proxy share a single TCP port -
Kroxylicious routes by **SNI hostname** on the TLS handshake
(`sniHostIdentifiesNode`).

## Architecture

```
                                  TLS (SNI=source.producer-proxy)
  demo-producer (Java) ────────▶ ┌──────────────────────────────┐
                                  │  producer-proxy :9192         │
                                  │   source.producer-proxy ──▶ kafka-source
                                  │   dest.producer-proxy   ──▶ kafka-dest
                                  └──────────────────────────────┘

                                  TLS (SNI=source.consumer-proxy)
  demo-consumer (Java) ────────▶ ┌──────────────────────────────┐
                                  │  consumer-proxy :9292         │
                                  │   source.consumer-proxy ──▶ kafka-source
                                  │   dest.consumer-proxy   ──▶ kafka-dest
                                  └──────────────────────────────┘
```

## Prerequisites

- Docker (or Podman) with Compose V2. The step scripts and justfile honour
  `CONTAINER_CMD` (default `docker`) - run with `CONTAINER_CMD=podman` to
  use Podman instead.
- [hermit](https://cashapp.github.io/hermit/) (optional - already vendored
  in `bin/`; use `. bin/activate-hermit` for direct `java`/`mvn`/`keytool`)
- [just](https://github.com/casey/just) (optional) - the `justfile` wraps
  every step (`just up`, `just migrate-producer`, ...).

## Layout

```
bin/                     hermit-managed openjdk@25 + maven
certs/
  generate-certs.sh      one-off TLS keystore/truststore generator (keytool)
  generated/             output (gitignored): keystore.p12, truststore.p12
clients/
  pom.xml                Maven module
  Dockerfile             multi-stage build for the demo image
  src/.../Producer.java
  src/.../Consumer.java
  src/.../TlsProps.java  shared TLS client props
producer-proxy-config.yaml   Kroxylicious config (TLS + sniHostIdentifiesNode)
consumer-proxy-config.yaml
docker-compose.yaml
step{1..5}*.sh                migration steps
```

## Run the demo

### Step 1 - Start everything

```bash
./step1-start.sh
```

On first run the script generates the demo keystore/truststore, then builds
the Java client image and starts: two KRaft Kafka clusters, two Kroxylicious
sidecars (`quay.io/kroxylicious/kroxylicious:0.19.0`), the Java producer
(1 msg/sec to `orders`, 3 partitions, messages keyed across `alice/bob/carol/dave`)
and the Java consumer.

```bash
docker compose logs -f consumer
```

### Step 2 - Migrate the producer

```bash
./step2-migrate-producer.sh
```

Recreates the producer container with `BOOTSTRAP=dest.producer-proxy:9192`.
Same TCP port as before - only the SNI hostname changes - so Kroxylicious
routes the new connections to the dest virtual cluster.

### Step 3 - Wait for the consumer to drain source

```bash
./step3-check-lag.sh
```

Polls `demo-consumer` group lag on source. Exits when lag reaches 0.

### Step 4 - Migrate the consumer

```bash
./step4-migrate-consumer.sh
```

Recreates the consumer with `BOOTSTRAP=dest.consumer-proxy:9292`. Both
workloads are now on `kafka-dest`.

### Step 5 - Verify the end state

```bash
./step5-verify.sh
```

Samples source/dest end-offsets over a few seconds and prints a
pass/fail report: producer stopped writing to source, producer writing
to dest, consumer drained source, consumer keeping up on dest.

### Watch the migration live (optional)

```bash
./dashboard.sh
```

In a second terminal, refreshes every 2s and shows source/dest end-offsets,
ingress rate per cluster, and consumer-group lag on each side. Run it
before `step2` and you'll see the producer "jump" to dest, source rate
drop to 0, and source lag drain to 0 before `step4` moves the consumer.

### Tear down

```bash
./stop.sh
```

## TLS material

`certs/generate-certs.sh` produces a single self-signed cert with SANs for
every SNI hostname the proxies expose:

```
source.producer-proxy   broker-1.source.producer-proxy
dest.producer-proxy     broker-1.dest.producer-proxy
source.consumer-proxy   broker-1.source.consumer-proxy
dest.consumer-proxy     broker-1.dest.consumer-proxy
```

Both proxies mount the same keystore. Clients use the matching truststore
and run with `ssl.endpoint.identification.algorithm=https` so SNI hostname
verification is enforced. Demo password is `changeit` everywhere - do not
reuse for anything real.

## What this demonstrates

1. **Zero producer downtime** - the container is recreated in seconds.
   In production, a Kubernetes ConfigMap change + sidecar restart does the same.

2. **Consumer drains before switching** - step 3 confirms no messages
   remain unread on source before the consumer moves.

3. **Per-workload isolation** - each workload has its own proxy instance.
   Migrating one does not affect the other.

4. **No client code changes** - only the bootstrap address (and therefore
   the SNI hostname) changes between source and dest.

5. **TLS + SNI routing** - both virtual clusters per proxy share one TCP
   port; routing is decided on the TLS handshake. No PrincipalRouter, no
   custom filter, no SASL.
