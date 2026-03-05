#!/usr/bin/env bash
#
# Step 2: Migrate the producer to the destination cluster.
#
# Recreates the producer container pointing at the dest virtual cluster
# (producer-proxy:9194) instead of source (producer-proxy:9192).
#

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yaml"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}Migrating producer: source (producer-proxy:9192) -> dest (producer-proxy:9194)${NC}"

PRODUCER_BOOTSTRAP=producer-proxy:9194 \
  docker compose -f "$COMPOSE_FILE" up -d --force-recreate --no-deps producer

echo ""
echo -e "${GREEN}Producer is now writing to the dest Kafka cluster.${NC}"
echo "The consumer is still reading from the source cluster."
echo ""
echo "Next: ./step3-check-lag.sh   # wait for consumer to drain source topic"
