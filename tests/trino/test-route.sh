#!/usr/bin/env bash

# Render-only checks (no cluster needed) for the OpenShift Route: which certificate it serves and how it reaches
# Trino. Without a cluster, lookup finds no Secret, so the CA of Trino's certificate is given as a value here.

set -euo pipefail

CHART="$(cd "$(dirname "$0")/../../charts/trino" && pwd)"
FAILED=0
CA="-----BEGIN CERTIFICATE-----
MIIBtestinternalca
-----END CERTIFICATE-----"

# OpenShift 4.20 by default: Kubernetes 1.33.
render() {
    render_template templates/route.yaml "$@"
}

render_template() {
    local template=$1
    shift
    helm template trino-test "$CHART" --namespace analytics --show-only "$template" --kube-version 1.33.0 \
        --set ingress.enabled=true \
        --set 'ingress.hosts[0].host=trino.apps.example.com' \
        --set 'ingress.hosts[0].paths[0].path=/' \
        --set 'ingress.hosts[0].paths[0].pathType=ImplementationSpecific' \
        --set 'ingress.tls[0].secretName=trino-ingress-tls' \
        --set server.config.https.keystore.secretName=trino-https \
        "$@"
}

# The documents of one kind, so a check on the Route cannot be satisfied by the Role.
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

expect_absent() {
    local label=$1 needle=$2 text=$3
    if grep -qF -- "$needle" <<<"$text"; then
        echo "FAIL - $label: did not expect '$needle'"
        FAILED=1
    else
        echo "ok   - $label"
    fi
}

echo "# HTTPS inside, CA known: the Route serves the ingress certificate from its Secret and re-encrypts"
out=$(render --api-versions route.openshift.io/v1 --set server.config.https.enabled=true \
    --set-string "route.tls.destinationCACertificate=$CA")
route=$(documents_of_kind Route "$out")
expect_contains "reencrypt" "termination: reencrypt" "$route"
expect_contains "to Trino's HTTPS port" "targetPort: 8443" "$route"
expect_contains "the ingress Secret is the external certificate" "name: trino-ingress-tls" "$route"
expect_contains "externalCertificate" "externalCertificate:" "$route"
expect_contains "Trino's certificate checked against its CA" "destinationCACertificate: |-" "$route"
expect_contains "the CA itself" "MIIBtestinternalca" "$route"
expect_contains "a path, now that the router reads the request" 'path: "/"' "$route"
expect_absent "no private key in the Route" "key:" "$route"
role=$(documents_of_kind Role "$out")
expect_contains "the router may read the ingress Secret" 'resourceNames: ["trino-ingress-tls"]' "$role"
expect_absent "and nothing else" "create" "$role"
binding=$(documents_of_kind RoleBinding "$out")
expect_contains "bound to the router's service account" "name: router" "$binding"
expect_contains "in openshift-ingress" "namespace: openshift-ingress" "$binding"

echo "# HTTPS inside, CA unknown: passthrough as before, nothing for the router to read"
out=$(render --api-versions route.openshift.io/v1 --set server.config.https.enabled=true)
route=$(documents_of_kind Route "$out")
expect_contains "passthrough" "termination: passthrough" "$route"
expect_absent "no path on a passthrough Route" "path:" "$route"
expect_absent "no external certificate" "externalCertificate" "$route"
expect_absent "no destination CA" "destinationCACertificate" "$route"
expect_absent "no Role" "kind: Role" "$out"

echo "# HTTPS inside, CA known, external certificates off: re-encrypt with the certificate copied (none without a cluster)"
out=$(render --api-versions route.openshift.io/v1 --set server.config.https.enabled=true \
    --set-string "route.tls.destinationCACertificate=$CA" --set route.tls.externalCertificate=false)
route=$(documents_of_kind Route "$out")
expect_contains "reencrypt" "termination: reencrypt" "$route"
expect_absent "no external certificate" "externalCertificate" "$route"
expect_contains "Trino's certificate checked against its CA" "destinationCACertificate: |-" "$route"
expect_absent "no Role" "kind: Role" "$out"

echo "# OpenShift before 4.19 (Kubernetes 1.31): the certificate is copied, unless external certificates are turned on"
out=$(render --api-versions route.openshift.io/v1 --kube-version 1.31.0 --set server.config.https.enabled=true \
    --set-string "route.tls.destinationCACertificate=$CA")
expect_contains "reencrypt" "termination: reencrypt" "$out"
expect_absent "no external certificate" "externalCertificate" "$out"
expect_absent "no Role" "kind: Role" "$out"
out=$(render --api-versions route.openshift.io/v1 --kube-version 1.31.0 --set server.config.https.enabled=true \
    --set-string "route.tls.destinationCACertificate=$CA" --set route.tls.externalCertificate=true)
expect_contains "external certificate when turned on" "externalCertificate:" "$out"
expect_contains "with its Role" "kind: Role" "$out"

echo "# HTTP inside: edge, serving the ingress certificate from its Secret"
out=$(render --api-versions route.openshift.io/v1 --set server.config.https.enabled=false)
route=$(documents_of_kind Route "$out")
expect_contains "edge" "termination: edge" "$route"
expect_contains "to Trino's HTTP port" "targetPort: 8080" "$route"
expect_contains "externalCertificate" "externalCertificate:" "$route"
expect_absent "no destination CA" "destinationCACertificate" "$route"
expect_contains "the router may read the ingress Secret" 'resourceNames: ["trino-ingress-tls"]' "$(documents_of_kind Role "$out")"

echo "# HTTP inside, no ingress certificate: edge on the router's certificate, nothing to read"
out=$(render --api-versions route.openshift.io/v1 --set server.config.https.enabled=false --set 'ingress.tls=null')
expect_contains "edge" "termination: edge" "$out"
expect_absent "no external certificate" "externalCertificate" "$out"
expect_absent "no Role" "kind: Role" "$out"

echo "# Trino behind a re-encrypting Route processes the router's X-Forwarded-* headers, once"
config=$(render_template templates/configmap-coordinator.yaml --api-versions route.openshift.io/v1 \
    --set server.config.https.enabled=true --set-string "route.tls.destinationCACertificate=$CA")
expect_count "process-forwarded set" "http-server.process-forwarded=true" 1 "$config"
config=$(render_template templates/configmap-coordinator.yaml --api-versions route.openshift.io/v1 \
    --set server.config.https.enabled=true --set-string "route.tls.destinationCACertificate=$CA" \
    --set 'additionalConfigProperties[0]=http-server.process-forwarded=true')
expect_count "not twice when already given" "http-server.process-forwarded" 1 "$config"
config=$(render_template templates/configmap-coordinator.yaml --api-versions route.openshift.io/v1 \
    --set server.config.https.enabled=true)
expect_absent "not behind a passthrough Route" "process-forwarded" "$config"
config=$(render_template templates/configmap-coordinator.yaml \
    --set server.config.https.enabled=true --set-string "route.tls.destinationCACertificate=$CA")
expect_absent "not without a Route" "process-forwarded" "$config"

echo "# Not OpenShift: no Route"
if out=$(render --set server.config.https.enabled=true --set-string "route.tls.destinationCACertificate=$CA" 2>&1); then
    expect_absent "no Route" "kind: Route" "$out"
else
    expect_contains "no Route" "could not find template" "$out"
fi

exit $FAILED
