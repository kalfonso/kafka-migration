#!/usr/bin/env bash
#
# topic-parity.sh - verify source and dest clusters expose the same topics
# with the same partition count, replication factor, and key topic-level
# configs.
#
# Why: the demo's cutover sequence (step2 -> step3 -> step4) assumes the
# producer can keep writing the same keys to the same partitions on the
# dest cluster after cutover. If dest has a different partition count, the
# key->partition mapping changes and per-key ordering breaks across the
# cutover. Replication factor or retention drift quietly changes durability
# and data lifetime guarantees. This script is the runtime parity check
# that doctor.sh's static config check cannot do.
#
# Run any time after step1-start.sh. Exits non-zero on any drift.
#
# Usage:
#   ./topic-parity.sh                  # check every non-internal topic
#   ./topic-parity.sh orders payments  # check the named topics only
#

set -euo pipefail

CONTAINER_CMD="${CONTAINER_CMD:-docker}"
SOURCE="${SOURCE_CONTAINER:-kafka-source}"
DEST="${DEST_CONTAINER:-kafka-dest}"

# Topic-level configs that materially affect a migration. Differences here
# mean source and dest behave differently for the same producer/consumer
# code, even when partition count and replication factor agree.
CONFIG_KEYS=(
  cleanup.policy
  retention.ms
  retention.bytes
  compression.type
  max.message.bytes
  min.insync.replicas
  segment.ms
  segment.bytes
)

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

drift_count=0
checked_count=0

# Run kafka-topics.sh / kafka-configs.sh inside the broker container.
broker_exec() {
  local container="$1"
  shift
  "$CONTAINER_CMD" exec "$container" /opt/kafka/bin/"$@"
}

list_user_topics() {
  local container="$1"
  broker_exec "$container" kafka-topics.sh \
    --bootstrap-server localhost:9092 --list 2>/dev/null \
    | grep -Ev '^(__|$)' \
    | sort
}

describe_topic() {
  local container="$1" topic="$2"
  broker_exec "$container" kafka-topics.sh \
    --bootstrap-server localhost:9092 \
    --describe --topic "$topic" 2>/dev/null
}

# Extract "PartitionCount: N" and "ReplicationFactor: N" from the
# kafka-topics --describe header. Format is stable across the 3.x/4.x
# images this repo uses.
parse_topic_field() {
  local describe_output="$1" field="$2"
  echo "$describe_output" | head -1 \
    | awk -v f="$field" '{
        for (i = 1; i <= NF; i++) {
          if ($i == f":") { print $(i+1); exit }
        }
      }'
}

describe_configs() {
  local container="$1" topic="$2"
  broker_exec "$container" kafka-configs.sh \
    --bootstrap-server localhost:9092 \
    --describe --entity-type topics --entity-name "$topic" 2>/dev/null
}

# kafka-configs --describe prints lines like:
#   cleanup.policy=delete sensitive=false synonyms={...}
# We take field 1 only (key=value) - synonyms encode *which* layer the
# value came from and would cause false drift between two clusters that
# resolve the same effective value via different defaults.
config_value() {
  local configs_output="$1" key="$2"
  echo "$configs_output" \
    | awk -v k="$key" '
        $1 ~ "^"k"=" { sub("^"k"=", "", $1); print $1; exit }
      '
}

compare_topic() {
  local topic="$1"
  checked_count=$((checked_count + 1))

  local src_desc dst_desc
  if ! src_desc=$(describe_topic "$SOURCE" "$topic"); then
    echo -e "  ${RED}[FAIL]${NC} cannot describe '$topic' on source"
    drift_count=$((drift_count + 1))
    return
  fi
  if ! dst_desc=$(describe_topic "$DEST" "$topic"); then
    echo -e "  ${RED}[FAIL]${NC} '$topic' missing on dest"
    drift_count=$((drift_count + 1))
    return
  fi

  local local_drift=0
  local src_partitions dst_partitions src_rf dst_rf
  src_partitions=$(parse_topic_field "$src_desc" PartitionCount)
  dst_partitions=$(parse_topic_field "$dst_desc" PartitionCount)
  src_rf=$(parse_topic_field "$src_desc" ReplicationFactor)
  dst_rf=$(parse_topic_field "$dst_desc" ReplicationFactor)

  echo -e "  ${CYAN}$topic${NC}"

  if [ "$src_partitions" != "$dst_partitions" ]; then
    echo -e "    ${RED}partition-count drift${NC}: source=$src_partitions dest=$dst_partitions"
    local_drift=1
  else
    echo "    partitions=$src_partitions"
  fi

  if [ "$src_rf" != "$dst_rf" ]; then
    echo -e "    ${RED}replication-factor drift${NC}: source=$src_rf dest=$dst_rf"
    local_drift=1
  else
    echo "    replication-factor=$src_rf"
  fi

  local src_cfg dst_cfg
  src_cfg=$(describe_configs "$SOURCE" "$topic" || true)
  dst_cfg=$(describe_configs "$DEST" "$topic" || true)

  for key in "${CONFIG_KEYS[@]}"; do
    local sv dv
    sv=$(config_value "$src_cfg" "$key")
    dv=$(config_value "$dst_cfg" "$key")
    # If neither cluster has the key explicitly set, it's broker default
    # on both sides - report nothing rather than spam the output.
    if [ -z "$sv" ] && [ -z "$dv" ]; then
      continue
    fi
    if [ "$sv" != "$dv" ]; then
      echo -e "    ${RED}$key drift${NC}: source='${sv:-<default>}' dest='${dv:-<default>}'"
      local_drift=1
    else
      echo "    $key=$sv"
    fi
  done

  if [ "$local_drift" -ne 0 ]; then
    drift_count=$((drift_count + 1))
  fi
}

echo -e "${YELLOW}Checking topic parity: ${SOURCE} vs ${DEST}${NC}"
echo ""

if [ $# -gt 0 ]; then
  topics=("$@")
else
  mapfile -t topics < <(list_user_topics "$SOURCE")
  if [ "${#topics[@]}" -eq 0 ]; then
    echo -e "${YELLOW}No user topics on source. Nothing to check.${NC}"
    exit 0
  fi
fi

for t in "${topics[@]}"; do
  compare_topic "$t"
done

echo ""
if [ "$drift_count" -eq 0 ]; then
  echo -e "${GREEN}OK: $checked_count topic(s) match between source and dest.${NC}"
  exit 0
fi
echo -e "${RED}DRIFT: $drift_count of $checked_count topic(s) differ between source and dest.${NC}"
echo -e "${YELLOW}Producer cutover (step2) will silently change partition mapping or${NC}"
echo -e "${YELLOW}durability behaviour. Reconcile dest before proceeding.${NC}"
exit 1
