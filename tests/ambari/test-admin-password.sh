#!/usr/bin/env bash

# Render-only checks (no cluster needed) for the first administrator password: the chart refuses to
# render without one unless the default is explicitly allowed, hands it to the image from whichever
# source it comes from (an existing Secret, Vault, or inline), and keeps the pod out of the Service
# until the image has replaced admin/admin.

set -euo pipefail

CHART="$(cd "$(dirname "$0")/../../charts/ambari" && pwd)"
NAMESPACE=kdps
FAILED=0

COMMON=(--namespace "$NAMESPACE" --set database.host=postgres.example.svc --set database.password=changeme
        --set masterKey.value=a-master-key --set route.host=ambari.apps.example.com)

VAULT=(--set global.vault.enabled=true --set global.vault.address=https://vault.vault-csi.svc:8200
       --set global.vault.auth.kubernetes.role=ambari)

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

expect_refused() {
    local label=$1 needle=$2
    shift 2
    local out
    if out=$(render "$@" 2>&1); then
        not_ok "$label: rendered, expected it to be refused"
    elif grep -qF -- "$needle" <<<"$out"; then
        ok "$label"
    else
        not_ok "$label: refused, but not with '$needle': $out"
    fi
}

# One environment variable of the server container, as "value=..." or "secret=<name>/<key>", or
# "absent". Read with a YAML parser rather than grep.
container_env() {
    python3 -c '
import sys, yaml
d = [d for d in yaml.safe_load_all(sys.stdin) if d and d.get("kind") == "Deployment"][0]
env = d["spec"]["template"]["spec"]["containers"][0]["env"]
e = next((e for e in env if e["name"] == sys.argv[1]), None)
if e is None:
    print("absent")
elif "value" in e:
    print("value=" + str(e["value"]))
else:
    ref = e["valueFrom"]["secretKeyRef"]
    print("secret=%s/%s" % (ref["name"], ref["key"]))' "$1"
}

# The server container's readiness probe command, one argument per line.
readiness_command() {
    python3 -c '
import sys, yaml
d = [d for d in yaml.safe_load_all(sys.stdin) if d and d.get("kind") == "Deployment"][0]
probe = d["spec"]["template"]["spec"]["containers"][0]["readinessProbe"]
if "exec" not in probe:
    print("not an exec probe: %s" % sorted(probe))
else:
    print("\n".join(probe["exec"]["command"]))'
}

# One document of the rendered output, by kind and name, as YAML ("" when absent).
document() {
    python3 -c '
import sys, yaml
for d in yaml.safe_load_all(sys.stdin):
    if d and d.get("kind") == sys.argv[1] and d["metadata"]["name"] == sys.argv[2]:
        print(yaml.safe_dump(d))' "$1" "$2"
}

echo "==> no administrator password: the chart refuses to render"
expect_refused "no password" "the first administrator password is required"
expect_refused "no password, also without a Route" "the first administrator password is required" \
    --set route.enabled=false

echo "==> an existing Secret"
out=$(render --set adminPassword.existingSecret=ambari-admin)
expect_equal "AMBARI_ADMIN_PASSWORD from that Secret" "secret=ambari-admin/password" "$(container_env AMBARI_ADMIN_PASSWORD <<<"$out")"
expect_equal "the default is not allowed" "absent" "$(container_env AMBARI_ADMIN_ALLOW_DEFAULT <<<"$out")"
expect_equal "no Secret of the chart's own" "" "$(document Secret ambari-admin-password <<<"$out")"
out=$(render --set adminPassword.existingSecret=ambari-admin --set adminPassword.existingSecretKey=admin-password)
expect_equal "with its own key" "secret=ambari-admin/admin-password" "$(container_env AMBARI_ADMIN_PASSWORD <<<"$out")"

echo "==> inline (development)"
out=$(render --set-string 'adminPassword.value=s3cr"et pass')
expect_equal "AMBARI_ADMIN_PASSWORD from the chart's Secret" "secret=ambari-admin-password/password" "$(container_env AMBARI_ADMIN_PASSWORD <<<"$out")"
secret=$(document Secret ambari-admin-password <<<"$out")
expect_contains "the Secret holds the value" 's3cr"et pass' "$(python3 -c 'import sys, yaml; print(yaml.safe_load(sys.stdin)["stringData"]["password"])' <<<"$secret")"

echo "==> Vault"
out=$(render "${VAULT[@]}" --set vault.csi.adminPassword.enabled=true \
    --set vault.csi.adminPassword.path=secret/data/kdps/ambari/admin)
expect_equal "AMBARI_ADMIN_PASSWORD from the synced Secret" "secret=ambari-admin-password/password" "$(container_env AMBARI_ADMIN_PASSWORD <<<"$out")"
spc=$(document SecretProviderClass ambari-vault <<<"$out")
expect_contains "read out of Vault" 'objectName: "admin-password"
  secretPath: "secret/data/kdps/ambari/admin"
  secretKey: password' "$spc"
synced=$(python3 -c '
import sys, yaml
spc = yaml.safe_load(sys.stdin)
print([(o["secretName"], o["data"]) for o in spc["spec"]["secretObjects"]])' <<<"$spc")
expect_contains "synced into a Secret" "('ambari-admin-password', [{'key': 'password', 'objectName': 'admin-password'}])" "$synced"
expect_contains "the CSI volume is mounted" "secretProviderClass: ambari-vault" "$out"
expect_equal "no Secret of the chart's own" "" "$(document Secret ambari-admin-password <<<"$out")"
out=$(render "${VAULT[@]}" --set vault.csi.adminPassword.enabled=true \
    --set vault.csi.adminPassword.path=secret/data/kdps/ambari/admin \
    --set vault.csi.adminPassword.key=admin --set vault.csi.adminPassword.secretName=kdps-admin)
expect_equal "with its own key and Secret name" "secret=kdps-admin/admin" "$(container_env AMBARI_ADMIN_PASSWORD <<<"$out")"
expect_refused "Vault without a path" "vault.csi.adminPassword.path is required" \
    "${VAULT[@]}" --set vault.csi.adminPassword.enabled=true

echo "==> adminPassword.allowDefault keeps admin/admin, and says so"
out=$(render --set adminPassword.allowDefault=true)
expect_equal "no AMBARI_ADMIN_PASSWORD" "absent" "$(container_env AMBARI_ADMIN_PASSWORD <<<"$out")"
expect_equal "AMBARI_ADMIN_ALLOW_DEFAULT" "value=true" "$(container_env AMBARI_ADMIN_ALLOW_DEFAULT <<<"$out")"
expect_contains "the notes warn" "WARNING -- admin/admin (adminPassword.allowDefault=true)" "$(notes --set adminPassword.allowDefault=true)"
out=$(render --set adminPassword.allowDefault=true --set adminPassword.existingSecret=ambari-admin)
expect_equal "a password given anyway is still set" "secret=ambari-admin/password" "$(container_env AMBARI_ADMIN_PASSWORD <<<"$out")"

echo "==> the pod is not Ready until the default password is gone"
out=$(render --set adminPassword.existingSecret=ambari-admin)
expect_equal "HTTP" "sh
-c
test -f /tmp/admin-bootstrapped && curl -fsS -o /dev/null http://127.0.0.1:8080/" "$(readiness_command <<<"$out")"
expect_contains "the probe timings are kept" "initialDelaySeconds: 60" "$(python3 -c '
import sys, yaml
d = [d for d in yaml.safe_load_all(sys.stdin) if d and d.get("kind") == "Deployment"][0]
print(yaml.safe_dump(d["spec"]["template"]["spec"]["containers"][0]["readinessProbe"]))' <<<"$out")"
out=$(render --set adminPassword.existingSecret=ambari-admin --set api.tls.enabled=true \
    --set api.tls.existingSecret=ambari-api-tls --set route.tls.mode=passthrough)
expect_equal "HTTPS when the server serves only that" "sh
-c
test -f /tmp/admin-bootstrapped && curl -fsS -o /dev/null -k https://127.0.0.1:8443/" "$(readiness_command <<<"$out")"
out=$(render --set adminPassword.existingSecret=ambari-admin --set api.tls.enabled=true \
    --set api.tls.existingSecret=ambari-api-tls --set route.tls.mode=passthrough --set api.tls.port=9443)
expect_contains "on the server's HTTPS port" "https://127.0.0.1:9443/" "$(readiness_command <<<"$out")"

echo "==> the notes name the Secret instead of admin/admin"
text=$(notes --set adminPassword.existingSecret=ambari-admin)
expect_contains "the Secret" "Admin    : password from Secret ambari-admin (key password)" "$text"
expect_absent "no admin/admin advice" "admin/admin by default" "$text"
expect_absent "no admin/admin warning" "WARNING -- admin/admin" "$text"

if [ "$FAILED" -ne 0 ]; then
    echo "ambari administrator password checks FAILED"
    exit 1
fi
echo "ambari administrator password checks passed"
