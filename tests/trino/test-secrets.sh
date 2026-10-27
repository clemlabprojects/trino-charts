#!/usr/bin/env bash

# Render-only checks (no cluster needed): the LDAP/AD bind password, the OIDC client secret, the internal shared
# secret, the HTTPS keystore password and catalog credentials never land in a ConfigMap or in a plain env var of a
# pod spec, where anyone allowed to read ConfigMaps or Deployments in the namespace could read them.

set -euo pipefail

CHART="$(cd "$(dirname "$0")/../../charts/trino" && pwd)"
FAILED=0

render() {
    helm template trino-test "$CHART" --namespace analytics --set server.workers=1 "$@"
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

# A secret must not show up in a ConfigMap or a Deployment, in clear or base64-encoded.
expect_hidden() {
    local secret=$1 text=$2
    local encoded
    encoded=$(printf '%s' "$secret" | base64)
    for kind in ConfigMap Deployment; do
        local docs
        docs=$(documents_of_kind "$kind" "$text")
        expect_absent "$secret not in a $kind" "$secret" "$docs"
        expect_absent "$secret not base64-encoded in a $kind" "$encoded" "$docs"
    done
}

LDAP_ARGS=(
    --set global.security.auth.mode=ldap
    --set global.security.auth.ldap.url=ldaps://ldap.example.com
    --set global.security.auth.ldap.bindDn=cn=bind,dc=example
    --set global.security.auth.ldap.baseDn=dc=example
    --set global.security.auth.ldap.bindPassword=Bind-Pass-1
)

echo "==> LDAP profile: the bind password comes from the chart's credentials Secret"
out=$(render "${LDAP_ARGS[@]}")
expect_hidden Bind-Pass-1 "$out"
secrets=$(documents_of_kind Secret "$out")
expect_contains "credentials Secret" "name: trino-test-clemlab-trino-auth-credentials" "$secrets"
expect_contains "bind password in it" "bind-password: \"$(printf 'Bind-Pass-1' | base64)\"" "$secrets"
expect_contains "authenticator reads it from the env" 'ldap.bind-password=${ENV:TRINO_LDAP_PASSWORD}' "$out"
expect_count "coordinator and worker read it from the Secret" "key: bind-password" 2 "$out"
expect_absent "no AD variable in LDAP mode" "TRINO_AD_BIND_PASSWORD" "$out"

echo "==> AD profile: one variable name for the authenticator, the AD password when no LDAP one is set"
out=$(render --set global.security.auth.mode=ad --set global.security.auth.ad.url=ldaps://ad.example.com \
    --set global.security.auth.ad.bindDn=cn=bind --set global.security.auth.ad.baseDn=dc=example \
    --set global.security.auth.ad.bindPassword=Ad-Pass-2)
expect_hidden Ad-Pass-2 "$out"
expect_contains "AD password in the credentials Secret" "bind-password: \"$(printf 'Ad-Pass-2' | base64)\"" "$out"
expect_contains "authenticator reads TRINO_LDAP_PASSWORD" 'ldap.bind-password=${ENV:TRINO_LDAP_PASSWORD}' "$out"
expect_count "TRINO_AD_BIND_PASSWORD kept, from the Secret" "name: TRINO_AD_BIND_PASSWORD" 2 "$out"
expect_count "both variables read from the Secret" "key: bind-password" 4 "$out"

echo "==> LDAP profile without a bind password: no Secret, no bind-password line"
out=$(render --set global.security.auth.mode=ldap --set global.security.auth.ldap.url=ldaps://ldap.example.com)
expect_absent "no credentials Secret" "auth-credentials" "$out"
expect_absent "no bind-password line" "ldap.bind-password" "$out"
expect_absent "no TRINO_LDAP_PASSWORD" "TRINO_LDAP_PASSWORD" "$out"

echo "==> OIDC profile with an inline client: the client secret comes from the credentials Secret"
out=$(render --set global.security.auth.mode=oidc --set global.security.auth.oidc.issuerUrl=https://idp/realms/r \
    --set global.security.auth.oidc.clientId=trino --set global.security.auth.oidc.clientSecret=Client-Secret-3)
expect_hidden Client-Secret-3 "$out"
expect_contains "client secret in the credentials Secret" "oidc-client-secret: \"$(printf 'Client-Secret-3' | base64)\"" "$out"
expect_contains "client id from the env" 'http-server.authentication.oauth2.client-id=${ENV:OIDC_CLIENT_ID}' "$out"
expect_contains "client secret from the env" 'http-server.authentication.oauth2.client-secret=${ENV:OIDC_CLIENT_SECRET}' "$out"
expect_count "client secret read from the Secret" "key: oidc-client-secret" 2 "$out"

echo "==> OIDC profile with secretRef AND an inline client (what KDPS sends for an External profile): secretRef wins"
out=$(render --set global.security.auth.mode=oidc --set global.security.auth.oidc.issuerUrl=https://idp/realms/r \
    --set global.security.auth.oidc.clientId=trino --set global.security.auth.oidc.clientSecret=Client-Secret-4 \
    --set global.security.auth.oidc.secretRef.name=trino-oidc-client)
expect_absent "inline client secret nowhere" "Client-Secret-4" "$out"
expect_absent "inline client secret nowhere, base64" "$(printf 'Client-Secret-4' | base64)" "$out"
expect_absent "no credentials Secret" "auth-credentials" "$out"
expect_contains "client secret from the env" 'http-server.authentication.oauth2.client-secret=${ENV:OIDC_CLIENT_SECRET}' "$out"
expect_count "client id and secret read from the client's Secret" 'name: "trino-oidc-client"' 4 "$out"

echo "==> existingSecret: the operator's Secret is read, the chart renders none"
out=$(render "${LDAP_ARGS[@]}" --set global.security.auth.existingSecret=trino-ldap-bind)
expect_absent "no chart credentials Secret" "name: trino-test-clemlab-trino-auth-credentials" "$out"
expect_count "bind password read from the operator's Secret" 'name: "trino-ldap-bind"' 2 "$out"
out=$(render --set global.security.auth.mode=ldap --set global.security.auth.ldap.bindDn=cn=bind \
    --set global.security.auth.ldap.baseDn=dc=example \
    --set global.security.auth.existingSecret=trino-ldap-bind)
expect_contains "bind-password line without a password in the values" 'ldap.bind-password=${ENV:TRINO_LDAP_PASSWORD}' "$out"

echo "==> values from earlier KDPS versions: literal shared secret and keystore password lines are left out"
STALE_ARGS=(
    --set 'additionalConfigProperties[0]=internal-communication.shared-secret=Shared-Secret-5'
    --set 'additionalConfigProperties[1]=http-server.process-forwarded=true'
    --set 'coordinator.additionalConfigProperties[0]=http-server.https.keystore.key=Keystore-Pass-6'
    --set 'coordinator.additionalConfigProperties[1]=query.max-history=500'
    --set server.config.https.enabled=true
    --set server.config.https.keystore.secretName=trino-https
    --set server.config.https.keystore.passwordSecretName=trino-https-pass
)
out=$(render "${LDAP_ARGS[@]}" "${STALE_ARGS[@]}")
expect_hidden Shared-Secret-5 "$out"
expect_hidden Keystore-Pass-6 "$out"
configmaps=$(documents_of_kind ConfigMap "$out")
expect_count "one shared-secret line per node role, from the env" 'internal-communication.shared-secret=${ENV:TRINO_INTERNAL_SHARED_SECRET}' 2 "$configmaps"
expect_count "other additional properties kept (coordinator and worker)" "http-server.process-forwarded=true" 2 "$configmaps"
expect_contains "other coordinator properties kept" "query.max-history=500" "$configmaps"
expect_contains "keystore password still appended from its Secret" 'http-server.https.keystore.key=$(cat' "$out"
out=$(render --set 'additionalConfigProperties[0]=internal-communication.shared-secret=Own-Secret-7' \
    --set 'coordinator.additionalConfigProperties[0]=http-server.https.keystore.key=Own-Pass-8')
expect_contains "without authentication the operator's shared secret is kept" "internal-communication.shared-secret=Own-Secret-7" "$out"
expect_contains "without the HTTPS keystore Secret the operator's password is kept" "http-server.https.keystore.key=Own-Pass-8" "$out"

echo "==> catalog credentials: Secrets exposed as env vars, the catalog references them"
out=$(render --set 'catalogCredentialSecrets[0]=pg-credentials' --set 'catalogCredentialSecrets[1]=mysql-credentials' \
    --set 'envFrom[0].configMapRef.name=extra-env' \
    --set-string 'additionalCatalogs.pg=connector.name=postgresql\nconnection-password=${ENV:PG_PASSWORD}')
deployments=$(documents_of_kind Deployment "$out")
expect_count "first Secret on coordinator and worker" 'name: "pg-credentials"' 2 "$deployments"
expect_count "second Secret on coordinator and worker" 'name: "mysql-credentials"' 2 "$deployments"
expect_count "envFrom entries kept" "name: extra-env" 2 "$deployments"
expect_contains "catalog keeps the reference" 'connection-password=${ENV:PG_PASSWORD}' "$(documents_of_kind ConfigMap "$out")"
out=$(render)
expect_absent "no catalog credentials by default" "secretRef" "$(documents_of_kind Deployment "$out")"

echo "==> no rendered annotation can be used to guess a credential without a cluster to salt it"
out=$(render "${LDAP_ARGS[@]}")
expect_absent "no credentials checksum when the shared secret cannot be read" "checksum/auth-credentials" "$out"

echo "==> no two resources share a kind and a name"
out=$(render "${LDAP_ARGS[@]}" "${STALE_ARGS[@]}" --set 'catalogCredentialSecrets[0]=pg-credentials' \
    --set accessControl.type=ranger --set ranger.serviceName=trino-test --set ranger.admin.ssl.enabled=false --set dynamicCatalogs.enabled=true \
    --set kdps.serviceUser.enabled=true)
dupes=$(awk '/^kind: /{k=$2} /^  name: /{if (k) {print k "/" $2; k=""}}' <<<"$out" | sort | uniq -d)
if [ -z "$dupes" ]; then echo "ok   - unique names"; else echo "FAIL - duplicated resources: $dupes"; FAILED=1; fi

if [ "$FAILED" -ne 0 ]; then
    echo "Some trino secret template tests failed."
    exit 1
fi
echo "All trino secret template tests passed."
