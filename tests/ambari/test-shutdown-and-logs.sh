#!/usr/bin/env bash

# Render-only checks (no cluster needed) for how the Ambari pod stops and where its logs go: the grace
# period outlasts the server's own stop timeout, the logs volume and the logback.xml override are
# mounted only when asked for, and the pod declares the ephemeral storage its rotated logs fit in.

set -euo pipefail

CHART="$(cd "$(dirname "$0")/../../charts/ambari" && pwd)"
NAMESPACE=kdps
FAILED=0

COMMON=(--namespace "$NAMESPACE" --set database.host=postgres.example.svc --set database.password=changeme
        --set masterKey.value=a-master-key --set adminPassword.existingSecret=ambari-admin
        --set route.host=ambari.apps.example.com)

render() {
    helm template ambari "$CHART" "${COMMON[@]}" "$@"
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

expect_refused() {
    local label=$1 needle=$2
    shift 2
    local out
    if out=$(render "$@" 2>&1); then
        echo "FAIL - $label: rendered, expected it to be refused"
        FAILED=1
    elif grep -qF -- "$needle" <<<"$out"; then
        echo "ok   - $label"
    else
        echo "FAIL - $label: refused, but not with '$needle': $out"
        FAILED=1
    fi
}

# The value of one field of the rendered Deployment, read with a YAML parser rather than grep.
deployment_field() {
    python3 -c '
import sys, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin) if d and d.get("kind") == "Deployment"]
value = docs[0]
for key in sys.argv[1].split("."):
    value = value[int(key)] if isinstance(value, list) else value.get(key)
    if value is None:
        break
print(value)' "$1"
}

echo "==> defaults: the server gets 50 s to stop and the pod 90 s"
out=$(render)
expect_contains "terminationGracePeriodSeconds" "terminationGracePeriodSeconds: 90" "$out"
expect_contains "the stop timeout reaches the image" "name: AMBARI_STOP_TIMEOUT" "$out"
[ "$(deployment_field spec.template.spec.terminationGracePeriodSeconds <<<"$out")" = 90 ] \
    && echo "ok   - grace period on the pod spec" || { echo "FAIL - grace period on the pod spec"; FAILED=1; }
env_value=$(python3 -c '
import sys, yaml
d = [d for d in yaml.safe_load_all(sys.stdin) if d and d.get("kind") == "Deployment"][0]
env = d["spec"]["template"]["spec"]["containers"][0]["env"]
print(next((e["value"] for e in env if e["name"] == "AMBARI_STOP_TIMEOUT"), ""))' <<<"$out")
[ "$env_value" = 50 ] && echo "ok   - AMBARI_STOP_TIMEOUT=50" || { echo "FAIL - AMBARI_STOP_TIMEOUT=$env_value"; FAILED=1; }

echo "==> defaults: ephemeral storage is requested and limited"
expect_contains "request" "ephemeral-storage: 1Gi" "$out"
expect_contains "limit" "ephemeral-storage: 3Gi" "$out"

echo "==> defaults: the logs stay in the container, the rotation override is mounted"
expect_absent "no logs volume" "mountPath: /var/log/ambari-server" "$out"
expect_absent "no logs claim" "name: ambari-logs" "$out"
expect_contains "logback.xml mounted over the image's" "mountPath: /etc/ambari-server/conf/logback.xml" "$out"
expect_contains "from the chart's ConfigMap" "name: ambari-logging" "$out"
expect_contains "pod rolls when the logging config changes" "checksum/logging:" "$out"
logback=$(render --show-only templates/configmap-logging.yaml | python3 -c '
import sys, yaml, xml.dom.minidom
x = yaml.safe_load(sys.stdin)["data"]["logback.xml"]
xml.dom.minidom.parseString(x)
print(x)')
expect_contains "logback.xml is well-formed and keeps the audit logger apart" '<logger name="audit" level="INFO" additivity="false">' "$logback"
expect_contains "server log keeps 5 rotated files" '<fileNamePattern>${AMBARI_LOG_DIR}/ambari-server.log.%i</fileNamePattern>
      <minIndex>1</minIndex>
      <maxIndex>5</maxIndex>' "$logback"
expect_contains "audit log keeps 5 rotated files" '<fileNamePattern>${AMBARI_LOG_DIR}/ambari-audit.log.%i.gz</fileNamePattern>
      <minIndex>1</minIndex>
      <maxIndex>5</maxIndex>' "$logback"
expect_contains "the log directory is the image's" '<property name="AMBARI_LOG_DIR" value="${AMBARI_ROOT_DIR}/var/log/ambari-server" />' "$logback"

echo "==> rotation settings are applied"
logback=$(render --show-only templates/configmap-logging.yaml \
    --set logs.rotation.server.maxBackups=3 --set logs.rotation.audit.maxBackups=12 \
    --set logs.rotation.audit.maxFileSize=20MB)
expect_contains "server maxIndex" "<maxIndex>3</maxIndex>" "$logback"
expect_contains "audit maxIndex" "<maxIndex>12</maxIndex>" "$logback"
expect_contains "audit maxFileSize" "<maxFileSize>20MB</maxFileSize>" "$logback"

echo "==> logs.rotation.enabled=false keeps the image's logback.xml"
out=$(render --set logs.rotation.enabled=false)
expect_absent "no logback.xml mount" "mountPath: /etc/ambari-server/conf/logback.xml" "$out"
expect_absent "no ConfigMap" "name: ambari-logging" "$out"
expect_absent "no checksum" "checksum/logging:" "$out"

echo "==> logs.persistence with an emptyDir"
out=$(render --set logs.persistence.enabled=true)
expect_contains "logs volume mounted" "mountPath: /var/log/ambari-server" "$out"
expect_contains "as an emptyDir" "- name: logs
          emptyDir: {}" "$out"
expect_absent "no claim created" "name: ambari-logs" "$out"
out=$(render --set logs.persistence.enabled=true --set logs.persistence.sizeLimit=2Gi)
expect_contains "sizeLimit applied" 'sizeLimit: "2Gi"' "$out"

echo "==> logs.persistence with a claim the chart creates, kept by helm uninstall"
out=$(render --set logs.persistence.enabled=true --set logs.persistence.type=pvc \
    --set logs.persistence.size=8Gi --set logs.persistence.storageClass=fast)
expect_contains "logs volume mounted" "mountPath: /var/log/ambari-server" "$out"
expect_contains "claim referenced" "claimName: ambari-logs" "$out"
pvc=$(render --set logs.persistence.enabled=true --set logs.persistence.type=pvc \
    --set logs.persistence.size=8Gi --set logs.persistence.storageClass=fast --show-only templates/pvc-logs.yaml)
expect_contains "claim created" "name: ambari-logs" "$pvc"
expect_contains "claim kept" "helm.sh/resource-policy: keep" "$pvc"
expect_contains "claim size" 'storage: "8Gi"' "$pvc"
expect_contains "claim storage class" 'storageClassName: "fast"' "$pvc"

echo "==> logs.persistence with an existing claim"
out=$(render --set logs.persistence.enabled=true --set logs.persistence.type=pvc \
    --set logs.persistence.existingClaim=audit-logs)
expect_contains "existing claim referenced" "claimName: audit-logs" "$out"
expect_absent "no claim created" "name: ambari-logs" "$out"

echo "==> the combinations the chart must refuse"
expect_refused "grace period not longer than the stop timeout" "must be at least stopTimeoutSeconds" \
    --set terminationGracePeriodSeconds=50
expect_refused "grace period without room for the entrypoint" "must be at least stopTimeoutSeconds" \
    --set terminationGracePeriodSeconds=60 --set stopTimeoutSeconds=56
expect_refused "stop timeout of zero" "stopTimeoutSeconds must be at least 1" --set stopTimeoutSeconds=0
expect_refused "unknown logs volume type" "logs.persistence.type must be emptyDir or pvc" \
    --set logs.persistence.enabled=true --set logs.persistence.type=hostPath
expect_refused "no rotated files" "logs.rotation.server.maxBackups must be between 1 and 20" \
    --set logs.rotation.server.maxBackups=0
expect_refused "more rotated files than the server keeps" "logs.rotation.audit.maxBackups must be between 1 and 20" \
    --set logs.rotation.audit.maxBackups=60

echo "==> a longer stop timeout with a grace period to match"
out=$(render --set stopTimeoutSeconds=120 --set terminationGracePeriodSeconds=150)
expect_contains "grace period" "terminationGracePeriodSeconds: 150" "$out"
expect_contains "stop timeout" 'value: "120"' "$out"

if [ "$FAILED" -ne 0 ]; then
    echo "ambari template checks FAILED"
    exit 1
fi
echo "ambari template checks passed"
