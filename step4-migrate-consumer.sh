#!/usr/bin/env bash
#
# Step 4: Migrate the consumer to the destination cluster.
#
# Recreates the consumer container pointing at the dest virtual cluster
# (consumer-proxy:9294) instead of source (consumer-proxy:9292).
#

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yaml"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}Migrating consumer: source (consumer-proxy:9292) -> dest (consumer-proxy:9294)${NC}"

CONSUMER_BOOTSTRAP=consumer-proxy:9294 \
  docker compose -f "$COMPOSE_FILE" up -d --force-recreate --no-deps consumer

echo ""
echo -e "${GREEN}Migration complete!${NC}"
echo "Both producer and consumer are now on the destination Kafka cluster."
echo ""
echo "Verify:   docker compose -f $COMPOSE_FILE logs -f consumer"
echo "Tear down: ./stop.sh"
