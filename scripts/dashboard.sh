#!/usr/bin/env bash
#
# Live dashboard for the migration demo.
#
# Continuously samples both Kafka clusters and prints, on a single
# refreshing screen:
#   - end-offset of TOPIC on source and dest (summed across partitions)
#   - delta-per-second since the previous tick (effective ingress rate)
#   - GROUP lag on source and on dest
#
# Ideal companion to ./step3-check-lag.sh: run this in a second terminal
# while you walk through step1..step5 and you'll see the producer "jump"
# from source to dest at step2, the source delta drop to 0, and the
# consumer-lag-on-source drain to 0 before step4 moves the consumer.
#
# Usage:
#   ./dashboard.sh                              # 2s refresh, topic=orders
#   REFRESH=1 TOPIC=orders ./dashboard.sh
#
# Ctrl-C to exit. No external dependencies beyond a container orchestrator (docker, podman) + the Apache
# Kafka CLI inside the broker images.
#

set -uo pipefail

TOPIC="${TOPIC:-orders}"
GROUP="${GROUP:-demo-consumer}"
REFRESH="${REFRESH:-2}"
SOURCE_CONTAINER="${SOURCE_CONTAINER:-kafka-source}"
DEST_CONTAINER="${DEST_CONTAINER:-kafka-dest}"
CONTAINER_CMD="${CONTAINER_CMD:-docker}"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

end_offset() {
    local container="$1"
    { ${CONTAINER_CMD} exec "$container" /opt/kafka/bin/kafka-get-offsets.sh \
        --bootstrap-server localhost:9092 --topic "$TOPIC" --time -1 2>/dev/null \
        || true; } | awk -F: '{ sum += $3 } END { print sum+0 }'
}

group_lag() {
    local container="$1"
    { ${CONTAINER_CMD} exec "$container" /opt/kafka/bin/kafka-consumer-groups.sh \
        --bootstrap-server localhost:9092 --describe --group "$GROUP" 2>/dev/null \
        || true; } | awk 'NR>1 && $6 ~ /^[0-9]+$/ { sum += $6 } END { print sum+0 }'
}

trap 'echo; echo -e "${DIM}dashboard stopped${NC}"; exit 0' INT TERM

PREV_SRC=""
PREV_DST=""

while true; do
    SRC=$(end_offset "$SOURCE_CONTAINER")
    DST=$(end_offset "$DEST_CONTAINER")
    SRC_LAG=$(group_lag "$SOURCE_CONTAINER")
    DST_LAG=$(group_lag "$DEST_CONTAINER")

    if [ -z "$PREV_SRC" ]; then
        SRC_RATE="-"
        DST_RATE="-"
    else
        SRC_RATE=$(awk -v a="$SRC" -v b="$PREV_SRC" -v r="$REFRESH" \
            'BEGIN { printf "%.1f", (a - b) / r }')
        DST_RATE=$(awk -v a="$DST" -v b="$PREV_DST" -v r="$REFRESH" \
            'BEGIN { printf "%.1f", (a - b) / r }')
    fi
    PREV_SRC="$SRC"
    PREV_DST="$DST"

    clear
    printf "${BOLD}${CYAN}Migration dashboard${NC}    topic=%s  group=%s  refresh=%ss\n" \
        "$TOPIC" "$GROUP" "$REFRESH"
    printf "${DIM}%s${NC}\n\n" "$(date '+%Y-%m-%d %H:%M:%S')"

    printf "  ${BOLD}%-12s${NC}  end-offset=%-7s  rate=%-6s msgs/s  group-lag=%s\n" \
        "source" "$SRC" "$SRC_RATE" "${SRC_LAG:-?}"
    printf "  ${BOLD}%-12s${NC}  end-offset=%-7s  rate=%-6s msgs/s  group-lag=%s\n" \
        "dest"   "$DST" "$DST_RATE" "${DST_LAG:-?}"

    echo ""
    if [ "${SRC_RATE}" != "-" ]; then
        if awk "BEGIN { exit !($SRC_RATE > 0) }"; then
            SRC_STATE="${YELLOW}producer still on source${NC}"
        else
            SRC_STATE="${GREEN}source quiet${NC}"
        fi
        if awk "BEGIN { exit !($DST_RATE > 0) }"; then
            DST_STATE="${GREEN}producer on dest${NC}"
        else
            DST_STATE="${DIM}dest idle${NC}"
        fi
        printf "  ${DIM}status:${NC} %b   %b\n" "$SRC_STATE" "$DST_STATE"
    fi

    echo ""
    echo -e "${DIM}Ctrl-C to exit${NC}"

    sleep "$REFRESH"
done
