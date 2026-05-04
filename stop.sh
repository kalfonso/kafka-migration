#!/usr/bin/env bash
#
# Tear down the migration demo.
#

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER_CMD="${CONTAINER_CMD:-docker}"

echo "Stopping demo..."
"$CONTAINER_CMD" compose -f "$SCRIPT_DIR/docker-compose.yaml" down -v 2>/dev/null || true
echo "Done."
