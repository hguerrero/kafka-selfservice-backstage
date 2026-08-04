#!/usr/bin/env bash
# Local mirror of the CI checks: lint YAML, validate manifests and AsyncAPI specs.
set -euo pipefail

echo "==> yamllint (platform, catalog)"
yamllint -d relaxed platform catalog 2>/dev/null || \
  echo "   (install yamllint: pip install yamllint)"

echo "==> kubeconform (platform manifests)"
if command -v kubeconform >/dev/null 2>&1; then
  kubeconform -ignore-missing-schemas -summary platform
else
  echo "   (install kubeconform: https://github.com/yannh/kubeconform)"
fi

echo "==> AsyncAPI validate"
if command -v asyncapi >/dev/null 2>&1; then
  for f in catalog/specs/*.asyncapi.yaml; do asyncapi validate "$f"; done
else
  echo "   (install: npm i -g @asyncapi/cli)"
fi
