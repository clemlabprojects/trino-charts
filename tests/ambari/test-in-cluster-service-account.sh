#!/usr/bin/env bash

# Render-only checks (no cluster needed) for KDPS connecting with the Ambari pod's own ServiceAccount: the pod asks for
# its ServiceAccount token when inClusterServiceAccount.enabled or serviceAccount.automountToken is set and is otherwise
# given none (KDPS does not use it, and whoever gets into the pod would hold the account's grants), the chart grants that ServiceAccount nothing either way, and the release notes name the identity KDPS acts as and
# the per-project grants it needs.

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

# What the rendered manifests say about the pod's ServiceAccount, one line per fact, read with a YAML parser:
#   serviceaccount <name>        each ServiceAccount the chart creates
#   pod-account <name>           the ServiceAccount the pod runs as
#   automount <true|false|unset> the pod's automountServiceAccountToken
#   binding <kind> <name> <subject-kind>:<subject-namespace>:<subject-name>
#                                each subject of each RoleBinding and ClusterRoleBinding the chart creates
account_facts() {
    python3 -c '
import sys, yaml
for d in yaml.safe_load_all(sys.stdin):
    if not d:
        continue
    kind = d["kind"]
    if kind == "ServiceAccount":
        print("serviceaccount", d["metadata"]["name"])
    if kind in ("RoleBinding", "ClusterRoleBinding"):
        for s in d.get("subjects", []):
            print("binding", kind, d["metadata"]["name"], "%s:%s:%s" % (s["kind"], s.get("namespace", "-"), s["name"]))
    if kind == "Deployment":
        spec = d["spec"]["template"]["spec"]
        print("pod-account", spec.get("serviceAccountName"))
        automount = spec.get("automountServiceAccountToken")
        print("automount", "unset" if automount is None else str(automount).lower())
'
}

echo "==> defaults: the pod is given no token"
facts=$(render | account_facts)
expect_contains "the release's ServiceAccount is created" "serviceaccount ambari" "$facts"
expect_contains "the pod runs as it" "pod-account ambari" "$facts"
expect_contains "the pod does not mount the token" "automount false" "$facts"
expect_absent "nothing bound to it" "ServiceAccount:kdps:ambari" "$facts"
out=$(notes)
expect_absent "notes do not offer the in-cluster connection" "In-cluster:" "$out"
expect_contains "notes still offer the OpenShift login" "OpenShift : KDPS -> Configuration" "$out"

echo "==> inClusterServiceAccount.enabled: the token is mounted"
facts=$(render --set inClusterServiceAccount.enabled=true | account_facts)
expect_contains "token mounted" "automount true" "$facts"
expect_contains "same ServiceAccount" "pod-account ambari" "$facts"
expect_absent "the chart still grants it nothing" "ServiceAccount:kdps:ambari" "$facts"
out=$(notes --set inClusterServiceAccount.enabled=true)
expect_contains "notes offer the in-cluster connection" \
    'In-cluster: KDPS -> Configuration -> "Connect with this ServiceAccount"' "$out"
expect_contains "notes name the identity" "KDPS then acts as system:serviceaccount:kdps:ambari" "$out"
expect_contains "notes give the admin grant" \
    "oc -n <project> create rolebinding kdps-admin --clusterrole=admin" "$out"
expect_contains "notes give the monitoring-edit grant" \
    "oc -n <project> create rolebinding kdps-monitoring-edit --clusterrole=monitoring-edit" "$out"
expect_contains "for this ServiceAccount" "--serviceaccount=kdps:ambari" "$out"

echo "==> serviceAccount.automountToken mounts it without the in-cluster connection"
facts=$(render --set serviceAccount.automountToken=true | account_facts)
expect_contains "token mounted" "automount true" "$facts"

echo "==> a ServiceAccount the platform team created"
facts=$(render --set serviceAccount.create=false --set serviceAccount.name=kdps-operator | account_facts)
expect_contains "the pod mounts no token, whatever the account says" "automount false" "$facts"
facts=$(render --set inClusterServiceAccount.enabled=true --set serviceAccount.create=false \
    --set serviceAccount.name=kdps-operator | account_facts)
expect_absent "none created" "serviceaccount " "$facts"
expect_contains "the pod runs as it" "pod-account kdps-operator" "$facts"
expect_contains "its token is mounted" "automount true" "$facts"
out=$(notes --set inClusterServiceAccount.enabled=true --set serviceAccount.create=false \
    --set serviceAccount.name=kdps-operator)
expect_contains "notes name it" "system:serviceaccount:kdps:kdps-operator" "$out"
expect_contains "grants are for it" "--serviceaccount=kdps:kdps-operator" "$out"

echo "==> the route certificate grant is the router's, not Ambari's"
facts=$(render --set inClusterServiceAccount.enabled=true --set route.tls.mode=edgeWithCert \
    --api-versions route.openshift.io/v1 | account_facts)
expect_contains "the router may read the certificate" \
    "binding RoleBinding ambari-router-cert ServiceAccount:openshift-ingress:router" "$facts"
expect_equal "and that is the only binding" 1 "$(grep -c '^binding ' <<<"$facts")"

if [ "$FAILED" -ne 0 ]; then
    echo "ambari in-cluster ServiceAccount checks FAILED"
    exit 1
fi
echo "ambari in-cluster ServiceAccount checks passed"
