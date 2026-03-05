#!/usr/bin/env bash
#
# Step 3: Monitor consumer lag on the source cluster.
#
# After the producer has been migrated (step 2), no new messages arrive on
# source. This script polls the consumer group lag until it reaches 0.
#

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GROUP="demo-consumer"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${YELLOW}Monitoring consumer group '$GROUP' lag on source cluster...${NC}"
echo -e "${CYAN}(Waiting for lag to reach 0 — the consumer is draining the source topic)${NC}"
echo ""

while true; do
    OUTPUT=$(docker exec kafka-source /opt/kafka/bin/kafka-consumer-groups.sh \
        --bootstrap-server localhost:9092 --describe --group "$GROUP" 2>/dev/null || echo "")

    if [ -z "$OUTPUT" ] || echo "$OUTPUT" | grep -q "does not exist"; then
        echo "  Waiting for consumer group to appear..."
        sleep 3
        continue
    fi

    LAG=$(echo "$OUTPUT" | awk 'NR>1 && $6 ~ /^[0-9]+$/ { sum += $6 } END { print sum+0 }')
    CURRENT=$(echo "$OUTPUT" | awk 'NR>1 && $4 ~ /^[0-9]+$/ { print $4 }')
    LOG_END=$(echo "$OUTPUT" | awk 'NR>1 && $5 ~ /^[0-9]+$/ { print $5 }')

    printf "  current-offset=%-6s  log-end-offset=%-6s  lag=%s\n" "$CURRENT" "$LOG_END" "$LAG"

    if [ "$LAG" -eq 0 ] 2>/dev/null; then
        echo ""
        echo -e "${GREEN}Lag is 0 — consumer has fully drained the source topic.${NC}"
        echo ""
        echo "Next: ./step4-migrate-consumer.sh   # move consumer to dest cluster"
        exit 0
    fi

    sleep 2
done
