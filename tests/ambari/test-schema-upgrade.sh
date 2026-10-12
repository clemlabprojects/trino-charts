#!/usr/bin/env bash

# Render-only checks (no cluster needed) for the database schema upgrade: the image upgrades the
# schema of a database from an earlier Ambari line only when schemaUpgrade.enabled asks it to, and the
# release notes say so while it is on, so that it is not left on for the next move to a new line.

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

# The release notes, which helm template does not print. Rendered client-side, without a cluster.
notes() {
    helm install ambari "$CHART" --dry-run=client "${COMMON[@]}" "$@" | sed -n '/^NOTES:/,$p'
}

ok() { echo "ok   - $1"; }
not_ok() { echo "FAIL - $1"; FAILED=1; }

expect_contains() {
    local label=$1 needle=$2 text=$3
    if grep -qF -- "$needle" <<<"$text"; then ok "$label"; else not_ok "$label: expected '$needle'"; fi
}

expect_absent() {
    local label=$1 needle=$2 text=$3
    if grep -qF -- "$needle" <<<"$text"; then not_ok "$label: did not expect '$needle'"; else ok "$label"; fi
}

expect_equal() {
    local label=$1 expected=$2 actual=$3
    if [ "$expected" = "$actual" ]; then ok "$label"; else not_ok "$label: expected '$expected', got '$actual'"; fi
}

# One environment variable of the server container, as "value=..." or "absent". Read with a YAML
# parser rather than grep.
container_env() {
    python3 -c '
import sys, yaml
d = [d for d in yaml.safe_load_all(sys.stdin) if d and d.get("kind") == "Deployment"][0]
env = d["spec"]["template"]["spec"]["containers"][0]["env"]
e = next((e for e in env if e["name"] == sys.argv[1]), None)
print("absent" if e is None else "value=" + str(e.get("value")))' "$1"
}

echo "==> by default the schema is never upgraded"
out=$(render)
expect_equal "no AMBARI_SCHEMA_UPGRADE" "absent" "$(container_env AMBARI_SCHEMA_UPGRADE <<<"$out")"
expect_absent "the notes say nothing about it" "Schema   :" "$(notes)"
out=$(render --set schemaUpgrade.enabled=false)
expect_equal "nor when it is turned off" "absent" "$(container_env AMBARI_SCHEMA_UPGRADE <<<"$out")"

echo "==> schemaUpgrade.enabled asks the image to upgrade it"
out=$(render --set schemaUpgrade.enabled=true)
expect_equal "AMBARI_SCHEMA_UPGRADE=true" "value=true" "$(container_env AMBARI_SCHEMA_UPGRADE <<<"$out")"
text=$(notes --set schemaUpgrade.enabled=true)
expect_contains "the notes say it is on" "Schema   : upgraded before the server starts when the database is from an earlier Ambari line" "$text"
expect_contains "and to turn it off again" "set it back to
             false once the pod is Ready." "$text"

if [ "$FAILED" -ne 0 ]; then
    echo "ambari schema upgrade checks FAILED"
    exit 1
fi
echo "ambari schema upgrade checks passed"
