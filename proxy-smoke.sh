#!/usr/bin/env bash
#
# proxy-smoke.sh - Round-trip TLS smoke test through both proxies.
#
# For each cluster (source, dest):
#   1. Create a unique smoke topic (1 partition) directly on the broker.
#   2. Produce N records THROUGH producer-proxy on TLS+SNI.
#   3. Consume them THROUGH consumer-proxy on TLS+SNI.
#   4. Confirm the count matches.
#   5. Delete the smoke topic.
#
# Validates the full wire path (client TLS -> SNI route -> Kroxylicious ->
# backend broker) for both virtual clusters in one shot. Use it:
#   - in CI as a synthetic probe after step1-start.sh,
#   - between migration steps to confirm both backends still answer,
#   - after rotating certs to confirm clients still trust the proxy.
#
# Different from:
#   - doctor.sh        (file-level config drift, no traffic)
#   - cert-check.sh    (keystore expiry, no traffic)
#   - topic-parity.sh  (broker config equality, no client traffic)
#   - bench.sh         (throughput - heavy, single path)
#

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RECORDS="${RECORDS:-50}"
TIMEOUT_MS="${TIMEOUT_MS:-30000}"
CONTAINER_CMD="${CONTAINER_CMD:-docker}"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

ok()   { printf "${GREEN}[OK]${NC}   %s\n" "$1"; }
warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; }
fail() { printf "${RED}[FAIL]${NC} %s\n" "$1" >&2; }

require_running() {
    local name="$1"
    if ! $CONTAINER_CMD ps --format '{{.Names}}' | grep -q "^${name}$"; then
        fail "${name} not running. Start the demo first: ./step1-start.sh"
        exit 1
    fi
}

require_running kafka-source
require_running producer-proxy
require_running consumer-proxy

CERTS_DIR="$SCRIPT_DIR/certs/generated"
if [ ! -f "$CERTS_DIR/truststore.p12" ]; then
    fail "Missing $CERTS_DIR/truststore.p12 - run ./certs/generate-certs.sh"
    exit 1
fi

NETWORK=$($CONTAINER_CMD inspect kafka-source \
    --format '{{range $k, $_ := .NetworkSettings.Networks}}{{$k}}{{end}}')
KAFKA_IMAGE=$($CONTAINER_CMD inspect kafka-source --format '{{.Config.Image}}')
if [ -z "$NETWORK" ] || [ -z "$KAFKA_IMAGE" ]; then
    fail "Could not introspect kafka-source network/image."
    exit 1
fi

SMOKE_TOPIC="smoke-$(date +%s)-$$"
echo -e "${CYAN}Smoke topic: ${SMOKE_TOPIC}   records: ${RECORDS}${NC}"
echo

# Track success per cluster so we always attempt cleanup of the topic on
# both backends even if one half fails.
RESULT_SOURCE="skipped"
RESULT_DEST="skipped"

cleanup() {
    for backend in kafka-source kafka-dest; do
        if $CONTAINER_CMD ps --format '{{.Names}}' | grep -q "^${backend}$"; then
            $CONTAINER_CMD exec "$backend" /opt/kafka/bin/kafka-topics.sh \
                --bootstrap-server localhost:9092 \
                --delete --topic "$SMOKE_TOPIC" \
                > /dev/null 2>&1 || true
        fi
    done
}
trap cleanup EXIT

# Round-trip a smoke topic through one virtual cluster pair.
# $1: cluster label (source|dest)
# $2: backend container (kafka-source|kafka-dest)
# $3: producer-proxy SNI host (e.g. source.producer-proxy)
# $4: consumer-proxy SNI host (e.g. source.consumer-proxy)
round_trip() {
    local label="$1" backend="$2" prod_host="$3" cons_host="$4"

    echo -e "${YELLOW}[${label}] create topic on ${backend}${NC}"
    if ! $CONTAINER_CMD exec "$backend" /opt/kafka/bin/kafka-topics.sh \
            --bootstrap-server localhost:9092 \
            --create --if-not-exists --topic "$SMOKE_TOPIC" \
            --partitions 1 --replication-factor 1 > /dev/null 2>&1; then
        fail "[${label}] could not create topic on ${backend}"
        return 1
    fi

    echo -e "${YELLOW}[${label}] produce ${RECORDS} records via ${prod_host}:9192${NC}"
    if ! $CONTAINER_CMD run --rm --network "$NETWORK" \
            -v "$CERTS_DIR:/certs:ro" \
            -e RECORDS="$RECORDS" \
            "$KAFKA_IMAGE" \
            bash -c '
                set -euo pipefail
                for i in $(seq 1 "$RECORDS"); do echo "smoke-$i"; done | \
                    /opt/kafka/bin/kafka-console-producer.sh \
                        --bootstrap-server '"$prod_host"':9192 \
                        --topic '"$SMOKE_TOPIC"' \
                        --producer-property security.protocol=SSL \
                        --producer-property ssl.truststore.location=/certs/truststore.p12 \
                        --producer-property ssl.truststore.password=changeit \
                        --producer-property ssl.endpoint.identification.algorithm=https
            ' > /dev/null 2>&1; then
        fail "[${label}] produce failed via ${prod_host}:9192"
        return 1
    fi

    echo -e "${YELLOW}[${label}] consume back via ${cons_host}:9292 (timeout ${TIMEOUT_MS}ms)${NC}"
    local consume_out
    consume_out=$(mktemp)
    # shellcheck disable=SC2064
    trap "rm -f '$consume_out'" RETURN

    if ! $CONTAINER_CMD run --rm --network "$NETWORK" \
            -v "$CERTS_DIR:/certs:ro" \
            "$KAFKA_IMAGE" \
            /opt/kafka/bin/kafka-console-consumer.sh \
                --bootstrap-server "$cons_host:9292" \
                --topic "$SMOKE_TOPIC" \
                --from-beginning \
                --max-messages "$RECORDS" \
                --timeout-ms "$TIMEOUT_MS" \
                --consumer-property security.protocol=SSL \
                --consumer-property ssl.truststore.location=/certs/truststore.p12 \
                --consumer-property ssl.truststore.password=changeit \
                --consumer-property ssl.endpoint.identification.algorithm=https \
                > "$consume_out" 2>/dev/null; then
        # Console consumer exits non-zero on --timeout-ms even when it got the
        # expected count. We treat the count as ground truth, not the exit code.
        :
    fi

    local got
    got=$(grep -c '^smoke-' "$consume_out" || true)
    if [ "$got" -eq "$RECORDS" ]; then
        ok "[${label}] round-trip ${RECORDS}/${RECORDS} via ${prod_host} -> ${cons_host}"
        return 0
    else
        fail "[${label}] expected ${RECORDS} records, consumed ${got}"
        return 1
    fi
}

if round_trip "source" kafka-source source.producer-proxy source.consumer-proxy; then
    RESULT_SOURCE="pass"
else
    RESULT_SOURCE="fail"
fi
echo

if $CONTAINER_CMD ps --format '{{.Names}}' | grep -q '^kafka-dest$'; then
    if round_trip "dest" kafka-dest dest.producer-proxy dest.consumer-proxy; then
        RESULT_DEST="pass"
    else
        RESULT_DEST="fail"
    fi
else
    warn "kafka-dest not running - dest path skipped (run step2-migrate-producer.sh first)"
    RESULT_DEST="skipped"
fi

echo
echo -e "${CYAN}Summary${NC}"
printf "  source: %s\n" "$RESULT_SOURCE"
printf "  dest:   %s\n" "$RESULT_DEST"

if [ "$RESULT_SOURCE" = "fail" ] || [ "$RESULT_DEST" = "fail" ]; then
    exit 1
fi
exit 0
