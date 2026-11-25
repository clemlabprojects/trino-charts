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

# Kerberos login of the audit writers: a JAAS file and the JVM option that names it, only when KDPS gives the
# principal and the keytab (JDK 24+: the Solr client's threads have no Kerberos identity of their own).
KRB=(--set ranger.admin.ssl.enabled=false --set ranger.audit.kerberos.principal=trino-analytics@EXAMPLE.COM
     --set ranger.audit.kerberos.keytab=/etc/security/keytabs/service.keytab)
out=$(render "${KRB[@]}")
if grep -qF -- "-Djava.security.auth.login.config=/etc/trino/ranger-audit-jaas.conf" <<<"$out" \
    && grep -qF "com.sun.security.jgss.krb5.initiate {" <<<"$out" && grep -qF "Client {" <<<"$out" \
    && [[ $(grep -cF 'principal="trino-analytics@EXAMPLE.COM";' <<<"$out") -eq 2 ]] \
    && [[ $(grep -cF 'keyTab="/etc/security/keytabs/service.keytab"' <<<"$out") -eq 2 ]]; then
    echo "ok   - the audit writers get a Kerberos login (JAAS file and JVM option)"
else
    echo "FAIL - the JAAS file or -Djava.security.auth.login.config is missing or incomplete"; FAILED=1
fi
out=$(render --set ranger.admin.ssl.enabled=false)
if grep -qE "java.security.auth.login.config|ranger-audit-jaas.conf" <<<"$out"; then
    echo "FAIL - a JAAS file is rendered without a principal and keytab"; FAILED=1
else
    echo "ok   - no JAAS file without a principal and keytab"
fi
out=$(helm template trino-test "$CHART" --namespace analytics --set server.workers=1 \
    --set ranger.audit.kerberos.principal=p@EXAMPLE.COM --set ranger.audit.kerberos.keytab=/k)
if grep -qE "java.security.auth.login.config|ranger-audit-jaas.conf" <<<"$out"; then
    echo "FAIL - a JAAS file is rendered without Ranger access control"; FAILED=1
else
    echo "ok   - no JAAS file without Ranger access control"
fi

exit $FAILED
