# Troubleshooting

Hard-won notes from getting TLS + SNI-routed Kroxylicious working with Java
Kafka clients. Most issues here look like generic "TLS handshake failed" but
have non-obvious causes.

## Quickly verify what should be true

```bash
# Cert SANs - all 8 SNI hostnames must be present
keytool -list -v -keystore certs/generated/keystore.p12 \
  -storepass changeit -storetype PKCS12 | grep -A1 "Subject Alternative"

# Proxy is actually serving TLS on the SNI hostname
openssl s_client -connect localhost:9192 \
  -servername source.producer-proxy -showcerts </dev/null 2>&1 | head -20

# Consumer group exists on the right cluster (use the underlying broker, not the proxy)
docker exec kafka-source /opt/kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server localhost:9092 --describe --group demo-consumer
```

## TLS handshake fails

### `No subject alternative DNS name matching ... found`

The Java client verifies the cert against the SNI hostname (`https`
endpoint identification). Two common causes:

1. The hostname the client connects to is not in the cert SANs. Check the
   keystore (`keytool -list -v` above). The cert must list every SNI
   hostname both proxies expose: `source.producer-proxy`,
   `dest.producer-proxy`, `broker-1.source.producer-proxy`,
   `broker-1.dest.producer-proxy`, and the same four for `consumer-proxy`.
2. The keystore was regenerated but the proxy container was not restarted.
   Kroxylicious loads the keystore on startup. `docker compose restart
   producer-proxy consumer-proxy` after running `certs/generate-certs.sh`.

### Client connects but advertised broker is unreachable

Kafka's bootstrap returns advertised broker addresses to the client. Those
must also resolve and pass cert verification. Two preconditions:

- The advertised pattern in the proxy config contains `$(nodeId)` and
  matches the cert SAN: `broker-$(nodeId).source.producer-proxy:9192`.
- The proxy container has a Docker network alias for each
  `broker-N.<env>.<proxy>` hostname (see `docker-compose.yaml`). Without
  the alias, DNS resolution fails inside the compose network *before* TLS
  even starts, and the error is misleading ("connection refused").

### `endpoint identification algorithm` defaults to empty

Kafka's default for `ssl.endpoint.identification.algorithm` is `https`
since 2.0, but if you copy a config from an older version or set it
explicitly to empty, hostname verification is skipped and SNI mismatches
are silently accepted - until the server presents a cert that doesn't
match anything, at which point you get a confusing connection failure
instead of a clear cert error. Keep it at `https`.

## Kroxylicious config schema

The 0.19.0 schema is not exhaustively documented. Reverse-engineer it from
the runtime jar:

```bash
# Find and copy the runtime jar out of the image
CID=$(docker create quay.io/kroxylicious/kroxylicious:0.19.0)
docker cp "$CID:/" - | tar -xO --wildcards '*kroxylicious-runtime-*.jar' \
  > /tmp/kroxylicious-runtime.jar
docker rm "$CID" >/dev/null

# Inspect the record fields - method signatures show the YAML keys
javap -p -classpath /tmp/kroxylicious-runtime.jar \
  io.kroxylicious.proxy.config.tls.KeyStore \
  io.kroxylicious.proxy.config.tls.InlinePassword \
  io.kroxylicious.proxy.config.SniHostIdentifiesNodeIdentificationStrategy
```

Key things this tells you:

- `KeyProvider` and `PasswordProvider` use Jackson's `DEDUCTION` typing.
  YAML keys map directly to record fields - no `type:` discriminator. So
  `storePassword: { password: changeit }` is `InlinePassword`, while
  `storePassword: { passwordFile: /path }` would be `FilePassword`.
- `VirtualClusterGateway` accepts EITHER `portIdentifiesNode` OR
  `sniHostIdentifiesNode`, never both. Optional `tls` block is shared.
- `sniHostIdentifiesNode` requires `bootstrapAddress` AND
  `advertisedBrokerAddressPattern`. The pattern MUST contain `$(nodeId)`
  or startup fails with a validation error.

## SNI routing oddities

Both virtual clusters can share a single TCP port - that is the entire
point of SNI routing. The proxy decides which virtual cluster the client
hit by reading the SNI extension on the TLS ClientHello, before any Kafka
protocol bytes flow. Consequence: misconfigured SNI looks like a TLS
problem, not a routing problem. If `openssl s_client -servername X` works
but the Kafka client fails for the same `X`, the issue is downstream
(target cluster, advertised brokers) - not the SNI extension itself.

## docker vs podman shell alias

The migration scripts call `docker compose ...`. On this machine `docker`
is a shell alias for `podman`. Aliases are NOT inherited by non-interactive
subshells - so a script run via `bash step1-start.sh` from a context that
doesn't load the alias will fail with "docker: command not found".

Fixes (any one):

- Run the script directly: `./step1-start.sh` (uses your interactive shell).
- Replace `docker` with `podman` in the scripts (lossy if collaborators use real Docker).
- Symlink: `ln -s "$(which podman)" ~/bin/docker` and put `~/bin` on PATH.

## Cert regeneration

`certs/generate-certs.sh` removes the existing `.p12`/`.crt` files before
regenerating (keytool can't append SANs to an existing cert, so adding a
new SNI hostname always means a fresh keystore). After regeneration,
restart the proxies - they read the keystore once at startup.
