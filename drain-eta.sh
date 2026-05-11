#!/usr/bin/env bash
#
# drain-eta.sh - estimate how long step3 (consumer drain) will take.
#
# Why: step3-check-lag.sh polls until lag reaches 0 but never says how
# much longer that will take. dashboard.sh shows live producer/consumer
# rates but is interactive. Cutover planners need a one-shot, machine-
# parseable answer to two questions:
#   - Can the consumer actually drain (consume rate > produce rate)?
#   - If so, ETA in seconds for the planning window.
#
# How: sample (LEO, group current-offset, lag) twice over INTERVAL
# seconds. Compute:
#   produce_rate  = (LEO_t1  - LEO_t0)  / INTERVAL
#   consume_rate  = (CURR_t1 - CURR_t0) / INTERVAL
#   net_drain     = consume_rate - produce_rate
#   eta_seconds   = lag_t1 / net_drain   (only if net_drain > 0)
#
# Run during step3 (producer already on dest, consumer still on source)
# OR pre-cutover against any cluster - the math holds for any
# (broker, topic, group) triple.
#
# Usage:
#   ./drain-eta.sh
#   INTERVAL=10 ./drain-eta.sh
#   CLUSTER=kafka-dest GROUP=demo-consumer ./drain-eta.sh
#
# Output (stdout, key=value, one per line):
#   cluster=kafka-source
#   topic=orders
#   group=demo-consumer
#   lag=1234
#   produce_rate=200.0
#   consume_rate=250.0
#   net_drain_rate=50.0
#   eta_seconds=24
#
# Exit codes:
#   0 - ETA computed (consumer is draining)
#   1 - net drain rate <= 0 (consumer cannot keep up)
#   2 - consumer group or topic not found
#   3 - bad input / cluster unreachable
#

set -euo pipefail

CONTAINER_CMD="${CONTAINER_CMD:-docker}"
CLUSTER="${CLUSTER:-kafka-source}"
TOPIC="${TOPIC:-orders}"
GROUP="${GROUP:-demo-consumer}"
INTERVAL="${INTERVAL:-5}"

if ! [[ "$INTERVAL" =~ ^[0-9]+$ ]] || [ "$INTERVAL" -lt 1 ]; then
    echo "FAIL: INTERVAL must be a positive integer (got: $INTERVAL)" >&2
    exit 3
fi

end_offset() {
    { "$CONTAINER_CMD" exec "$CLUSTER" /opt/kafka/bin/kafka-get-offsets.sh \
        --bootstrap-server localhost:9092 --topic "$TOPIC" --time -1 2>/dev/null \
        || true; } | awk -F: '{ sum += $3 } END { print sum+0 }'
}

# Sums current-offset (col 4) and lag (col 6) across partitions for GROUP.
# Returns "<current-offset> <lag>" on stdout, or empty string if the group
# is missing or has no committed offsets for TOPIC.
group_state() {
    local out
    out=$("$CONTAINER_CMD" exec "$CLUSTER" /opt/kafka/bin/kafka-consumer-groups.sh \
        --bootstrap-server localhost:9092 --describe --group "$GROUP" 2>/dev/null || true)
    if [ -z "$out" ] || echo "$out" | grep -q "does not exist"; then
        echo ""
        return 0
    fi
    echo "$out" | awk -v t="$TOPIC" '
        NR>1 && $2==t && $4 ~ /^[0-9]+$/ && $6 ~ /^[0-9]+$/ { cur += $4; lag += $6 }
        END { printf "%d %d\n", cur+0, lag+0 }'
}

# Probe the cluster once before timing the sample window.
LEO_PROBE=$(end_offset)
if [ -z "$LEO_PROBE" ] || [ "$LEO_PROBE" = "0" ]; then
    # Distinguish "topic empty" from "cluster unreachable": kafka-topics --list
    # returns 0 with empty stdout on an empty broker, non-zero on connect error.
    if ! "$CONTAINER_CMD" exec "$CLUSTER" /opt/kafka/bin/kafka-topics.sh \
        --bootstrap-server localhost:9092 --list >/dev/null 2>&1; then
        echo "FAIL: cluster '$CLUSTER' unreachable" >&2
        exit 3
    fi
fi

GS=$(group_state)
if [ -z "$GS" ]; then
    echo "FAIL: consumer group '$GROUP' has no committed offsets for topic '$TOPIC' on '$CLUSTER'" >&2
    exit 2
fi

LEO_T0=$(end_offset)
read -r CUR_T0 LAG_T0 <<< "$GS"

sleep "$INTERVAL"

LEO_T1=$(end_offset)
GS=$(group_state)
read -r CUR_T1 LAG_T1 <<< "$GS"

PRODUCE_RATE=$(awk -v a="$LEO_T1" -v b="$LEO_T0" -v r="$INTERVAL" \
    'BEGIN { printf "%.1f", (a - b) / r }')
CONSUME_RATE=$(awk -v a="$CUR_T1" -v b="$CUR_T0" -v r="$INTERVAL" \
    'BEGIN { printf "%.1f", (a - b) / r }')
NET_DRAIN=$(awk -v c="$CONSUME_RATE" -v p="$PRODUCE_RATE" \
    'BEGIN { printf "%.1f", c - p }')

cat <<EOF
cluster=$CLUSTER
topic=$TOPIC
group=$GROUP
interval_s=$INTERVAL
lag=$LAG_T1
produce_rate=$PRODUCE_RATE
consume_rate=$CONSUME_RATE
net_drain_rate=$NET_DRAIN
EOF

if awk -v n="$NET_DRAIN" 'BEGIN { exit !(n <= 0) }'; then
    echo "eta_seconds=infinity"
    echo "" >&2
    echo "WARN: consumer is not draining (net_drain_rate=$NET_DRAIN msgs/s)." >&2
    echo "  produce_rate=$PRODUCE_RATE >= consume_rate=$CONSUME_RATE" >&2
    echo "  Stop or throttle the producer before attempting cutover." >&2
    exit 1
fi

# Lag could be 0 already (drain complete); print eta_seconds=0 in that case.
ETA=$(awk -v lag="$LAG_T1" -v n="$NET_DRAIN" \
    'BEGIN { if (lag <= 0) print 0; else printf "%d", (lag / n) + 0.5 }')
echo "eta_seconds=$ETA"
exit 0
