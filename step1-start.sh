#!/usr/bin/env bash
#
# Step 1: Start the migration demo.
#
# Brings up two Kafka clusters, two Kroxylicious sidecars, a producer (1 msg/sec)
# and a consumer — all in Docker.
#

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER_CMD="${CONTAINER_CMD:-docker}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║          Kafka Migration Demo — Kroxylicious Sidecar        ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
if [ ! -f "$SCRIPT_DIR/certs/generated/keystore.p12" ]; then
  echo -e "${YELLOW}Generating TLS certificates (one-off)...${NC}"
  KEYTOOL="${KEYTOOL:-$SCRIPT_DIR/bin/keytool}" "$SCRIPT_DIR/certs/generate-certs.sh"
  echo ""
fi

echo -e "${YELLOW}Starting all services (Kafka clusters, proxies, producer, consumer)...${NC}"
echo ""

"$CONTAINER_CMD" compose -f "$SCRIPT_DIR/docker-compose.yaml" up -d --build 2>&1

echo ""
echo -e "${GREEN}All services started.${NC}"
echo ""
echo -e "${CYAN}Watch consumer output:${NC}"
echo "  $CONTAINER_CMD compose -f $SCRIPT_DIR/docker-compose.yaml logs -f consumer"
echo ""
echo -e "${CYAN}Watch producer output:${NC}"
echo "  $CONTAINER_CMD compose -f $SCRIPT_DIR/docker-compose.yaml logs -f producer"
echo ""
echo -e "${CYAN}Next steps:${NC}"
echo "  ./step2-migrate-producer.sh    # migrate producer to dest cluster"
echo "  ./step3-check-lag.sh           # wait for consumer to drain source"
echo "  ./step4-migrate-consumer.sh    # migrate consumer to dest cluster"
echo "  ./step5-verify.sh              # verify the migration end-state"
echo "  ./stop.sh                      # tear everything down"
