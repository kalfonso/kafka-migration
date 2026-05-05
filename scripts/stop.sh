#!/usr/bin/env bash
#
# Tear down the migration demo.
#

set -euo pipefail
CONTAINER_CMD="${CONTAINER_CMD:-docker}"

echo "Stopping demo..."
"$CONTAINER_CMD" compose -f "docker-compose.yaml" down -v 2>/dev/null || true
echo "Done."
