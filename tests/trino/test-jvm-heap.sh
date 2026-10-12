#!/usr/bin/env bash

# Render-only checks (no cluster needed) for the Java heap options in jvm.config and for the resources
# of the chart's own init containers.

set -euo pipefail

CHART="$(cd "$(dirname "$0")/../../charts/trino" && pwd)"
FAILED=0

render() {
    local template=$1
    shift
    helm template trino-test "$CHART" --show-only "templates/$template" "$@"
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

echo "==> memory limit set: the heap is a share of the limit, no fixed -Xmx"
for role in coordinator worker; do
    out=$(render "configmap-$role.yaml" --set "$role.resources.limits.memory=8Gi")
    expect_contains "$role MaxRAMPercentage" "-XX:MaxRAMPercentage=75" "$out"
    expect_contains "$role InitialRAMPercentage" "-XX:InitialRAMPercentage=75" "$out"
    expect_absent "$role no -Xmx" "-Xmx" "$out"
done

echo "==> empty resources or limits (e.g. 'limits:' left blank in the YAML editor): renders, fixed 8G heap"
for role in coordinator worker; do
    out=$(render "configmap-$role.yaml" --set "$role.resources.limits=null")
    expect_contains "$role null limits -Xmx8G" "-Xmx8G" "$out"
    out=$(render "configmap-$role.yaml" --set "$role.resources=null")
    expect_contains "$role null resources -Xmx8G" "-Xmx8G" "$out"
done

echo "==> no memory limit (chart defaults, or requests only): the fixed 8G heap of earlier versions"
for role in coordinator worker; do
    out=$(render "configmap-$role.yaml")
    expect_contains "$role defaults -Xmx8G" "-Xmx8G" "$out"
    expect_absent "$role defaults no percentage of the node memory" "RAMPercentage" "$out"
    out=$(render "configmap-$role.yaml" --set "$role.resources.requests.memory=8Gi")
    expect_contains "$role request only -Xmx8G" "-Xmx8G" "$out"
    expect_absent "$role request only no percentage of the node memory" "RAMPercentage" "$out"
done
# Each role follows its own limit: a coordinator limit does not size the workers' heap from the node memory.
out=$(render configmap-worker.yaml --set coordinator.resources.limits.memory=8Gi)
expect_contains "worker without its own limit -Xmx8G" "-Xmx8G" "$out"

echo "==> explicit heap: a fixed -Xmx and no percentage, with or without a limit"
out=$(render configmap-coordinator.yaml --set coordinator.jvm.maxHeapSize=6G --set coordinator.resources.limits.memory=8Gi)
expect_contains "coordinator -Xmx6G" "-Xmx6G" "$out"
expect_absent "coordinator no MaxRAMPercentage" "RAMPercentage" "$out"
out=$(render configmap-worker.yaml --set worker.jvm.maxHeapSize=5G)
expect_contains "worker -Xmx5G" "-Xmx5G" "$out"
expect_absent "worker no MaxRAMPercentage" "RAMPercentage" "$out"
expect_absent "worker no default -Xmx8G" "-Xmx8G" "$out"

echo "==> custom percentages: the initial heap follows the maximum unless set"
out=$(render configmap-worker.yaml --set worker.jvm.maxRAMPercentage=70 --set worker.resources.limits.memory=4Gi)
expect_contains "worker MaxRAMPercentage=70" "-XX:MaxRAMPercentage=70" "$out"
expect_contains "worker InitialRAMPercentage=70" "-XX:InitialRAMPercentage=70" "$out"
out=$(render configmap-coordinator.yaml --set coordinator.jvm.initialRAMPercentage=25 --set coordinator.resources.limits.memory=4Gi)
expect_contains "coordinator MaxRAMPercentage=75" "-XX:MaxRAMPercentage=75" "$out"
expect_contains "coordinator InitialRAMPercentage=25" "-XX:InitialRAMPercentage=25" "$out"

echo "==> init container resources"
INIT_ARGS=(
    --set accessControl.type=ranger
    --set ranger.serviceName=trino-test
    --set ranger.admin.ssl.enabled=false
    --set dynamicCatalogs.enabled=true
    --set server.workers=1
    --set server.config.https.enabled=true
    --set server.config.https.keystore.secretName=trino-https
    --set server.config.https.keystore.passwordSecretName=trino-https-pass
    --set hadoopConf.enabled=true
    --set hadoopConf.groupMapping.enabled=true
    --set hadoopConf.groupMapping.ldap.url=ldaps://ldap.example.com
    --set hadoopConf.groupMapping.ldap.bindUser=cn=bind
    --set hadoopConf.groupMapping.ldap.baseDn=dc=example
)
RESOURCE_ARGS=(
    --set initContainerResources.requests.cpu=111m
    --set initContainerResources.requests.memory=128Mi
    --set initContainerResources.limits.cpu=111m
    --set initContainerResources.limits.memory=128Mi
)
# coordinator: catalog store, Ranger directories, Hadoop overlay, HTTPS keystore (requests + limits each)
out=$(render deployment-coordinator.yaml "${INIT_ARGS[@]}" "${RESOURCE_ARGS[@]}")
expect_count "coordinator init containers carry the resources" "cpu: 111m" 8 "$out"
# worker: Hadoop overlay, HTTPS keystore
out=$(render deployment-worker.yaml "${INIT_ARGS[@]}" "${RESOURCE_ARGS[@]}")
expect_count "worker init containers carry the resources" "cpu: 111m" 4 "$out"
out=$(render deployment-coordinator.yaml "${INIT_ARGS[@]}")
expect_count "unset: the Hadoop overlay keeps its own resources" "cpu: 10m" 1 "$out"
expect_absent "unset: no init container resources" "cpu: 111m" "$out"

if [ "$FAILED" -ne 0 ]; then
    echo "Some trino jvm/heap template tests failed."
    exit 1
fi
echo "All trino jvm/heap template tests passed."
