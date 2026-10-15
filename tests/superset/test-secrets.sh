#!/usr/bin/env bash

# Render-only checks (no cluster needed): the Superset SECRET_KEY, the bind password or OIDC client secret of the
# security profile and the datasource files never land in a ConfigMap or in a plain env var of a pod spec, where
# anyone allowed to read ConfigMaps or Deployments in the namespace could read them.

set -euo pipefail

SRC="$(cd "$(dirname "$0")/../../charts/superset" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# The PostgreSQL and Redis sub-charts are turned off below; drop them from the copy so no registry is needed.
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

# Every value given as `value:` in a pod spec (secretKeyRef and envFrom values are not in it).
plain_env_values() {
    local text=$1
    documents_of_kind "(Deployment|Job)" "$text" | grep -E '^\s+value: ' || true
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

# What the KDPS view sends: the key in extraSecretEnv, a datasource file with a password, an LDAP profile.
KDPS_ARGS=(
    --set extraSecretEnv.SUPERSET_SECRET_KEY=Secret-Key-1
    --set-string 'extraConfigs.import_datasources_trino\.yaml=password: Datasource-Pass-2'
    --set global.security.auth.mode=ldap
    --set global.security.auth.ldap.bindDn=cn=bind
    --set global.security.auth.ldap.bindPassword=Bind-Pass-3
)

echo "==> LDAP profile, SECRET_KEY and datasource file: only in Secrets"
out=$(render "${KDPS_ARGS[@]}")
for secret in Secret-Key-1 Datasource-Pass-2 Bind-Pass-3; do
    expect_absent "$secret not in a ConfigMap" "$secret" "$(documents_of_kind ConfigMap "$out")"
    expect_absent "$secret not in a Deployment or Job" "$secret" "$(documents_of_kind "(Deployment|Job)" "$out")"
done
expect_absent "no ConfigMap for the datasource files" "name: ss-superset-extra-config" "$(documents_of_kind ConfigMap "$out")"
secrets=$(documents_of_kind Secret "$out")
expect_contains "datasource files in a Secret" "name: ss-superset-extra-config" "$secrets"
expect_contains "datasource file content" "password: Datasource-Pass-2" "$secrets"
expect_contains "bind password in the env Secret" 'SECURITY_LDAP_BIND_PASSWORD: "Bind-Pass-3"' "$secrets"
expect_contains "SECRET_KEY in the env Secret" 'SUPERSET_SECRET_KEY: "Secret-Key-1"' "$secrets"
workloads=$(documents_of_kind "(Deployment|Job)" "$out")
# web, worker, beat, flower, websockets and the init job
expect_count "bind password read from the env Secret in every pod" "key: SECURITY_LDAP_BIND_PASSWORD" 6 "$workloads"
# web, worker, beat and the init job mount the datasource files
expect_count "datasource files mounted from the Secret" "secretName: ss-superset-extra-config" 4 "$workloads"
expect_count "datasource files read-only for owner and group" "defaultMode: 288" 4 "$workloads"
volumes=$(grep -A1 -- '- name: superset-extra-config' <<<"$workloads" || true)
expect_absent "no datasource ConfigMap volume" "configMap:" "$volumes"

echo "==> AD profile: the AD bind password comes from the env Secret"
out=$(render --set global.security.auth.mode=ad --set global.security.auth.ad.bindPassword=Ad-Pass-4)
expect_absent "AD bind password not in a pod spec" "Ad-Pass-4" "$(documents_of_kind "(Deployment|Job)" "$out")"
expect_contains "AD bind password in the env Secret" 'SECURITY_AD_BIND_PASSWORD: "Ad-Pass-4"' "$(documents_of_kind Secret "$out")"
expect_count "AD bind password read from the env Secret" "key: SECURITY_AD_BIND_PASSWORD" 6 "$out"

echo "==> OIDC profile with an inline client secret: from the env Secret"
out=$(render --set global.security.auth.mode=oidc --set global.security.auth.oidc.clientId=superset \
    --set global.security.auth.oidc.clientSecret=Client-Secret-5)
expect_absent "client secret not in a pod spec" "Client-Secret-5" "$(documents_of_kind "(Deployment|Job)" "$out")"
expect_contains "client secret in the env Secret" 'SECURITY_OIDC_CLIENT_SECRET: "Client-Secret-5"' "$(documents_of_kind Secret "$out")"
expect_count "client secret read from the env Secret" "key: SECURITY_OIDC_CLIENT_SECRET" 6 "$out"

echo "==> OIDC profile with secretRef: the client's own Secret, nothing in the env Secret"
out=$(render --set global.security.auth.mode=oidc --set global.security.auth.oidc.secretRef.name=superset-oidc \
    --set global.security.auth.oidc.clientSecret=Client-Secret-6)
expect_absent "inline client secret ignored" "Client-Secret-6" "$out"
expect_count "client secret read from secretRef" 'name: "superset-oidc"' 12 "$out"

echo "==> operator-provided env Secret (secretEnv.create=false): referenced, optional, nothing rendered"
out=$(render --set secretEnv.create=false --set envFromSecret=superset-external-env "${KDPS_ARGS[@]}")
expect_absent "no env Secret rendered" "name: ss-superset-env" "$out"
expect_absent "bind password not rendered" "Bind-Pass-3" "$(documents_of_kind "(Deployment|Job)" "$out")"
refs=$(grep -B1 -- 'key: SECURITY_LDAP_BIND_PASSWORD' <<<"$out" || true)
expect_count "bind password read from the operator Secret" 'name: "superset-external-env"' 6 "$refs"
expect_count "the key may be missing from it" "optional: true" 6 "$out"

echo "==> a SECRET_KEY left in extraEnv by an earlier deploy: the Secret wins, the pod spec does not show it"
out=$(render "${KDPS_ARGS[@]}" --set extraEnv.SUPERSET_SECRET_KEY=Secret-Key-1 --set extraEnv.GUNICORN_TIMEOUT=300)
expect_absent "SECRET_KEY not a plain env var" "Secret-Key-1" "$(plain_env_values "$out")"
expect_count "other extraEnv entries kept in every pod" 'name: "GUNICORN_TIMEOUT"' 6 "$out"
out=$(render --set extraEnv.SUPERSET_SECRET_KEY=Plain-Key-7)
expect_contains "without extraSecretEnv, extraEnv is rendered as before" 'value: "Plain-Key-7"' "$(plain_env_values "$out")"

echo "==> the pods restart when a credential changes, and the annotation is one hash of all secrets"
first=$(render "${KDPS_ARGS[@]}" | grep 'checksum/secrets' | sort -u)
second=$(render "${KDPS_ARGS[@]}" --set global.security.auth.ldap.bindPassword=Bind-Pass-8 | grep 'checksum/secrets' | sort -u)
expect_count "one checksum for every pod" "checksum/secrets" 1 "$first"
if [ "$first" != "$second" ]; then echo "ok   - bind password change changes the checksum"; else echo "FAIL - bind password change keeps the checksum"; FAILED=1; fi
expect_absent "no separate checksum of extraSecretEnv" "checksum/extraSecretEnv" "$(render "${KDPS_ARGS[@]}")"

echo "==> no two resources share a kind and a name (the datasource Secret replaces a ConfigMap of the same name)"
out=$(render "${KDPS_ARGS[@]}" --set init.enabled=true)
dupes=$(awk '/^kind: /{k=$2} /^  name: /{if (k) {print k "/" $2; k=""}}' <<<"$out" | sort | uniq -d)
if [ -z "$dupes" ]; then echo "ok   - unique names"; else echo "FAIL - duplicated resources: $dupes"; FAILED=1; fi

if [ "$FAILED" -ne 0 ]; then
    echo "Some superset secret template tests failed."
    exit 1
fi
echo "All superset secret template tests passed."
