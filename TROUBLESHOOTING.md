# Troubleshooting

Non-obvious failure modes for the Kroxylicious + TLS + SNI demo. Most
of these will only bite you if you change something - the defaults
work - but each one represents a place where the design is more
load-bearing than it looks.

## 1. TLS handshake fails: "unable to find valid certification path"

Symptom (Java client):

```
PKIX path building failed: sun.security.provider.certpath.SunCertPathBuilderException:
unable to find valid certification path to requested target
```

Cause: the client truststore does not contain the cert that the
proxy presented. Either the truststore is stale (regenerated keystore,
old truststore mounted) or the wrong file is mounted into the
container.

Check:

```bash
keytool -list -keystore certs/generated/truststore.p12 \
  -storetype PKCS12 -storepass changeit
```

The fingerprint must match the one in `keystore.p12`. If they
diverge, regenerate both - see section 5.

## 2. TLS handshake fails: "No subject alternative DNS name matching ... found"

Symptom:

```
javax.net.ssl.SSLHandshakeException:
  No subject alternative DNS name matching source.producer-proxy found.
```

Cause: the cert's SAN list does not cover the hostname the client is
connecting to. This is the SNI hostname - not the docker container
name.

Every hostname that appears in either proxy YAML must be a SAN on the
cert. The full set is hard-coded in `certs/generate-certs.sh`:

```
source.producer-proxy   broker-1.source.producer-proxy
dest.producer-proxy     broker-1.dest.producer-proxy
source.consumer-proxy   broker-1.source.consumer-proxy
dest.consumer-proxy     broker-1.dest.consumer-proxy
```

If you add a virtual cluster, add its bootstrap and broker hostnames to
the SAN list and to `docker-compose.yaml` network aliases - then
regenerate.

## 3. Connection succeeds, then "Connection refused" on the broker address

Symptom: the bootstrap connection works, the client receives metadata,
then fails connecting to `broker-1.source.producer-proxy:9192`.

Cause: the advertised broker hostname does not resolve. Kroxylicious
returns whatever you put in `advertisedBrokerAddressPattern` in the
metadata response; the client trusts it and tries to dial that host.
If docker DNS does not resolve `broker-1.source.producer-proxy`, the
second hop fails.

The fix lives in `docker-compose.yaml`: the proxy container needs a
network alias for every advertised broker hostname. From
`docker-compose.yaml`:

```yaml
producer-proxy:
  ...
  networks:
    default:
      aliases:
        - source.producer-proxy
        - dest.producer-proxy
        - broker-1.source.producer-proxy
        - broker-1.dest.producer-proxy
```

The bootstrap aliases on their own are not enough - the broker
aliases are what makes the second hop resolvable. Adding a virtual
cluster means adding both bootstrap and broker aliases.

## 4. `ssl.endpoint.identification.algorithm` must be `https`

`clients/src/main/java/com/example/kafkamigration/TlsProps.java` sets:

```java
props.put(SslConfigs.SSL_ENDPOINT_IDENTIFICATION_ALGORITHM_CONFIG, "https");
```

Do not set this to empty string to make a TLS error go away. Empty
disables hostname verification, which means the cert's SAN list is no
longer enforced - any cert signed by anything in the truststore would
be accepted regardless of hostname. With `https` enabled, hostname
verification on the SNI name is what makes the SAN list in section 2
load-bearing.

The Kafka client default is `https` from 2.0+ for SSL connections, so
the explicit set is belt-and-braces. Leave it.

## 5. Regenerating certs

The keystore and truststore must always be regenerated together - they
are linked by the cert fingerprint.

```bash
rm -rf certs/generated
./certs/generate-certs.sh
docker compose restart producer-proxy consumer-proxy producer consumer
```

The proxies and clients mount `certs/generated` read-only, so a
restart is enough - no rebuild. If you only restart one side you will
get section 1's PKIX error.

`step1-start.sh` only generates certs when `keystore.p12` is missing.
After editing the SAN list in `generate-certs.sh`, delete the
`generated/` directory or run `just certs` (see additional notes).

## 6. The `sniHostIdentifiesNode` schema is reverse-engineered

The Kroxylicious config schema uses Jackson polymorphic deserialization
with `JsonTypeInfo.Id.DEDUCTION`. There is no `type:` discriminator on
gateway entries - Jackson picks the gateway implementation by looking
at which fields are present.

Practically:

- `sniHostIdentifiesNode:` selects the SNI gateway. Its required
  fields are `bootstrapAddress` and `advertisedBrokerAddressPattern`.
- A typo in either field name will silently route the YAML to a
  different gateway type or fail with a deduction error that does not
  point at the typo.
- `bootstrapAddress` and `advertisedBrokerAddressPattern` must agree
  on port. The proxy listens on the port from `bootstrapAddress`;
  `advertisedBrokerAddressPattern` is what the client tries next.
  Mismatched ports produce section 3.

If you need to extend the config, work from a known-good example and
compare. Skipping the docs and grep'ing the source for the gateway
type's `@JsonProperty` annotations is faster than the published YAML
reference.

## 7. The shell alias trap (docker / podman / colima)

If `docker` is aliased to `podman` (common on macOS via colima or
podman-desktop), the demo will mostly work but two things diverge:

- Network alias resolution. Podman's default DNS plugin resolves
  network aliases; older or non-default backends may not. If section 3
  reproduces under podman but not docker, this is the suspect.
- Volume mount permissions. The `certs/generated` mount is `:ro` and
  must be readable by uid 1000 inside the container. Podman with
  `:Z`/`:z` SELinux relabelling may surprise you if you copied a
  command from elsewhere.

Sanity check before debugging anything else:

```bash
type docker
docker info | grep -i 'server version\|name:'
```

If it says `podman`, you know what you have. The demo targets docker
compose v2 but works on podman compose - just be aware which one is
running.

## Additional notes

A `justfile` (run with [`just`](https://github.com/casey/just)) wraps
the cert generation and the four `stepN-*.sh` scripts so the demo can
be driven with `just up`, `just migrate-producer`, etc. The
`just certs` target clears `certs/generated` and re-runs
`certs/generate-certs.sh` - use it after editing the SAN list.
