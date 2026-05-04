#!/usr/bin/env bash
#
# Generate a self-signed TLS certificate covering all SNI hostnames used by
# the producer-proxy and consumer-proxy virtual clusters.
#
# Output (under certs/generated/):
#   keystore.p12    PKCS12 keystore for Kroxylicious (server side)
#   truststore.p12  PKCS12 truststore for Java clients
#   cert.crt        PEM public certificate
#
# All stores use password 'changeit'. This is demo material - do not reuse.
#

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$SCRIPT_DIR/generated"
PASS="changeit"

mkdir -p "$OUT"
rm -f "$OUT/keystore.p12" "$OUT/truststore.p12" "$OUT/cert.crt"

KEYTOOL="${KEYTOOL:-keytool}"

SANS="dns:source.producer-proxy,dns:broker-1.source.producer-proxy"
SANS="$SANS,dns:dest.producer-proxy,dns:broker-1.dest.producer-proxy"
SANS="$SANS,dns:source.consumer-proxy,dns:broker-1.source.consumer-proxy"
SANS="$SANS,dns:dest.consumer-proxy,dns:broker-1.dest.consumer-proxy"

"$KEYTOOL" -genkeypair \
    -alias kroxylicious \
    -keyalg RSA -keysize 2048 -validity 3650 \
    -storetype PKCS12 \
    -keystore "$OUT/keystore.p12" \
    -storepass "$PASS" -keypass "$PASS" \
    -dname "CN=kroxylicious-demo, O=demo" \
    -ext "SAN=$SANS"

"$KEYTOOL" -exportcert \
    -alias kroxylicious \
    -keystore "$OUT/keystore.p12" \
    -storetype PKCS12 -storepass "$PASS" \
    -rfc -file "$OUT/cert.crt"

"$KEYTOOL" -importcert -noprompt \
    -alias kroxylicious \
    -file "$OUT/cert.crt" \
    -keystore "$OUT/truststore.p12" \
    -storetype PKCS12 -storepass "$PASS"

chmod 644 "$OUT"/*.p12 "$OUT"/*.crt
echo "Generated TLS material in $OUT"
