# Production Migration Playbook

Operator runbook for executing the Kroxylicious + SNI migration pattern
against a real workload. The README explains how to run the demo.
ARCHITECTURE.md explains why the pattern works. This file is what an
on-call engineer reads at 09:00 on cutover day.

The demo collapses every wait to seconds. Production runs the same
sequence but with explicit checkpoints, larger time budgets, and a
defined rollback trigger at each step.

## 0. Pre-flight (T - 1 day)

Cutover only proceeds if every item below is green. Any red is a
cancel-the-window decision, not a "let's see how it goes."

| Check                                          | How                                                         |
| ---------------------------------------------- | ----------------------------------------------------------- |
| Source and dest brokers reachable from proxies | `kafka-broker-api-versions.sh --bootstrap-server <broker>`  |
| Cert valid for >= cutover window + 7 days      | `keytool -list -v -keystore keystore.p12`                   |
| All SNI hostnames resolve to proxy             | `getent hosts <hostname>` from a workload pod               |
| Proxy YAML SAN list, cert SANs, DNS aliases agree | three-way diff (this is the #1 production foot-gun)      |
| Topic config parity (partitions, RF, configs)  | `kafka-configs.sh --describe --entity-type topics`          |
| ACLs replicated to dest cluster                | `kafka-acls.sh --list`                                      |
| Dest cluster has headroom (CPU, disk, network) | broker metrics from APM                                     |
| Consumer group offsets seeded if doing offline pre-replication | `kafka-consumer-groups.sh --reset-offsets ...` |
| Rollback path exercised in staging within 30 days | last staging rollback ticket linked in change record    |

## 1. T0 - Migrate the producer

Single change: producer `bootstrap.servers` flips from
`source.<workload>-proxy:<port>` to `dest.<workload>-proxy:<port>`.
TCP port and TLS material are identical - only the SNI hostname changes.

| Mechanism | What to change |
| --------- | -------------- |
| Kubernetes deployment | ConfigMap value + `kubectl rollout restart deployment/<producer>` |
| ECS / Nomad           | task definition env var + service update                          |
| Docker compose / VM   | `docker compose up -d --force-recreate <producer>`                |

**Checkpoint A** (T0 + 2 min): destination log-end-offset is advancing.

```bash
kafka-get-offsets.sh --bootstrap-server dest --topic <topic> --time -1
```

Run twice 30s apart. Delta must be > 0. If the delta is 0, the producer
is not connected to dest (likely SNI/cert issue) - **rollback now**.

**Checkpoint B** (T0 + 2 min): source log-end-offset has stopped advancing.

Same query against source. Delta must be 0. A non-zero delta means the
producer is dual-publishing - investigate before continuing.

## 2. T1 - Wait for source drain

Consumer is still on source. It must drain everything the producer
wrote to source before T0 *plus* anything in flight.

```bash
kafka-consumer-groups.sh --bootstrap-server source \
  --describe --group <group> | awk 'NR>1 { sum += $6 } END { print sum }'
```

Lag must reach 0 and stay there for one consecutive sample interval.
The demo's `step3-check-lag.sh` polls until lag = 0; production runs
the same logic with a larger ceiling and an alert if lag flatlines
above 0 (consumer stuck, not drained).

**Time budget**: typical drain time is roughly
`source-lag-at-T0 / steady-state-throughput`. Budget at least 3x that
before the change window expires.

## 3. T2 - Migrate the consumer

Same mechanism as the producer flip. The dest topic now has the
producer's post-T0 writes; the consumer starts fresh on dest.

**Group offset behaviour**: each Kafka cluster owns its own
`__consumer_offsets`. The dest-cluster group has no committed offset
on the first run, so `auto.offset.reset` decides where it starts.
Set this explicitly per workload:

| Workload requirement                          | `auto.offset.reset` |
| --------------------------------------------- | ------------------- |
| Replay from cluster cutover (post-T0 writes)  | `earliest`          |
| Skip backlog, only consume new writes         | `latest`            |
| Pre-seeded offsets via offline replication    | `none` (fail loud)  |

**Checkpoint C** (T2 + 2 min): consumer is committing offsets on dest.

```bash
kafka-consumer-groups.sh --bootstrap-server dest --describe --group <group>
```

`CURRENT-OFFSET` must be > 0 and advancing. `LAG` should track
production rate, not the topic's full history (unless `earliest` is
the deliberate choice).

## 4. Post-cutover verification

Run the equivalent of `step5-verify.sh` with production thresholds:

- Source delta over 60s == 0 (producer stopped).
- Dest delta over 60s > 0 (producer writing).
- Source lag for the group == 0 (consumer drained).
- Dest lag <= dest delta (consumer keeping up).

All four green for 15 consecutive minutes = migration accepted.
Anything red after T2 is a rollback decision.

## 5. Rollback triggers

Cut back to source if any of these fire within the change window:

| Trigger                                               | Action      |
| ----------------------------------------------------- | ----------- |
| Producer cannot connect to dest (TLS / SNI failure)   | Revert step 1 immediately |
| Dest delta == 0 for > 5 min after producer migration  | Revert step 1 |
| Source lag flatlines > 0 (consumer stuck on source)   | Investigate; do not migrate consumer until drained |
| Consumer cannot connect to dest after step 3          | Revert step 3 |
| Data divergence detected (downstream check)           | Revert both, post-mortem |

Rollback is the same operation in reverse: flip `bootstrap.servers`
back to the source SNI hostname and force-recreate the workload.
Source cluster has retained everything during the cutover - nothing
needs to be replayed unless the consumer was migrated and committed
offsets on dest.

## 6. Decommission (T + N days)

Source cluster stays online for N days as the rollback safety net.
Typical N = 7 to 30, depending on retention and audit requirements.

Decommission gates:
- No application has flipped back to source within N days.
- All downstream consumers (CDC, audit, analytics) confirmed on dest.
- Source cluster has no producer connections (`kafka-broker-api-versions.sh`
  on each broker, or APM connection metrics).

Then: stop the source workload's virtual cluster in the proxy YAML,
roll the proxy, and finally tear down source brokers.

## What this pattern does not give you

The proxy migrates *workloads*. It does not migrate *data*. If the
dest cluster needs the source's history, you need a separate
replication step (MirrorMaker 2, Cluster Linking, or a one-time
offline copy) before T0. This demo deliberately skips that - the dest
topic starts empty and the consumer picks up from the producer's
post-T0 writes.

For workloads where history matters (event sourcing, audit logs,
replay-driven recompute), pair this pattern with offline pre-replication
and use `auto.offset.reset=none` plus seeded group offsets at step 3.
