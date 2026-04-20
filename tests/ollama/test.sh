#!/usr/bin/env bash

set -euo pipefail

CHART="$(cd "$(dirname "$0")/../../charts/ollama" && pwd)"

echo "==> helm template (default values)"
helm template ollama-test "$CHART" >/dev/null

echo "==> helm template (GPU enabled)"
helm template ollama-test "$CHART" \
  --set gpu.enabled=true \
  --set gpu.nodeSelector."nvidia\.com/gpu"=present \
  >/dev/null

echo "==> helm template (imagePullSecrets)"
helm template ollama-test "$CHART" \
  --set "imagePullSecrets[0].name=regcred" \
  >/dev/null

echo "==> helm template (custom sqlAssistant port)"
helm template ollama-test "$CHART" \
  --set sqlAssistant.port=9090 \
  >/dev/null

echo "All ollama template tests passed."
