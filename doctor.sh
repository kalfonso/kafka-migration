#!/usr/bin/env bash
#
# doctor.sh - diagnose the load-bearing pieces of the TLS + SNI demo.
#
# Codifies TROUBLESHOOTING.md sections 1-3 and 7 as a single static check
# that does not require the stack to be running. Run it after editing
# certs/generate-certs.sh, the proxy YAMLs, or docker-compose.yaml.
#
# Exit code: 0 = all checks passed, 1 = one or more issues found.
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
amber() { printf '\033[33m%s\033[0m\n' "$*"; }

ISSUES=0
fail() { red   "[FAIL] $*"; ISSUES=$((ISSUES + 1)); }
ok()   { green "[ OK ] $*"; }
warn() { amber "[WARN] $*"; }
section() { printf '\n==> %s\n' "$*"; }

CERT_DIR="$SCRIPT_DIR/certs/generated"
KEYSTORE="$CERT_DIR/keystore.p12"
TRUSTSTORE="$CERT_DIR/truststore.p12"
PASS="changeit"

# --- helpers ---------------------------------------------------------------

# Extract host:port pairs from `bootstrapAddress:` and
# `advertisedBrokerAddressPattern:` lines, with $(nodeId) substituted to 1.
yaml_hostnames() {
    local file="$1"
    awk '
        /bootstrapAddress:|advertisedBrokerAddressPattern:/ {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /:[0-9]+$/) {
                    gsub(/\$\(nodeId\)/, "1", $i)
                    print $i
                }
            }
        }
    ' "$file"
}

compose_aliases() {
    # Emit one alias per line for both proxy services.
    awk '
        /^  [a-zA-Z0-9_-]+:/ { svc = $1; sub(/:$/, "", svc) }
        /aliases:/ { in_aliases = 1; next }
        in_aliases && /^[[:space:]]+- / { sub(/^[[:space:]]+- /, ""); print svc "/" $0; next }
        in_aliases && !/^[[:space:]]+- / { in_aliases = 0 }
    ' docker-compose.yaml
}

# --- 0. Tooling ------------------------------------------------------------

section "Tooling"
for bin in keytool awk grep; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        fail "$bin not found on PATH"
    fi
done
[ "$ISSUES" -eq 0 ] && ok "keytool, awk, grep available"

# --- 1. Cert material ------------------------------------------------------

section "TLS material"
if [ ! -f "$KEYSTORE" ] || [ ! -f "$TRUSTSTORE" ]; then
    fail "keystore.p12 / truststore.p12 missing - run ./certs/generate-certs.sh"
    KEY_FP=""
    TRUST_FP=""
else
    KEY_FP=$(keytool -list -v -keystore "$KEYSTORE" -storetype PKCS12 -storepass "$PASS" 2>/dev/null \
             | awk -F': ' '/SHA256:|SHA-256:/ { print $2; exit }')
    TRUST_FP=$(keytool -list -v -keystore "$TRUSTSTORE" -storetype PKCS12 -storepass "$PASS" 2>/dev/null \
               | awk -F': ' '/SHA256:|SHA-256:/ { print $2; exit }')
    if [ -z "$KEY_FP" ] || [ -z "$TRUST_FP" ]; then
        fail "could not extract SHA-256 fingerprint from one of the stores"
    elif [ "$KEY_FP" != "$TRUST_FP" ]; then
        fail "keystore / truststore fingerprint mismatch (TROUBLESHOOTING.md #1)"
        echo "      keystore:   $KEY_FP"
        echo "      truststore: $TRUST_FP"
    else
        ok "keystore and truststore share the same cert"
    fi
fi

# --- 2. SAN coverage -------------------------------------------------------

section "SAN coverage vs proxy YAML hostnames"
SAN_LIST=""
if [ -f "$KEYSTORE" ]; then
    SAN_LIST=$(keytool -list -v -keystore "$KEYSTORE" -storetype PKCS12 -storepass "$PASS" 2>/dev/null \
               | awk '
                   /SubjectAlternativeName/ { in_san = 1; next }
                   in_san && /DNSName:/ {
                       for (i = 1; i <= NF; i++) if ($i == "DNSName:") print $(i + 1)
                   }
                   in_san && /^[[:space:]]*$/ { in_san = 0 }
               ')
fi

YAML_HOSTS=$( { yaml_hostnames producer-proxy-config.yaml; \
                yaml_hostnames consumer-proxy-config.yaml; } | sort -u )

if [ -z "$YAML_HOSTS" ]; then
    fail "no hostnames extracted from proxy YAMLs - parsing broken?"
fi

while IFS= read -r hostport; do
    [ -z "$hostport" ] && continue
    host="${hostport%:*}"
    if printf '%s\n' "$SAN_LIST" | grep -qx "$host"; then
        ok "SAN covers $host"
    else
        fail "SAN missing $host (TROUBLESHOOTING.md #2)"
    fi
done <<< "$YAML_HOSTS"

# --- 3. docker-compose alias coverage --------------------------------------

section "docker-compose aliases vs advertised broker hostnames"
ALIASES=$(compose_aliases | sort -u)

# We only care about the advertisedBrokerAddressPattern hosts here - those
# are the second-hop addresses the client tries to reach (TROUBLESHOOTING.md #3).
ADVERTISED_HOSTS=$(awk '
    /advertisedBrokerAddressPattern:/ {
        for (i = 1; i <= NF; i++) if ($i ~ /:[0-9]+$/) {
            gsub(/\$\(nodeId\)/, "1", $i); split($i, a, ":"); print a[1]
        }
    }
' producer-proxy-config.yaml consumer-proxy-config.yaml | sort -u)

while IFS= read -r host; do
    [ -z "$host" ] && continue
    if printf '%s\n' "$ALIASES" | grep -q "/$host\$"; then
        ok "docker alias resolves $host"
    else
        fail "no docker-compose alias for $host (TROUBLESHOOTING.md #3)"
    fi
done <<< "$ADVERTISED_HOSTS"

# --- 4. Container runtime sanity (advisory) --------------------------------

section "Container runtime"
CONTAINER_CMD="${CONTAINER_CMD:-docker}"
if command -v "$CONTAINER_CMD" >/dev/null 2>&1; then
    REAL=$("$CONTAINER_CMD" --version 2>/dev/null | awk '{print tolower($1)}')
    if [ "$REAL" = "podman" ] && [ "$CONTAINER_CMD" = "docker" ]; then
        warn "'docker' resolves to podman (TROUBLESHOOTING.md #7)"
    else
        ok "$CONTAINER_CMD: $REAL"
    fi
else
    warn "$CONTAINER_CMD not on PATH - skipping runtime checks"
fi

# --- summary ---------------------------------------------------------------

echo
if [ "$ISSUES" -eq 0 ]; then
    green "All checks passed."
    exit 0
else
    red "$ISSUES issue(s) found - see TROUBLESHOOTING.md for fixes."
    exit 1
fi
