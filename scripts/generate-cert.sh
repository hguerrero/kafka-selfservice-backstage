#!/usr/bin/env bash
# Fallback (no cert-manager): create the wildcard TLS secret the listener expects.
set -euo pipefail

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout "$TMP/tls.key" -out "$TMP/tls.crt" \
  -subj "/CN=127-0-0-1.sslip.io" \
  -addext "subjectAltName=DNS:*.127-0-0-1.sslip.io"

kubectl create secret tls keg-tls-secret \
  --cert="$TMP/tls.crt" --key="$TMP/tls.key" -n kong \
  --dry-run=client -o yaml | kubectl apply -f -

# Save the cert so clients can trust it (see examples/kafka-client).
cp "$TMP/tls.crt" examples/kafka-client/ca.crt
echo "Wrote secret keg-tls-secret and examples/kafka-client/ca.crt"
