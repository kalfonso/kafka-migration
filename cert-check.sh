#!/usr/bin/env bash
#
# Print expiry of the demo TLS keystore and warn if it expires soon.
#
# Complements doctor.sh: doctor.sh checks structural drift between the
# cert SAN list, proxy YAML and docker-compose aliases. This script
# checks the temporal validity - the one drift doctor.sh cannot see.
#
# Exit codes:
#   0  cert valid for at least MIN_DAYS (default 30)
#   1  cert expires in less than MIN_DAYS (or already expired)
#   2  keystore missing or unreadable
#
# Usage:
#   ./cert-check.sh                # warn if < 30 days
#   MIN_DAYS=7 ./cert-check.sh     # warn if < 7 days
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYSTORE="${KEYSTORE:-$SCRIPT_DIR/certs/generated/keystore.p12}"
PASS="${KEYSTORE_PASS:-changeit}"
MIN_DAYS="${MIN_DAYS:-30}"
KEYTOOL="${KEYTOOL:-keytool}"

if [ ! -f "$KEYSTORE" ]; then
    echo "FAIL: keystore not found at $KEYSTORE"
    echo "      run certs/generate-certs.sh first"
    exit 2
fi

if ! command -v "$KEYTOOL" >/dev/null 2>&1; then
    echo "FAIL: keytool not on PATH"
    echo "      activate hermit: . bin/activate-hermit"
    exit 2
fi

# Extract "Valid from: <from> until: <until>" line. Format from keytool:
#   Valid from: Mon May 04 17:38:04 AEST 2026 until: Thu May 01 17:38:04 AEST 2036
LISTING="$("$KEYTOOL" -list -v -keystore "$KEYSTORE" -storepass "$PASS" 2>/dev/null)"

UNTIL_LINE="$(printf '%s\n' "$LISTING" | awk '/Valid from:/ { sub(/.*until: /, ""); print; exit }')"
if [ -z "$UNTIL_LINE" ]; then
    echo "FAIL: could not parse 'Valid from' line from keytool output"
    exit 2
fi

# Try GNU date first (Linux/CI), then BSD date (macOS).
to_epoch() {
    local s
    if s=$(date -d "$1" +%s 2>/dev/null); then printf '%s' "$s"; return 0; fi
    if s=$(date -j -f "%a %b %d %H:%M:%S %Z %Y" "$1" +%s 2>/dev/null); then printf '%s' "$s"; return 0; fi
    return 1
}

if ! UNTIL_EPOCH="$(to_epoch "$UNTIL_LINE")"; then
    echo "FAIL: could not parse expiry date: $UNTIL_LINE"
    exit 2
fi

NOW_EPOCH="$(date +%s)"
DAYS_LEFT=$(( (UNTIL_EPOCH - NOW_EPOCH) / 86400 ))

ALIAS="$(printf '%s\n' "$LISTING" | awk -F': ' '/^Alias name:/ { print $2; exit }')"

printf 'Keystore: %s\n' "$KEYSTORE"
printf 'Alias:    %s\n' "$ALIAS"
printf 'Expires:  %s\n' "$UNTIL_LINE"

if [ "$DAYS_LEFT" -lt 0 ]; then
    printf 'Status:   EXPIRED %d days ago\n' $((-DAYS_LEFT))
    echo "        regenerate with certs/generate-certs.sh"
    exit 1
fi

if [ "$DAYS_LEFT" -lt "$MIN_DAYS" ]; then
    printf 'Status:   WARN - expires in %d days (threshold %d)\n' "$DAYS_LEFT" "$MIN_DAYS"
    echo "        regenerate with certs/generate-certs.sh"
    exit 1
fi

printf 'Status:   OK - %d days remaining\n' "$DAYS_LEFT"
exit 0
