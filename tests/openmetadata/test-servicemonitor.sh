#!/usr/bin/env bash

# Render-only checks (no cluster needed) for the OpenMetadata ServiceMonitor: it is always created in the release
# namespace, and carries the kube-prometheus-stack 'release' label only when one is given.

set -euo pipefail

CHART="$(cd "$(dirname "$0")/../../charts/openmetadata" && pwd)"
NAMESPACE=project-a
FAILED=0

render() {
    helm template om-test "$CHART" --namespace "$NAMESPACE" --show-only templates/servicemonitor.yaml \
        --set serviceMonitor.enabled=true "$@"
}

expect_contains() {
    local label=$1 needle=$2 text=$3
    if grep -qF -- "$needle" <<<"$text"; then
        echo "ok   - $label"
    else
        echo "FAIL - $label: expected '$needle'"
        FAILED=1
    fi
}

expect_absent() {
    local label=$1 needle=$2 text=$3
    if grep -qF -- "$needle" <<<"$text"; then
        echo "FAIL - $label: did not expect '$needle'"
        FAILED=1
    else
        echo "ok   - $label"
    fi
}

expect_count() {
    local label=$1 needle=$2 expected=$3 text=$4
    local actual
    actual=$(grep -cF -- "$needle" <<<"$text" || true)
    if [ "$actual" = "$expected" ]; then
        echo "ok   - $label"
    else
        echo "FAIL - $label: expected $expected x '$needle', found $actual"
        FAILED=1
    fi
}

echo "==> OpenShift values (no release label, no monitoring block): release namespace, no 'release' label"
out=$(render --api-versions route.openshift.io/v1)
expect_contains "namespace is the release namespace" "  namespace: $NAMESPACE" "$out"
expect_absent "no 'release' label" "release:" "$out"
expect_contains "scrapes the release namespace" "- $NAMESPACE" "$out"

echo "==> values written by an older wizard still name a 'monitoring' namespace: ignored"
out=$(render --api-versions route.openshift.io/v1 \
    --set serviceMonitor.namespace=monitoring --set monitoring.namespace=monitoring)
expect_contains "namespace is still the release namespace" "  namespace: $NAMESPACE" "$out"
expect_absent "no 'monitoring' namespace" "namespace: monitoring" "$out"

echo "==> no 'monitoring' block at all: renders without a 'release' label"
out=$(render --set monitoring=null)
expect_contains "renders" "kind: ServiceMonitor" "$out"
expect_absent "no 'release' label" "release:" "$out"

echo "==> vanilla Kubernetes values: the kube-prometheus-stack 'release' label is kept, once"
out=$(render --set serviceMonitor.labels.release=kube-prometheus-stack)
expect_contains "release label" 'release: "kube-prometheus-stack"' "$out"
expect_count "a single 'release' label" "release:" 1 "$out"
expect_contains "namespace is the release namespace" "  namespace: $NAMESPACE" "$out"

echo "==> labels found by Prometheus discovery are kept next to the 'release' label"
out=$(render --set serviceMonitor.labels.release=obs --set serviceMonitor.labels.team=data)
expect_contains "release label" 'release: "obs"' "$out"
expect_contains "discovered label" "team: data" "$out"
expect_count "a single 'release' label" "release:" 1 "$out"

echo "==> release name only in the older monitoring.release"
out=$(render --set monitoring.release=kps)
expect_contains "release label from monitoring.release" 'release: "kps"' "$out"
out=$(render --set monitoring.release=kps --set serviceMonitor.labels.release=obs)
expect_contains "serviceMonitor.labels.release wins" 'release: "obs"' "$out"
expect_count "a single 'release' label" "release:" 1 "$out"

echo "==> serviceMonitor.enabled=false (chart default): no ServiceMonitor"
out=$(helm template om-test "$CHART" --namespace "$NAMESPACE")
expect_absent "no ServiceMonitor" "kind: ServiceMonitor" "$out"

if [ "$FAILED" -ne 0 ]; then
    echo "Some openmetadata ServiceMonitor template tests failed."
    exit 1
fi
echo "All openmetadata ServiceMonitor template tests passed."
