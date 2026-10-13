#!/usr/bin/env bash

# Render-only check (no cluster needed): with Ranger access control, the plugin reads the audit configuration that
# KDPS mounts (ranger-trino-audit.xml), so the Solr and HDFS audit destinations of the cluster are honoured instead of
# the plugin's defaults.

set -euo pipefail

CHART="$(cd "$(dirname "$0")/../../charts/trino" && pwd)"
FAILED=0

render() {
    helm template trino-test "$CHART" --namespace analytics --set server.workers=1 \
        --set accessControl.type=ranger --set ranger.serviceName=trino-analytics \
        --set ranger.securityConfigMapName=trino-test-ranger-trino-security \
        --set ranger.auditConfigMapName=trino-test-ranger-trino-audit \
        --set ranger.policymgrSslConfigMapName=trino-test-ranger-policymgr-ssl "$@"
}

check() {
    local label=$1; shift
    local line
    line=$(render "$@" | grep -F "ranger.plugin.config.resource=" || true)
    if [[ "$line" == *"/etc/trino/ranger/ranger-trino-audit.xml"* ]]; then
        echo "ok   - $label"
    else
        echo "FAIL - $label: ranger.plugin.config.resource does not list the audit file: '$line'"
        FAILED=1
    fi
}

check "the plugin reads the audit file" --set ranger.admin.ssl.enabled=false
check "the plugin reads the audit file with Ranger Admin over TLS" --set ranger.admin.ssl.enabled=true

exit $FAILED
