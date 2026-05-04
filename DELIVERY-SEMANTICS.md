# Delivery Semantics During Cutover

What this migration pattern guarantees, what it does not, and the
duplicate window every operator should know about before running it
on a real workload.

## TL;DR

This demo is **at-least-once across the cluster boundary**, not
exactly-once. After step 4 the consumer will re-process every record
produced to `kafka-dest` between step 2 and step 4. Make your consumer
idempotent or be willing to live with duplicates.

## Why duplicates exist

Kroxylicious is a stateless TLS proxy. Flipping a client from
`source.*-proxy` to `dest.*-proxy` opens a fresh connection to a
different cluster - it does not transfer state.

Kafka offsets and consumer-group commits live **per cluster** in
`__consumer_offsets`. `kafka-source` and `kafka-dest` each have their
own. When `demo-consumer` reconnects to `kafka-dest` after step 4:

- The dest cluster has no record of group `demo-consumer`.
- The client falls back to `auto.offset.reset` (set to `earliest` in
  `Consumer.java:23`).
- The consumer replays the dest topic from offset 0.

Step 2 started the producer writing to dest. Step 3 then waited for the
consumer to drain source. Every record the producer wrote to dest during
that wait window is on dest at consumer-flip time, and will be replayed.

```
              step2          step3 finishes    step4
producer:  ----+--- writes to dest -----+------+----- writes to dest
consumer:  reads source ----------------+----- reads dest from earliest
                                         <----- duplicates ----->
                                          producer wrote here AND
                                          consumer replays from 0
```

## Sizing the window

With the demo defaults (1 msg/sec, 4 keys round-robin, 3 partitions),
the duplicate window equals the elapsed time between step 2 and step 4:

```
window_records ~= producer_rate * (step3_drain_time + step4_human_delay)
```

In the e2e CI run that drain takes ~5-15s, so the window is ~5-15
duplicate records. On a real workload at 10k msg/sec with a multi-minute
drain, expect tens of millions.

You can measure the actual window after running the full demo:

```bash
# total dest records (= what consumer re-reads from offset 0)
./bin/podman compose exec kafka-dest /opt/kafka/bin/kafka-get-offsets.sh \
  --bootstrap-server localhost:9092 --topic orders --time -1 \
  | awk -F: '{ s += $3 } END { print s }'

# everything above this line was produced before step4 and will be
# replayed by the migrated consumer
```

## What this pattern does **not** do

- **Exactly-once.** No transactional bridge between source and dest.
  Idempotent producer (already enabled in `Producer.java:21`) prevents
  duplicates *within* a cluster on retry, not across the cluster flip.
- **Offset translation.** No mapping from source offset to dest offset.
  MirrorMaker 2 has `RemoteOffsetTranslation`; Cluster Linking preserves
  offsets natively. This proxy-flip pattern has neither.
- **Global ordering.** Records produced to dest in step 2 appear before
  source-drain finishes in step 3 - so dest sees recent records before
  the consumer has finished consuming older source records. Per-key
  order on the dest cluster is preserved (single producer, idempotent,
  keyed); cross-cluster total order is not.
- **Loss prevention if you skip step 3.** The whole point of step 3 is
  to ensure source has drained before the consumer moves. Skip it and
  the in-flight tail on source is lost.

## Hardening for production

Pick one based on tolerance for duplicates vs. data loss:

| Strategy | Duplicates | Loss | Cost |
|---|---|---|---|
| `auto.offset.reset=earliest` (this demo) | yes, sized as above | none | $0 |
| `auto.offset.reset=latest` after step 4 | none from window | yes, the window | $0, ops risk |
| Idempotent consumer (dedup on event-id) | absorbed | none | app change |
| External offset store keyed by event-id | absorbed | none | infra |
| Sentinel handshake message | bounded by sentinel | none | small app change |
| Switch to MirrorMaker 2 | none | none | run MM2 cluster |
| Switch to Cluster Linking | none | none | Confluent only |

The proxy-flip pattern is best when:
- Consumers are already idempotent (dedup table, upsert sink, etc.).
- The duplicate window is small enough to be cheap to re-process.
- You value zero new infrastructure over zero duplicates.

It is the wrong tool when:
- Each event has financial or legal side effects on first read.
- The consumer is a sink with no dedup primitive (e.g., counter
  increments without an idempotency key).
- Downstream ordering across cluster boundary matters.

## See also

- `step5-verify.sh` - confirms the producer and consumer are on dest;
  does not measure the duplicate window.
- `TROUBLESHOOTING.md` - operational failure modes (TLS, SNI, aliases).
- `PLAYBOOK.md` (PR #16) - operator runbook for production cutover.
