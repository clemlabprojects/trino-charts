#!/usr/bin/env bash
# The Atlas tag projector CronJob: which image it runs, and how it is told the Trino catalog of its
# sources. Without a map the projector takes every Hive service on the tag service (a Cloudera
# cluster has two) to the default catalog; a map selects sources.
set -euo pipefail

CHART="$(cd "$(dirname "$0")/../../charts/trino" && pwd)"

render() {
    helm template trino-test "$CHART" --namespace analytics --set server.workers=1 \
        --set accessControl.type=ranger --set ranger.serviceName=trino-analytics \
        --set ranger.securityConfigMapName=trino-test-ranger-trino-security \
        --set ranger.auditConfigMapName=trino-test-ranger-trino-audit \
        --set ranger.policymgrSslConfigMapName=trino-test-ranger-policymgr-ssl \
        --set tagSync.enabled=true --set tagSync.ranger.url=https://ranger.example.com:6182 \
        --set tagSync.ranger.existingSecret=trino-test-tagsync-ranger "$@"
}

# The value of an env variable of the CronJob's container.
env_of() {
    awk -v name="$1" '
        /^kind: CronJob/ { cron = 1 }
        /^---/ { cron = 0 }
        cron && $0 ~ "- name: " name "$" { getline; sub(/^ *value: /, ""); print; exit }'
}

fail() { echo "FAIL: $1" >&2; exit 1; }

out="$(render)"
grep -q 'image: .*kdps-tag-projector:0.1.1' <<<"$out" || fail "the projector image is not 0.1.1"
[ "$(env_of DEFAULT_CATALOG <<<"$out")" = '"hive"' ] || fail "the default catalog is not hive"
[ "$(env_of CATALOG_MAP <<<"$out")" = '"{}"' ] || fail "an empty catalog map is not passed as {}"
[ "$(grep -c 'name: DEFAULT_CATALOG' <<<"$out")" = 2 ] || fail "the install Job and the CronJob do not both get the default catalog"

out="$(render --set tagSync.defaultCatalog=warehouse --set tagSync.catalogMap.cm_hive=lake)"
[ "$(env_of DEFAULT_CATALOG <<<"$out")" = '"warehouse"' ] || fail "tagSync.defaultCatalog is not passed"
[ "$(env_of CATALOG_MAP <<<"$out")" = '"{\"cm_hive\":\"lake\"}"' ] || fail "tagSync.catalogMap is not passed"

out="$(render --set tagSync.enabled=false)"
! grep -q 'tag-projector' <<<"$out" || fail "the projector is rendered with tag sync off"

echo "tag projector: OK"
