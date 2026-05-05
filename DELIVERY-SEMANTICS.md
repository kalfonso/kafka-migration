# Delivery Semantics During Cutover

What this migration pattern guarantees, what it does not, and the
duplicate window every operator should know about before running it
on a real workload.

## TL;DR

The proxy-flip pattern supports two cutover modes:

- **Parallel flip** (this demo's `step1`-`step5`): producer migrates first
  while consumer drains source. Simple and zero-downtime for writes, but
  **at-least-once** - the consumer re-reads everything produced to dest
  during the drain. Use this only if your consumer is idempotent.
- **Drain-first flip** (recommended for non-idempotent consumers): pause
  the producer, drain the consumer on source, flip the consumer to dest,
  then resume the producer on dest. **No duplicates, no loss**, at the
  cost of a brief write pause equal to the source drain time.

The "duplicates" in the rest of this doc are specific to the parallel
flip. The drain-first variant eliminates them by construction - see
[Drain-first cutover](#drain-first-cutover-no-duplicates).

## Drain-first cutover (no duplicates)

If the consumer is not idempotent, run the cutover so that the producer
is never writing to dest while the consumer is still reading source.
Each record then exists on exactly one cluster and is consumed exactly
once.

```
              pause-prod   drain done   flip-consumer   resume-prod
producer:  ---|              ...                       |--- writes to dest
consumer:  reads source -----+--------|         |------- reads dest from 0
                              <-------- write pause ----->
                              dest is empty during the
                              flip, so 'earliest' = no
                              duplicates and no loss
```

Step sequence (overlay on the existing scripts):

1. `step1-start.sh` - start everything; producer writes to source.
2. **Pause the producer** (`docker compose stop producer`). This is the
   only behavioural change vs. the parallel flip.
3. `step3-check-lag.sh` - wait for the consumer group on source to reach
   lag 0.
4. `step4-migrate-consumer.sh` - flip the consumer to dest. Dest is
   empty, so `auto.offset.reset=earliest` reads from offset 0 of an
   empty topic - a no-op until step 5.
5. **Resume the producer on dest** (`PRODUCER_BOOTSTRAP=dest.producer-proxy:9192
   docker compose up -d --force-recreate --no-deps producer`).

Why this works:

- The producer never writes to dest while the consumer is on source, so
  there is no "produced-to-dest while consumer-on-source" window to
  replay.
- When the consumer flips to dest, the dest topic is empty (or only has
  records produced after the flip, which the consumer is now reading
  online). `auto.offset.reset=earliest` is safe.
- No `__consumer_offsets` translation is needed - there is nothing to
  translate, because the consumer never had an offset on dest before
  the flip and there is nothing on dest before the flip.

The trade is a write pause for the duration of step 3 (source drain
time). At demo defaults that is ~5-15s. At 10k msg/sec with a 60s drain
that is 60s of write back-pressure - usually acceptable, occasionally
not. If write availability is non-negotiable, run the parallel flip and
make the consumer idempotent (see [Hardening](#hardening-for-production)).

## Why duplicates exist (parallel flip)

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
| Parallel flip + `auto.offset.reset=earliest` (this demo's default) | yes, sized as above | none | $0 |
| Parallel flip + `auto.offset.reset=latest` after step 4 | none from window | yes, the window | $0, ops risk |
| **Drain-first flip** (above) | **none** | **none** | **brief write pause** |
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
