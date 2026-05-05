# Architecture

Why this demo migrates with a Kroxylicious sidecar instead of the more
familiar alternatives, what each component does, and where the approach
breaks down.

## The migration pattern in one sentence

Each Kafka workload talks to its own Kroxylicious sidecar that exposes
the source and destination clusters as two virtual clusters on a single
TCP port. The client is migrated by changing one thing - the bootstrap
SNI hostname - which causes Kroxylicious to route subsequent connections
to the other backend.

## Components

```
                          per-workload sidecar
                          (one virtual cluster
                           per backend)
                          ┌─────────────────────────┐
                          │ producer-proxy :9192    │
   demo-producer ──TLS──▶ │   source.* ─▶ source    │ ──▶ kafka-source
   (SNI=source/dest)      │   dest.*   ─▶ dest      │ ──▶ kafka-dest
                          └─────────────────────────┘

                          ┌─────────────────────────┐
                          │ consumer-proxy :9292    │
   demo-consumer ──TLS──▶ │   source.* ─▶ source    │ ──▶ kafka-source
   (SNI=source/dest)      │   dest.*   ─▶ dest      │ ──▶ kafka-dest
                          └─────────────────────────┘
```

- `kafka-source`, `kafka-dest`: independent KRaft single-broker clusters.
  Nothing connects them - no MirrorMaker, no Cluster Linking, no shared
  controller quorum.
- `producer-proxy`, `consumer-proxy`: Kroxylicious instances. Each holds
  two `virtualClusters` with one `gateway` each. Both gateways listen on
  the same port; `sniHostIdentifiesNode` selects the backend by the SNI
  name presented during the TLS handshake.
- `demo-producer`, `demo-consumer`: standard Kafka 4.1 Java clients with
  `ssl.endpoint.identification.algorithm=https`. They are unaware of
  Kroxylicious - to them it is just a Kafka broker that happens to live
  at `<env>.<workload>-proxy:<port>`.

## Why SNI routing and not PrincipalRouter

Each virtual cluster needs at least one TCP endpoint. There are three
ways to multiplex multiple virtual clusters onto a single proxy:

1. **One port per cluster** - simplest, but then "migrating" means
   pointing the client at a different port. Defeats the goal of an
   in-place cutover with the same listening surface.
2. **`sniHostIdentifiesNode`** (this demo) - one port, routing is decided
   by the SNI name on the TLS ClientHello. Requires TLS and a cert with
   one SAN per virtual hostname.
3. **PrincipalRouter / SASL identity routing** - one port, routing keyed
   on the authenticated principal. Requires SASL and a principal-to-
   cluster mapping. More moving parts than the demo needs.

Option 2 is the smallest viable surface that still demonstrates a true
in-place migration, so the demo uses that.

## The migration sequence

```
   t0: producer ──▶ source.producer-proxy ──▶ kafka-source
       consumer ──▶ source.consumer-proxy ──▶ kafka-source

   step 2: producer recreated with BOOTSTRAP=dest.producer-proxy
   t1: producer ──▶ dest.producer-proxy   ──▶ kafka-dest          (NEW)
       consumer ──▶ source.consumer-proxy ──▶ kafka-source         (drains)

   step 3: wait until consumer-group lag on source == 0

   step 4: consumer recreated with BOOTSTRAP=dest.consumer-proxy
   t2: producer ──▶ dest.producer-proxy ──▶ kafka-dest
       consumer ──▶ dest.consumer-proxy ──▶ kafka-dest             (caught up)
```

Two invariants the demo relies on:

- **The producer is idempotent** (`enable.idempotence=true`). On the
  brief window where the producer's existing in-flight batches drain
  during container recreate, no duplicates land on either side.
- **The consumer commits offsets per-cluster**. Because source and dest
  are unrelated clusters, the `__consumer_offsets` topic on each is
  independent. After step 4, the consumer reads `dest` from the earliest
  available offset (no committed offset for the new group on the new
  cluster). The demo accepts this; a real migration would either pre-
  seed dest offsets via MirrorMaker 2's offset translation or use a
  point-in-time cutover where source has been fully drained AND no new
  records have been written to dest yet.

## Tradeoffs vs other migration strategies

| Strategy | When to use | Cost vs this demo |
| --- | --- | --- |
| **Direct cutover via proxy** (this demo) | Per-workload control, no replication infra, brief consumer pause acceptable | Need a sidecar per workload; cert plumbing |
| **MirrorMaker 2** | Many workloads at once, geo-replication, want offset translation | Whole second pipeline to operate; replication lag becomes part of the cutover budget |
| **Cluster Linking** (Confluent) | Same as MM2 but vendor-managed | Commercial; same lag concerns |
| **Dual-write at the application** | App owns the migration window | Touches every producer's source code; halves the throughput budget during the window |
| **Stop the world** | Tiny topic, downtime acceptable | Trivial; not interesting |

The proxy approach earns its keep when you want **per-workload cutover**
without modifying the workload, and you don't want to operate a second
replication pipeline for the duration of the migration.

## Failure modes covered (and not)

Covered by the demo and `step5-verify.sh`:

- Producer kept writing to source after step 2 (would show as a non-zero
  source delta over the sample window).
- Consumer left lag on source (would show as `source-lag != 0`).
- Producer or proxy never came up on dest (dest delta == 0).

Not covered - and therefore real-world caveats:

- **Cert/keystore drift**: changing the SAN list on the keystore without
  rolling the proxy will break TLS the next time a client reconnects.
  See `TROUBLESHOOTING.md` section 1.
- **In-flight transactions**: a transactional producer would need its
  `transactional.id` to be quiesced before step 2; this demo uses an
  idempotent (non-transactional) producer.
- **ACLs**: source and dest are independent clusters; ACL state is not
  copied. A real migration would need to seed ACLs on dest before step 2.
- **Schema Registry**: not part of this demo. If clients use a registry,
  it must be reachable from both windows of the cutover, with subjects
  pre-registered on the dest registry.
- **Consumer group offsets**: see "two invariants" above. The demo
  accepts that the consumer reads dest from earliest. Production should
  pre-seed offsets.

## Reading the configs

`producer-proxy-config.yaml` and `consumer-proxy-config.yaml` are
near-identical - same shape, different hostnames and port. The pieces
worth understanding:

- `virtualClusters[].targetCluster.bootstrapServers` - the real Kafka
  the proxy fronts.
- `gateways[].sniHostIdentifiesNode.bootstrapAddress` - the SNI name
  clients use to reach the bootstrap of this virtual cluster.
- `gateways[].sniHostIdentifiesNode.advertisedBrokerAddressPattern` -
  the per-broker hostnames Kroxylicious advertises in metadata responses.
  `$(nodeId)` is templated per source-cluster broker; clients then open
  a fresh TLS connection per broker, with that broker's SNI name.
- `gateways[].tls.key.storeFile` - the keystore mounted into the proxy
  container. `certs/generate-certs.sh` builds it with one SAN per
  advertised hostname above.
