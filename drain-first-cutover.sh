#!/usr/bin/env bash
#
# Drain-first cutover: the no-duplicate variant.
#
# The standard demo (step2 -> step3 -> step4) is the parallel/at-least-once
# variant: producer flips first, source drains, consumer flips. The
# consumer's dest-cluster group has no committed offset, so
# auto.offset.reset=earliest re-reads anything the producer wrote between
# step2 and step4 - the duplicate window.
#
# This script runs the inverse sequence to give an empty-dest no-duplicate
# cutover at the cost of a brief producer write pause:
#
#   1. Pause the producer (stop demo-producer container).
#   2. Drain the consumer on source until lag = 0.
#   3. Flip the consumer to dest (dest topic empty, 'earliest' is a no-op).
#   4. Flip the producer to dest and resume.
#
# Trade vs the parallel flow:
# - No duplicates (dest is empty when consumer attaches).
# - Producer write pause = drain time (typically seconds for keep-up
#   consumers, longer if backlog exists).
# - Application must tolerate the pause OR buffer producer writes upstream.
#
# Use this variant when application semantics cannot tolerate duplicate
# delivery and the workload allows a brief write pause. Use the parallel
# flow (step2-step4 + offset-bridge.sh) when the producer cannot pause.
#

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yaml"
GROUP="demo-consumer"
CONTAINER_CMD="${CONTAINER_CMD:-docker}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}== Drain-first cutover (no-duplicate variant) ==${NC}"
echo ""

# --- 1. Pause producer ---------------------------------------------------
echo -e "${YELLOW}[1/4] Stopping producer to freeze source topic...${NC}"
"$CONTAINER_CMD" compose -f "$COMPOSE_FILE" stop producer >/dev/null
echo "  producer stopped"
echo ""

# --- 2. Drain source -----------------------------------------------------
echo -e "${YELLOW}[2/4] Draining consumer group '$GROUP' on source...${NC}"
DRAIN_START=$(date +%s)
while true; do
    OUTPUT=$("$CONTAINER_CMD" exec kafka-source /opt/kafka/bin/kafka-consumer-groups.sh \
        --bootstrap-server localhost:9092 --describe --group "$GROUP" 2>/dev/null || echo "")

    if [ -z "$OUTPUT" ] || echo "$OUTPUT" | grep -q "does not exist"; then
        echo "  Waiting for consumer group to appear..."
        sleep 3
        continue
    fi

    LAG=$(echo "$OUTPUT" | awk 'NR>1 && $6 ~ /^[0-9]+$/ { sum += $6 } END { print sum+0 }')
    CURRENT=$(echo "$OUTPUT" | awk 'NR>1 && $4 ~ /^[0-9]+$/ { sum += $4 } END { print sum+0 }')
    LOG_END=$(echo "$OUTPUT" | awk 'NR>1 && $5 ~ /^[0-9]+$/ { sum += $5 } END { print sum+0 }')

    printf "  current-offset=%-6s  log-end-offset=%-6s  lag=%s\n" "$CURRENT" "$LOG_END" "$LAG"

    if [ "$LAG" -eq 0 ] 2>/dev/null; then
        DRAIN_ELAPSED=$(($(date +%s) - DRAIN_START))
        echo -e "${GREEN}  drained in ${DRAIN_ELAPSED}s${NC}"
        break
    fi
    sleep 2
done
echo ""

# --- 3. Flip consumer ----------------------------------------------------
echo -e "${YELLOW}[3/4] Migrating consumer: source.consumer-proxy -> dest.consumer-proxy${NC}"
CONSUMER_BOOTSTRAP=dest.consumer-proxy:9292 \
  "$CONTAINER_CMD" compose -f "$COMPOSE_FILE" up -d --force-recreate --no-deps consumer >/dev/null
echo "  consumer recreated against dest"
echo ""

# --- 4. Flip and resume producer -----------------------------------------
echo -e "${YELLOW}[4/4] Starting producer against dest: dest.producer-proxy:9192${NC}"
PRODUCER_BOOTSTRAP=dest.producer-proxy:9192 \
  "$CONTAINER_CMD" compose -f "$COMPOSE_FILE" up -d --force-recreate --no-deps producer >/dev/null
echo "  producer recreated against dest"
echo ""

CUTOVER_ELAPSED=$(($(date +%s) - DRAIN_START))
echo -e "${GREEN}== Cutover complete in ${CUTOVER_ELAPSED}s (write pause = drain + flip) ==${NC}"
echo ""
echo -e "${CYAN}Verify with: ./step5-verify.sh${NC}"
echo -e "${CYAN}If you ran audit-delivery.sh against this run, expect overlap=0.${NC}"
