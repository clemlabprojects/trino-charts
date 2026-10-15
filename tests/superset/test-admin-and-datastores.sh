#!/usr/bin/env bash

# Render-only checks (no cluster needed): the administrator never gets a well-known password, its password never
# lands in the init script or a pod spec, the break-glass local sign-in is off in every security profile unless
# turned on, and the pods read the database and Redis passwords from the Secrets the operator names.

set -euo pipefail

SRC="$(cd "$(dirname "$0")/../../charts/superset" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# The PostgreSQL and Redis sub-charts are not rendered; drop them from the copy so no registry is needed. Their
# values (postgresql.*, redis.*) are still read by the Superset templates.
cp -r "$SRC" "$WORK/superset"
awk '/^dependencies:/{exit} {print}' "$SRC/Chart.yaml" > "$WORK/superset/Chart.yaml"
CHART="$WORK/superset"
FAILED=0

render() {
    helm template ss "$CHART" --namespace analytics \
        --set postgresql.enabled=false --set redis.enabled=false \
        --set supersetCeleryBeat.enabled=true --set supersetCeleryFlower.enabled=true \
        --set supersetWebsockets.enabled=true "$@"
}

# The documents of one kind, so a check on ConfigMaps or Deployments cannot be satisfied by a Secret.
documents_of_kind() {
    local kind=$1 text=$2
    awk -v kind="$kind" '
        /^---/ { if (doc ~ "\nkind: " kind "\n") printf "%s", doc; doc = "\n"; next }
        { doc = doc $0 "\n" }
        END { if (doc ~ "\nkind: " kind "\n") printf "%s", doc }
    ' <<<"$text"
}

# The document rendered from one template.
document_of() {
    local template=$1 text=$2
    awk -v source="# Source: superset/templates/$template" '
        /^---/ { if (doc ~ source) printf "%s", doc; doc = ""; next }
        { doc = doc $0 "\n" }
        END { if (doc ~ source) printf "%s", doc }
    ' <<<"$text"
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

# The value of the env var SECURITY_LOCAL_LOGIN_FALLBACK, once per pod that sets it.
fallback_values() {
    grep -A1 -- '- name: SECURITY_LOCAL_LOGIN_FALLBACK' <<<"$1" | grep -E '^\s+value: ' | sed -E 's/^\s+//' || true
}

# web, worker, beat, flower, websockets and the init job
PODS=6

for mode in ldap ad oidc; do
    echo "==> $mode profile: the break-glass local sign-in is off unless turned on"
    out=$(render --set global.security.auth.mode=$mode)
    expect_count "SECURITY_LOCAL_LOGIN_FALLBACK=false in every pod" 'value: "false"' $PODS "$(fallback_values "$out")"
    expect_absent "no pod turns it on" 'value: "true"' "$(fallback_values "$out")"
    out=$(render --set global.security.auth.mode=$mode --set global.security.auth.localLoginFallback=true)
    expect_count "turned on in every pod with localLoginFallback=true" 'value: "true"' $PODS "$(fallback_values "$out")"
done

echo "==> superset_config.py: without the env var, the fallback is off too"
out=$(render --set global.security.auth.mode=ldap)
config=$(document_of secret-superset-config.yaml "$out")
expect_contains "LDAP fallback defaults to off" "_LOCAL_FALLBACK = env('SECURITY_LOCAL_LOGIN_FALLBACK', 'false')" "$config"
expect_contains "OIDC /login/local defaults to off" "_OIDC_LOCAL_FALLBACK = env('SECURITY_LOCAL_LOGIN_FALLBACK', 'false')" "$config"
expect_absent "no default that turns it on" "'SECURITY_LOCAL_LOGIN_FALLBACK', 'true'" "$config"

echo "==> mode none: local accounts are the sign-in, no fallback switch"
out=$(render --set global.security.auth.mode=none)
expect_absent "no SECURITY_LOCAL_LOGIN_FALLBACK" "SECURITY_LOCAL_LOGIN_FALLBACK" "$(documents_of_kind "(Deployment|Job)" "$out")"

echo "==> default administrator: a generated password in <fullname>-admin-password, never 'admin'"
out=$(render)
admin=$(document_of secret-admin.yaml "$out")
expect_contains "administrator Secret rendered" "name: ss-superset-admin-password" "$admin"
expect_contains "kept after an uninstall" "helm.sh/resource-policy: keep" "$admin"
expect_absent "not the password 'admin'" "password: \"$(printf admin | base64)\"" "$admin"
generated=$(grep -E '^\s+password: ' <<<"$admin" | sed -E 's/^\s+password: "(.*)"$/\1/' | base64 -d)
if [ "${#generated}" -ge 24 ]; then echo "ok   - generated password of ${#generated} characters"; else echo "FAIL - generated password too short: ${#generated}"; FAILED=1; fi
script=$(document_of secret-superset-config.yaml "$out")
expect_contains "init script reads the password from the environment" '--password "$ADMIN_PASSWORD"' "$script"
expect_absent "no password in the init script" "--password admin" "$script"
expect_absent "no reset by default" "fab reset-password" "$script"
job=$(document_of init-job.yaml "$out")
expect_contains "init job reads ADMIN_PASSWORD from the Secret" 'name: "ss-superset-admin-password"' "$(grep -A4 -- '- name: ADMIN_PASSWORD' <<<"$job")"
expect_contains "init job pods carry the release label" "release: ss" "$job"

echo "==> a password given in the values: kept in the Secret, never in a pod spec, a ConfigMap or the init script"
out=$(render --set init.adminUser.password=Admin-Pass-1)
expect_contains "password in the administrator Secret" "password: \"$(printf Admin-Pass-1 | base64)\"" "$(document_of secret-admin.yaml "$out")"
expect_absent "not in a Deployment or Job" "Admin-Pass-1" "$(documents_of_kind "(Deployment|Job)" "$out")"
expect_absent "not in a ConfigMap" "Admin-Pass-1" "$(documents_of_kind ConfigMap "$out")"
expect_absent "not in the init script" "Admin-Pass-1" "$(document_of secret-superset-config.yaml "$out")"

echo "==> existingSecret (the KDPS view): no chart Secret, the init job reads the named one; resetPassword resets it"
out=$(render --set init.adminUser.existingSecret=ss-kdps-admin --set init.adminUser.passwordKey=pw \
    --set init.adminUser.resetPassword=true)
expect_absent "no chart administrator Secret" "secret-admin.yaml" "$out"
refs=$(grep -A4 -- '- name: ADMIN_PASSWORD' <<<"$(document_of init-job.yaml "$out")")
expect_contains "named Secret" 'name: "ss-kdps-admin"' "$refs"
expect_contains "named key" 'key: "pw"' "$refs"
expect_contains "existing administrator reset" 'superset fab reset-password --username admin --password "$ADMIN_PASSWORD"' \
    "$(document_of secret-superset-config.yaml "$out")"

echo "==> createAdmin=false: no administrator, no Secret, no ADMIN_PASSWORD"
out=$(render --set init.createAdmin=false)
expect_absent "no administrator Secret" "secret-admin.yaml" "$out"
expect_absent "no ADMIN_PASSWORD" "ADMIN_PASSWORD" "$(documents_of_kind Job "$out")"

echo "==> postgresql.auth.existingSecret and redis.auth.existingSecret: every pod reads the passwords from them"
DATASTORE_ARGS=(
    --set postgresql.enabled=true --set postgresql.auth.existingSecret=ss-superset-db
    --set redis.enabled=true --set redis.auth.enabled=true --set redis.auth.existingSecret=ss-superset-redis
)
out=$(render "${DATASTORE_ARGS[@]}" --set supersetNode.connections.db_pass=Db-Pass-2)
workloads=$(documents_of_kind "(Deployment|Job)" "$out")
expect_count "DB_PASS from the database Secret" 'name: "ss-superset-db"' $PODS "$workloads"
expect_count "REDIS_PASSWORD from the Redis Secret" 'name: "ss-superset-redis"' $PODS "$workloads"
expect_count "Redis password key" 'key: "redis-password"' $PODS "$workloads"
expect_absent "db_pass not in the env Secret" "Db-Pass-2" "$(document_of secret-env.yaml "$out")"
config=$(document_of secret-superset-config.yaml "$out")
expect_contains "Redis URL carries the password" "{env('REDIS_PASSWORD')}@" "$config"
expect_contains "results backend authenticates" "password=env('REDIS_PASSWORD')" "$config"

echo "==> without them, the connection values are used as before"
out=$(render --set supersetNode.connections.db_pass=Db-Pass-3)
expect_contains "DB_PASS in the env Secret" 'DB_PASS: "Db-Pass-3"' "$(document_of secret-env.yaml "$out")"
expect_absent "no DB_PASS env var" "- name: DB_PASS" "$(documents_of_kind "(Deployment|Job)" "$out")"
expect_absent "no Redis password" "REDIS_PASSWORD" "$(document_of secret-superset-config.yaml "$out")"

echo "==> no two resources share a kind and a name"
out=$(render "${DATASTORE_ARGS[@]}" --set global.security.auth.mode=ad)
dupes=$(awk '/^kind: /{k=$2} /^  name: /{if (k) {print k "/" $2; k=""}}' <<<"$out" | sort | uniq -d)
if [ -z "$dupes" ]; then echo "ok   - unique names"; else echo "FAIL - duplicated resources: $dupes"; FAILED=1; fi

if [ "$FAILED" -ne 0 ]; then
    echo "Some superset administrator and data store template tests failed."
    exit 1
fi
echo "All superset administrator and data store template tests passed."
