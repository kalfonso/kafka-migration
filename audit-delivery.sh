#!/usr/bin/env bash
#
# audit-delivery.sh - empirical loss/duplicate audit for the proxy-flip migration.
#
# DELIVERY-SEMANTICS.md claims the proxy-flip pattern is at-least-once with a
# duplicate window of producer_rate * drain_time records, and no loss.
# This script verifies both claims on a real run by reading every record from
# kafka-source and kafka-dest, parsing the demo producer's `msg-<N> <ts>` value,
# and computing:
#
#   - src range  [src_min .. src_max]
#   - dst range  [dst_min .. dst_max]
#   - overlap    = |src ∩ dst|   (the empirical duplicate window)
#   - gaps       = expected_count - distinct_seen   (loss)
#
# Exit codes:
#   0 = no gaps (no loss). Overlap is reported but not a failure.
#   1 = gaps detected (records lost) or stack not running.
#
# Run AFTER step5-verify.sh has succeeded AND after stopping the producer
# (e.g. `docker compose stop producer`). The script reads each cluster
# `--from-beginning` and relies on `--timeout-ms` to detect end-of-log; an
# active producer would prevent the consumer from ever idling.
#
# Reads use the plaintext listener on 9092 (inside-container), independently
# of the proxies - so the result reflects what was actually persisted, not
# what the proxy currently routes.
#

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

TOPIC="${TOPIC:-orders}"
CONTAINER_CMD="${CONTAINER_CMD:-docker}"
TIMEOUT_MS="${TIMEOUT_MS:-8000}"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
amber() { printf '\033[33m%s\033[0m\n' "$*"; }
cyan()  { printf '\033[36m%s\033[0m\n' "$*"; }

dump_cluster() {
    local cluster="$1"
    local out="$2"
    "$CONTAINER_CMD" exec "$cluster" /opt/kafka/bin/kafka-console-consumer.sh \
        --bootstrap-server localhost:9092 \
        --topic "$TOPIC" \
        --from-beginning \
        --timeout-ms "$TIMEOUT_MS" \
        --property print.key=true \
        --property key.separator=$'\t' \
        2>/dev/null > "$out" || true
}

extract_seqs() {
    awk -F'\t' '
        $1 != "" && $2 ~ /^msg-[0-9]+/ {
            v = $2
            sub(/^msg-/, "", v)
            sub(/ .*$/, "", v)
            print v + 0
        }
    ' "$1"
}

if ! "$CONTAINER_CMD" ps --format '{{.Names}}' 2>/dev/null | grep -qx kafka-source; then
    red "kafka-source container not running - start the stack with ./step1-start.sh"
    exit 1
fi
if ! "$CONTAINER_CMD" ps --format '{{.Names}}' 2>/dev/null | grep -qx kafka-dest; then
    red "kafka-dest container not running - start the stack with ./step1-start.sh"
    exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cyan "Draining kafka-source $TOPIC (timeout ${TIMEOUT_MS}ms) ..."
dump_cluster kafka-source "$TMP/src.tsv"
cyan "Draining kafka-dest   $TOPIC (timeout ${TIMEOUT_MS}ms) ..."
dump_cluster kafka-dest   "$TMP/dst.tsv"

extract_seqs "$TMP/src.tsv" | sort -u > "$TMP/src.seqs"
extract_seqs "$TMP/dst.tsv" | sort -u > "$TMP/dst.seqs"

SRC_COUNT=$(wc -l < "$TMP/src.tsv" | tr -d ' ')
DST_COUNT=$(wc -l < "$TMP/dst.tsv" | tr -d ' ')
SRC_DISTINCT=$(wc -l < "$TMP/src.seqs" | tr -d ' ')
DST_DISTINCT=$(wc -l < "$TMP/dst.seqs" | tr -d ' ')

if [ "$SRC_DISTINCT" -eq 0 ] && [ "$DST_DISTINCT" -eq 0 ]; then
    red "No parseable records on either cluster - nothing to audit."
    exit 1
fi

range() {
    local f="$1"
    if [ ! -s "$f" ]; then echo "-"; return; fi
    local mn mx
    mn=$(sort -n "$f" | head -n1)
    mx=$(sort -n "$f" | tail -n1)
    printf '%s..%s' "$mn" "$mx"
}
SRC_RANGE=$(range "$TMP/src.seqs")
DST_RANGE=$(range "$TMP/dst.seqs")

OVERLAP=$(comm -12 "$TMP/src.seqs" "$TMP/dst.seqs" | wc -l | tr -d ' ')

sort -u "$TMP/src.seqs" "$TMP/dst.seqs" > "$TMP/all.seqs"
ALL_DISTINCT=$(wc -l < "$TMP/all.seqs" | tr -d ' ')
if [ "$ALL_DISTINCT" -eq 0 ]; then
    GAPS=0
    EXPECTED=0
    ALL_MIN=0
    ALL_MAX=0
else
    ALL_MIN=$(sort -n "$TMP/all.seqs" | head -n1)
    ALL_MAX=$(sort -n "$TMP/all.seqs" | tail -n1)
    EXPECTED=$((ALL_MAX - ALL_MIN + 1))
    GAPS=$((EXPECTED - ALL_DISTINCT))
fi

echo
printf "  %-22s records=%-7s distinct=%-7s range=%s\n" "kafka-source" "$SRC_COUNT" "$SRC_DISTINCT" "$SRC_RANGE"
printf "  %-22s records=%-7s distinct=%-7s range=%s\n" "kafka-dest"   "$DST_COUNT" "$DST_DISTINCT" "$DST_RANGE"
echo
printf "  union expected=%s distinct=%s\n" "$EXPECTED" "$ALL_DISTINCT"
printf "  overlap (duplicate window) = %s\n" "$OVERLAP"
printf "  gaps    (lost records)     = %s\n" "$GAPS"
echo

if [ "$GAPS" -gt 0 ]; then
    red "FAIL: $GAPS sequence number(s) absent from both clusters - records were lost."
    if [ "$ALL_DISTINCT" -gt 0 ]; then
        comm -23 <(seq "$ALL_MIN" "$ALL_MAX" | sort) <(sort "$TMP/all.seqs") \
          | sort -n | head -n 20 \
          | awk 'BEGIN { printf "  missing seqs (first 20): " } { printf "%s ", $0 } END { print "" }'
    fi
    exit 1
fi

if [ "$OVERLAP" -gt 0 ]; then
    amber "PASS with overlap: $OVERLAP duplicate(s) - expected for at-least-once delivery."
    amber "  See DELIVERY-SEMANTICS.md for hardening strategies."
else
    green "PASS: no loss, no overlap. Producer was migrated cleanly between flushes."
fi
exit 0
