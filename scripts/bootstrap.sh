#!/usr/bin/env bash
# Bootstrap the platform on a local cluster (minikube). Idempotent-ish; re-run safely.
# This is the "first time, deliver everything" path.
set -euo pipefail

: "${KONNECT_PAT:?Set KONNECT_PAT to your Konnect Personal Access Token}"

echo "==> Namespaces"
kubectl create namespace kong  --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace kafka --dry-run=client -o yaml | kubectl apply -f -

echo "==> Strimzi (Kafka operator)"
kubectl create -f 'https://strimzi.io/install/latest?namespace=kafka' -n kafka 2>/dev/null || \
  kubectl apply  -f 'https://strimzi.io/install/latest?namespace=kafka' -n kafka

echo "==> Kong Operator (install per docs if not already present)"
echo "    https://developer.konghq.com/operator/  (helm install kong/kong-operator)"

echo "==> Konnect auth secret"
kubectl create secret generic konnect-api-auth-secret \
  --from-literal=token="$KONNECT_PAT" -n kong \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> TLS cert for the Event Gateway listener"
if kubectl get crd certificates.cert-manager.io >/dev/null 2>&1; then
  echo "    cert-manager present; certificate is applied via platform/networking/tls-certificate.yaml"
else
  echo "    cert-manager not found; generating a self-signed secret directly"
  ./scripts/generate-cert.sh
fi

echo "==> Apply the platform"
kubectl apply -k platform/

echo "==> Waiting for Kafka to be ready"
kubectl wait kafka/northwind --for=condition=Ready --timeout=300s -n kafka || true

echo
echo "Platform up. Next:"
echo "  1) In the kafka-selfservice-gitops repo: apply argocd/*.yaml (edit repoURLs first), OR"
echo "     apply the example tenant directly: kubectl apply -k ../kafka-selfservice-gitops/apps/fraud-analytics/kong/"
echo "  2) minikube tunnel   (so *.127-0-0-1.sslip.io resolves to the Gateway)"
echo "  3) Test with examples/kafka-client/"
