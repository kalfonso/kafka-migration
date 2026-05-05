#!/usr/bin/env bash
#
# Rollback: re-point the producer or consumer back to the source virtual cluster.
#
# Mirror of step2 / step4. The proxy pattern's selling point is that migration
# is reversible: if the destination cluster misbehaves after a flip, switch the
# bootstrap back. Same TCP port, only the SNI hostname changes - Kroxylicious
# routes the new connections to the source virtual cluster.
#
# Usage:
#   ./rollback.sh producer   # re-point producer to source.producer-proxy:9192
#   ./rollback.sh consumer   # re-point consumer to source.consumer-proxy:9292
#
# Note on data:
# - Rolling back the producer leaves any messages written to dest stranded
#   on dest. Replay or accept loss is the operator's call.
# - Rolling back the consumer is only meaningful AFTER the producer has been
#   rolled back; otherwise no new messages arrive on source.
#

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yaml"
CONTAINER_CMD="${CONTAINER_CMD:-docker}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

usage() {
    echo "Usage: $0 <producer|consumer>"
    echo ""
    echo "  producer   re-point producer to source.producer-proxy:9192"
    echo "  consumer   re-point consumer to source.consumer-proxy:9292"
    exit 2
}

[ $# -eq 1 ] || usage

case "$1" in
    producer)
        WORKLOAD=producer
        ENV_VAR=PRODUCER_BOOTSTRAP
        TARGET=source.producer-proxy:9192
        ;;
    consumer)
        WORKLOAD=consumer
        ENV_VAR=CONSUMER_BOOTSTRAP
        TARGET=source.consumer-proxy:9292
        ;;
    *)
        usage
        ;;
esac

echo -e "${YELLOW}Rolling back ${WORKLOAD} -> ${TARGET}${NC}"

if [ "$WORKLOAD" = "consumer" ]; then
    PRODUCER_LANE=$($CONTAINER_CMD inspect -f \
        '{{range .Config.Env}}{{println .}}{{end}}' producer 2>/dev/null \
        | awk -F= '/^PRODUCER_BOOTSTRAP=/ { print $2 }' || true)
    if [ -n "$PRODUCER_LANE" ] && [[ "$PRODUCER_LANE" != source.* ]]; then
        echo -e "${RED}Warning:${NC} producer is on '${PRODUCER_LANE}', not source."
        echo "  Rolling back the consumer alone is a no-op once source stops receiving writes."
        echo "  Roll back the producer first: $0 producer"
        echo ""
    fi
fi

env "$ENV_VAR=$TARGET" \
    $CONTAINER_CMD compose -f "$COMPOSE_FILE" up -d --force-recreate --no-deps "$WORKLOAD"

echo ""
echo -e "${GREEN}${WORKLOAD} is now connected to ${TARGET}.${NC}"
