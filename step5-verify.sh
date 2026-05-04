#!/usr/bin/env bash
#
# Step 5: Verify the migration end-state.
#
# After steps 1-4 the producer and consumer should both be on kafka-dest.
# This script confirms that:
#   1. The source-cluster log-end-offset is no longer advancing
#      (the producer has stopped writing to source).
#   2. The dest-cluster log-end-offset IS advancing
#      (the producer is now writing to dest).
#   3. The 'demo-consumer' group has fully drained source (lag = 0).
#   4. The 'demo-consumer' group is reading from dest (lag at or near 0).
#

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOPIC="${TOPIC:-orders}"
GROUP="${GROUP:-demo-consumer}"
SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-3}"
CONTAINER_CMD="${CONTAINER_CMD:-docker}"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

end_offset() {
    local cluster="$1"
    { "$CONTAINER_CMD" exec "$cluster" /opt/kafka/bin/kafka-get-offsets.sh \
        --bootstrap-server localhost:9092 --topic "$TOPIC" --time -1 2>/dev/null \
        || true; } | awk -F: '{ sum += $3 } END { print sum+0 }'
}

group_lag() {
    local cluster="$1"
    { "$CONTAINER_CMD" exec "$cluster" /opt/kafka/bin/kafka-consumer-groups.sh \
        --bootstrap-server localhost:9092 --describe --group "$GROUP" 2>/dev/null \
        || true; } | awk 'NR>1 && $6 ~ /^[0-9]+$/ { sum += $6 } END { print sum+0 }'
}

echo -e "${CYAN}Sampling source/dest end-offsets over ${SAMPLE_INTERVAL}s ...${NC}"

SRC_T0=$(end_offset kafka-source)
DST_T0=$(end_offset kafka-dest)
sleep "$SAMPLE_INTERVAL"
SRC_T1=$(end_offset kafka-source)
DST_T1=$(end_offset kafka-dest)

SRC_LAG=$(group_lag kafka-source)
DST_LAG=$(group_lag kafka-dest)

SRC_DELTA=$((SRC_T1 - SRC_T0))
DST_DELTA=$((DST_T1 - DST_T0))

printf "\n  %-22s  t0=%-6s t1=%-6s delta=%-3s\n" "kafka-source $TOPIC" "$SRC_T0" "$SRC_T1" "$SRC_DELTA"
printf "  %-22s  t0=%-6s t1=%-6s delta=%-3s\n"   "kafka-dest   $TOPIC" "$DST_T0" "$DST_T1" "$DST_DELTA"
printf "  %-22s  source-lag=%-6s dest-lag=%-6s\n\n" "$GROUP" "${SRC_LAG:-?}" "${DST_LAG:-?}"

ok=0
fail=0
check() {
    if eval "$2"; then
        echo -e "  ${GREEN}PASS${NC} $1"
        ok=$((ok + 1))
    else
        echo -e "  ${RED}FAIL${NC} $1"
        fail=$((fail + 1))
    fi
}

check "producer no longer writing to source (delta == 0)"   "[ \"$SRC_DELTA\" -eq 0 ]"
check "producer writing to dest (delta > 0)"                "[ \"$DST_DELTA\" -gt 0 ]"
check "consumer drained source ($GROUP lag == 0)"           "[ \"${SRC_LAG:-1}\" -eq 0 ]"
check "consumer keeping up on dest (lag <= delta)"          "[ \"${DST_LAG:-9999}\" -le \"$DST_DELTA\" ]"

echo ""
if [ "$fail" -eq 0 ]; then
    echo -e "${GREEN}Migration verified: $ok/$ok checks passed.${NC}"
    exit 0
else
    echo -e "${YELLOW}$fail check(s) failed - migration may be incomplete or step 4 has not run yet.${NC}"
    exit 1
fi
