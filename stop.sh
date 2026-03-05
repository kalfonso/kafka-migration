#!/usr/bin/env bash
#
# Tear down the migration demo.
#

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Stopping demo..."
docker compose -f "$SCRIPT_DIR/docker-compose.yaml" down -v 2>/dev/null || true
echo "Done."
