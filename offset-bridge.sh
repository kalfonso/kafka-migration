#!/usr/bin/env bash
#
# offset-bridge.sh - Translate consumer-group offsets from source to dest by
# timestamp, eliminating the auto.offset.reset duplicate window during the
# proxy-flip cutover.
#
# Why:
#   sniHostIdentifiesNode flip is stateless. __consumer_offsets are per-cluster,
#   so a consumer flipped to dest with no committed group falls back to
#   auto.offset.reset. With 'earliest' you replay everything; with 'latest' you
#   risk dropping in-flight records. This script seeds dest's __consumer_offsets
#   from source's, mapped by message timestamp, so the consumer resumes at the
#   right logical position on dest.
#
# Algorithm:
#   1. For each (topic, partition) in the source group's committed offsets,
#      read the timestamp of the message at that offset on source.
#   2. Look up the first dest offset at or after that timestamp.
#   3. Write the (topic, partition, dest_offset) plan as a reset CSV.
#   4. With --execute, apply via kafka-consumer-groups --reset-offsets.
#
# Run AFTER the producer has been migrated (step2) and dest has received at
# least the records the consumer needs to resume from. Run BEFORE step4
# (consumer flip).
#
# Usage:
#   ./offset-bridge.sh --group GROUP --topic TOPIC [--execute]
#
# Defaults to dry-run; print the plan without modifying dest.
#

set -euo pipefail

GROUP=""
TOPIC=""
EXECUTE=0
CONTAINER_CMD="${CONTAINER_CMD:-docker}"
SOURCE_CONTAINER="${SOURCE_CONTAINER:-kafka-source}"
DEST_CONTAINER="${DEST_CONTAINER:-kafka-dest}"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

usage() {
    cat <<EOF
Usage: $0 --group GROUP --topic TOPIC [--execute]

  --group GROUP   consumer group whose offsets will be bridged
  --topic TOPIC   topic name (must exist on both clusters)
  --execute       apply the reset on dest (default: dry-run)

Env overrides: CONTAINER_CMD, SOURCE_CONTAINER, DEST_CONTAINER.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --group) GROUP="$2"; shift 2 ;;
        --topic) TOPIC="$2"; shift 2 ;;
        --execute) EXECUTE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
    esac
done

if [ -z "$GROUP" ] || [ -z "$TOPIC" ]; then
    usage
    exit 2
fi

require_container() {
    local name="$1"
    if ! $CONTAINER_CMD ps --format '{{.Names}}' | grep -q "^${name}$"; then
        echo -e "${RED}Container '$name' is not running. Start the demo first.${NC}" >&2
        exit 1
    fi
}
require_container "$SOURCE_CONTAINER"
require_container "$DEST_CONTAINER"

# Verify topic exists on dest. Source existence is implied by the group's
# committed offsets; if dest is missing the topic we cannot proceed.
if ! $CONTAINER_CMD exec "$DEST_CONTAINER" /opt/kafka/bin/kafka-topics.sh \
        --bootstrap-server localhost:9092 --list 2>/dev/null \
        | grep -qx "$TOPIC"; then
    echo -e "${RED}Topic '$TOPIC' does not exist on $DEST_CONTAINER. Create it before bridging.${NC}" >&2
    exit 1
fi

echo -e "${CYAN}Bridging offsets for group=${GROUP} topic=${TOPIC}${NC}"
echo -e "${CYAN}  source=${SOURCE_CONTAINER}  dest=${DEST_CONTAINER}  execute=${EXECUTE}${NC}"
echo

# Parse source committed offsets.
# kafka-consumer-groups --describe columns: GROUP TOPIC PARTITION CURRENT-OFFSET LOG-END-OFFSET LAG ...
DESCRIBE=$($CONTAINER_CMD exec "$SOURCE_CONTAINER" /opt/kafka/bin/kafka-consumer-groups.sh \
    --bootstrap-server localhost:9092 --describe --group "$GROUP" 2>/dev/null || true)

if [ -z "$DESCRIBE" ] || echo "$DESCRIBE" | grep -q "does not exist"; then
    echo -e "${RED}Consumer group '$GROUP' has no committed offsets on $SOURCE_CONTAINER.${NC}" >&2
    exit 1
fi

# Extract (partition, current-offset, log-end) for the requested topic.
# Filter on column 2 (TOPIC) so we only handle the topic the user asked about.
ROWS=$(echo "$DESCRIBE" | awk -v t="$TOPIC" 'NR>1 && $2==t && $3 ~ /^[0-9]+$/ { print $3, $4, $5 }')

if [ -z "$ROWS" ]; then
    echo -e "${RED}No committed offsets for topic '$TOPIC' in group '$GROUP'.${NC}" >&2
    exit 1
fi

# read message timestamp at (topic, partition, offset) on source.
# kafka-console-consumer with --partition --offset reads exactly that record.
# print.timestamp=true emits "CreateTime:<ms>\t..." as the first field.
read_timestamp_at() {
    local partition="$1"
    local offset="$2"
    local out
    out=$($CONTAINER_CMD exec "$SOURCE_CONTAINER" /opt/kafka/bin/kafka-console-consumer.sh \
        --bootstrap-server localhost:9092 \
        --topic "$TOPIC" \
        --partition "$partition" \
        --offset "$offset" \
        --max-messages 1 \
        --property print.timestamp=true \
        --timeout-ms 5000 2>/dev/null || true)
    # Expected: "CreateTime:<ms>\t..." possibly preceded by warnings.
    echo "$out" | awk -F'[:\t]' '/^CreateTime:/ { print $2; exit }'
}

# return first dest offset whose timestamp >= ts_ms. -1 means no such message.
dest_offset_for_timestamp() {
    local partition="$1"
    local ts_ms="$2"
    # kafka-get-offsets is the modern entry point; on older images it lives as
    # GetOffsetShell via kafka-run-class.
    local out
    out=$($CONTAINER_CMD exec "$DEST_CONTAINER" /opt/kafka/bin/kafka-get-offsets.sh \
        --bootstrap-server localhost:9092 \
        --topic-partitions "${TOPIC}:${partition}" \
        --time "$ts_ms" 2>/dev/null || true)
    if [ -z "$out" ]; then
        out=$($CONTAINER_CMD exec "$DEST_CONTAINER" /opt/kafka/bin/kafka-run-class.sh \
            kafka.tools.GetOffsetShell \
            --broker-list localhost:9092 \
            --topic "$TOPIC" --partitions "$partition" \
            --time "$ts_ms" 2>/dev/null || true)
    fi
    # Format: "topic:partition:offset"
    echo "$out" | awk -F: 'NF>=3 { print $NF; exit }'
}

PLAN=$(mktemp)
trap 'rm -f "$PLAN"' EXIT

printf "%-9s %-15s %-15s %-15s %s\n" "PART" "SOURCE-OFFSET" "SOURCE-TS-MS" "DEST-OFFSET" "NOTE"

SKIPPED=0
PLANNED=0
while read -r part src_offset src_log_end; do
    [ -z "$part" ] && continue
    if ! [[ "$src_offset" =~ ^[0-9]+$ ]]; then
        printf "%-9s %-15s %-15s %-15s %s\n" "$part" "$src_offset" "-" "-" "no committed offset, skipped"
        SKIPPED=$((SKIPPED+1))
        continue
    fi

    # If the consumer is caught up (offset == LEO), there is no message AT that
    # offset; use the LEO timestamp by reading the last consumed record (LEO-1).
    probe_offset="$src_offset"
    note=""
    if [ "$src_offset" = "$src_log_end" ] && [ "$src_offset" -gt 0 ]; then
        probe_offset=$((src_offset - 1))
        note="caught-up; probed offset-1"
    elif [ "$src_offset" = "0" ] && [ "$src_log_end" = "0" ]; then
        printf "%-9s %-15s %-15s %-15s %s\n" "$part" "$src_offset" "-" "0" "empty partition, skipped"
        SKIPPED=$((SKIPPED+1))
        continue
    fi

    ts=$(read_timestamp_at "$part" "$probe_offset")
    if ! [[ "$ts" =~ ^[0-9]+$ ]]; then
        printf "%-9s %-15s %-15s %-15s %s\n" "$part" "$src_offset" "?" "-" "could not read source ts, skipped"
        SKIPPED=$((SKIPPED+1))
        continue
    fi

    # If we probed offset-1 (caught up), advance ts by 1ms so we resolve to the
    # next dest record after the last one consumed on source.
    if [ -n "$note" ]; then
        ts=$((ts + 1))
    fi

    dest_off=$(dest_offset_for_timestamp "$part" "$ts")
    if ! [[ "$dest_off" =~ ^-?[0-9]+$ ]] || [ "$dest_off" = "-1" ]; then
        # No dest record at-or-after ts: dest is behind or partition empty.
        # Conservative choice: set dest cursor to current LEO (latest) so we
        # consume only future records on dest.
        latest=$($CONTAINER_CMD exec "$DEST_CONTAINER" /opt/kafka/bin/kafka-get-offsets.sh \
            --bootstrap-server localhost:9092 \
            --topic-partitions "${TOPIC}:${part}" \
            --time -1 2>/dev/null | awk -F: '{print $NF; exit}')
        if ! [[ "$latest" =~ ^[0-9]+$ ]]; then latest=0; fi
        dest_off="$latest"
        note="${note:+$note; }no dest ts match, using latest"
    fi

    printf "%-9s %-15s %-15s %-15s %s\n" "$part" "$src_offset" "$ts" "$dest_off" "$note"
    echo "${TOPIC},${part},${dest_off}" >> "$PLAN"
    PLANNED=$((PLANNED+1))
done <<< "$ROWS"

echo
echo -e "${CYAN}Planned partitions: ${PLANNED}   Skipped: ${SKIPPED}${NC}"

if [ "$PLANNED" -eq 0 ]; then
    echo -e "${YELLOW}Nothing to apply.${NC}"
    exit 0
fi

if [ "$EXECUTE" -ne 1 ]; then
    echo -e "${YELLOW}Dry-run. Re-run with --execute to apply on ${DEST_CONTAINER}.${NC}"
    exit 0
fi

# Apply via --reset-offsets --from-file. Copy the CSV into the dest container
# so kafka-consumer-groups can read it from a path inside the container.
DEST_PATH="/tmp/offset-bridge.${GROUP}.csv"
$CONTAINER_CMD cp "$PLAN" "${DEST_CONTAINER}:${DEST_PATH}"

echo -e "${YELLOW}Applying reset on ${DEST_CONTAINER} for group '${GROUP}'...${NC}"
$CONTAINER_CMD exec "$DEST_CONTAINER" /opt/kafka/bin/kafka-consumer-groups.sh \
    --bootstrap-server localhost:9092 \
    --group "$GROUP" \
    --reset-offsets --from-file "$DEST_PATH" \
    --execute

echo -e "${GREEN}Done. Verify with:${NC}"
echo "  $CONTAINER_CMD exec $DEST_CONTAINER /opt/kafka/bin/kafka-consumer-groups.sh \\"
echo "      --bootstrap-server localhost:9092 --describe --group $GROUP"
