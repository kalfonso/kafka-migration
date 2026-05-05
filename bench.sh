#!/usr/bin/env bash
#
# bench.sh - Measure Kroxylicious proxy overhead vs direct PLAINTEXT.
#
# Runs kafka-producer-perf-test.sh twice against kafka-source:
#   1. Direct PLAINTEXT inside the kafka-source container (baseline)
#   2. Through producer-proxy with TLS + SNI (what real clients pay)
#
# Reports the throughput and latency numbers side by side so you can quote
# a real overhead figure when someone asks "what does the proxy cost?".
#
# Requires the demo to be running (./step1-start.sh).
#

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TOPIC_DIRECT="${TOPIC_DIRECT:-bench-direct}"
TOPIC_PROXIED="${TOPIC_PROXIED:-bench-proxied}"
RECORDS="${RECORDS:-200000}"
RECORD_SIZE="${RECORD_SIZE:-200}"
THROUGHPUT="${THROUGHPUT:--1}"   # -1 = unbounded
PARTITIONS="${PARTITIONS:-3}"
ACKS="${ACKS:-all}"
CONTAINER_CMD="${CONTAINER_CMD:-docker}"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

if ! $CONTAINER_CMD ps --format '{{.Names}}' | grep -q '^kafka-source$'; then
    echo -e "${RED}kafka-source not running. Start the demo first: ./step1-start.sh${NC}" >&2
    exit 1
fi
if ! $CONTAINER_CMD ps --format '{{.Names}}' | grep -q '^producer-proxy$'; then
    echo -e "${RED}producer-proxy not running. Start the demo first: ./step1-start.sh${NC}" >&2
    exit 1
fi

# Resolve the docker-compose network kafka-source is attached to so the
# ephemeral kafka-tools container can reach producer-proxy by SNI hostname.
NETWORK=$($CONTAINER_CMD inspect kafka-source \
    --format '{{range $k, $_ := .NetworkSettings.Networks}}{{$k}}{{end}}')
KAFKA_IMAGE=$($CONTAINER_CMD inspect kafka-source --format '{{.Config.Image}}')

if [ -z "$NETWORK" ] || [ -z "$KAFKA_IMAGE" ]; then
    echo -e "${RED}Could not introspect kafka-source network/image.${NC}" >&2
    exit 1
fi

CERTS_DIR="$SCRIPT_DIR/certs/generated"
if [ ! -f "$CERTS_DIR/truststore.p12" ]; then
    echo -e "${RED}Missing $CERTS_DIR/truststore.p12 - run ./certs/generate-certs.sh${NC}" >&2
    exit 1
fi

echo -e "${CYAN}Network: $NETWORK   Image: $KAFKA_IMAGE${NC}"
echo -e "${CYAN}Workload: ${RECORDS} records x ${RECORD_SIZE}B, throughput=${THROUGHPUT}, acks=${ACKS}, partitions=${PARTITIONS}${NC}"
echo

create_topic() {
    local topic="$1"
    $CONTAINER_CMD exec kafka-source /opt/kafka/bin/kafka-topics.sh \
        --bootstrap-server localhost:9092 \
        --create --if-not-exists --topic "$topic" \
        --partitions "$PARTITIONS" --replication-factor 1 > /dev/null
}

create_topic "$TOPIC_DIRECT"
create_topic "$TOPIC_PROXIED"

DIRECT_OUT=$(mktemp)
PROXIED_OUT=$(mktemp)
trap 'rm -f "$DIRECT_OUT" "$PROXIED_OUT"' EXIT

echo -e "${YELLOW}[1/2] Direct PLAINTEXT (kafka-source -> localhost:9092) ...${NC}"
$CONTAINER_CMD exec kafka-source /opt/kafka/bin/kafka-producer-perf-test.sh \
    --topic "$TOPIC_DIRECT" \
    --num-records "$RECORDS" \
    --record-size "$RECORD_SIZE" \
    --throughput "$THROUGHPUT" \
    --producer-props \
        bootstrap.servers=localhost:9092 \
        acks="$ACKS" \
    > "$DIRECT_OUT" 2>&1

echo -e "${YELLOW}[2/2] Proxied TLS  (ephemeral -> source.producer-proxy:9192) ...${NC}"
$CONTAINER_CMD run --rm --network "$NETWORK" \
    -v "$CERTS_DIR:/certs:ro" \
    "$KAFKA_IMAGE" \
    /opt/kafka/bin/kafka-producer-perf-test.sh \
        --topic "$TOPIC_PROXIED" \
        --num-records "$RECORDS" \
        --record-size "$RECORD_SIZE" \
        --throughput "$THROUGHPUT" \
        --producer-props \
            bootstrap.servers=source.producer-proxy:9192 \
            acks="$ACKS" \
            security.protocol=SSL \
            ssl.truststore.location=/certs/truststore.p12 \
            ssl.truststore.password=changeit \
            ssl.endpoint.identification.algorithm=https \
    > "$PROXIED_OUT" 2>&1

# Last line of perf-test output is the summary, e.g.:
#   200000 records sent, 95238.095 records/sec (18.16 MB/sec), 4.12 ms avg latency, ...
DIRECT_SUMMARY=$(tail -n 1 "$DIRECT_OUT")
PROXIED_SUMMARY=$(tail -n 1 "$PROXIED_OUT")

# Pull rec/sec out of "X records sent, Y records/sec ..." for a delta.
rec_per_sec() {
    sed -E 's/.*records sent, ([0-9.]+) records\/sec.*/\1/' <<<"$1"
}
avg_latency() {
    sed -E 's/.*records\/sec [^,]+, ([0-9.]+) ms avg latency.*/\1/' <<<"$1"
}
p99() {
    sed -E 's/.*, ([0-9.]+) ms 99th.*/\1/' <<<"$1"
}

DIRECT_RPS=$(rec_per_sec "$DIRECT_SUMMARY")
PROXIED_RPS=$(rec_per_sec "$PROXIED_SUMMARY")
DIRECT_P99=$(p99 "$DIRECT_SUMMARY")
PROXIED_P99=$(p99 "$PROXIED_SUMMARY")
DIRECT_AVG=$(avg_latency "$DIRECT_SUMMARY")
PROXIED_AVG=$(avg_latency "$PROXIED_SUMMARY")

echo
echo -e "${GREEN}Direct  (PLAINTEXT, localhost:9092):${NC}"
echo "  $DIRECT_SUMMARY"
echo -e "${GREEN}Proxied (TLS, source.producer-proxy:9192):${NC}"
echo "  $PROXIED_SUMMARY"
echo

if [[ "$DIRECT_RPS" =~ ^[0-9.]+$ ]] && [[ "$PROXIED_RPS" =~ ^[0-9.]+$ ]]; then
    THROUGHPUT_DELTA=$(awk -v d="$DIRECT_RPS" -v p="$PROXIED_RPS" \
        'BEGIN { printf "%+.1f", (p - d) * 100.0 / d }')
    LATENCY_DELTA=$(awk -v d="$DIRECT_AVG" -v p="$PROXIED_AVG" \
        'BEGIN { printf "%+.2f", p - d }')
    P99_DELTA=$(awk -v d="$DIRECT_P99" -v p="$PROXIED_P99" \
        'BEGIN { printf "%+.2f", p - d }')
    printf "${CYAN}Overhead${NC}  throughput: %s%%   avg latency: %s ms   p99: %s ms\n" \
        "$THROUGHPUT_DELTA" "$LATENCY_DELTA" "$P99_DELTA"
else
    echo -e "${YELLOW}Could not parse perf-test summary - showing raw lines above.${NC}"
fi
