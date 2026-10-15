#!/usr/bin/env bash

# Render-only checks (no cluster needed) for what the Ambari pod keeps on its claim: the view's working
# directory, which holds the KDPS internal CA, and keys/, Ambari's credential store with the Git
# credentials of GitOps releases. keys/ is seeded from the image without replacing anything already on
# the claim, and the chart refuses to run without the claim unless that is acknowledged. The seed
# script itself is run too, on two local directories standing in for the image's keys/ and the claim's.

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

# What the rendered pod does with its claim, one line per fact, read with a YAML parser rather than grep:
#   volume <claim>                     the claim behind the "data" volume
#   mount <container> <path> <subPath> each mount of the "data" volume
#   init <name>                        each init container, in order
#   seed <script line>                 the seed-keys init container's script
#   property <line>                    each line of AMBARI_EXTRA_PROPERTIES
#   pvc <name> <resource-policy>       each PersistentVolumeClaim the chart creates
pod_facts() {
    python3 -c '
import sys, yaml
for d in yaml.safe_load_all(sys.stdin):
    if not d:
        continue
    if d["kind"] == "PersistentVolumeClaim":
        print("pvc", d["metadata"]["name"], d["metadata"].get("annotations", {}).get("helm.sh/resource-policy"))
    if d["kind"] != "Deployment":
        continue
    spec = d["spec"]["template"]["spec"]
    for v in spec.get("volumes", []):
        if v["name"] == "data":
            print("volume", v["persistentVolumeClaim"]["claimName"])
    containers = spec.get("initContainers", []) + spec["containers"]
    for c in spec.get("initContainers", []):
        print("init", c["name"])
        if c["name"] == "seed-keys":
            for line in c["command"][2].splitlines():
                print("seed", line)
            print("seed-security", c["securityContext"] == spec["containers"][0]["securityContext"])
    for c in containers:
        for m in c.get("volumeMounts", []):
            if m["name"] == "data":
                print("mount", c["name"], m["mountPath"], m.get("subPath", "-"))
    for e in spec["containers"][0]["env"]:
        if e["name"] == "AMBARI_EXTRA_PROPERTIES":
            for line in e["value"].splitlines():
                print("property", line)
'
}

echo "==> defaults: the claim is created, kept by helm uninstall, and mounted on both sub-paths"
facts=$(render | pod_facts)
expect_contains "claim created and kept" "pvc ambari keep" "$facts"
expect_contains "claim behind the data volume" "volume ambari" "$facts"
expect_contains "view working directory (internal CA, operation records)" \
    "mount ambari /var/lib/ambari-server/resources/views/k8s-view-data k8s-view-data" "$facts"
expect_contains "keys/ (credential store) on the claim" "mount ambari /var/lib/ambari-server/keys keys" "$facts"
expect_equal "the claim is mounted nowhere else in the server" 2 "$(grep -c '^mount ambari ' <<<"$facts")"
# Both the server and the view keep using the default location; moving only the view's store would
# split it from the server's.
expect_absent "credential store not moved" "credential_store_path" "$facts"
expect_absent "keys directory not moved" "keys_dir" "$facts"

echo "==> defaults: keys/ is seeded from the image before the server starts"
expect_contains "seed-keys init container" "init seed-keys" "$facts"
expect_contains "seed-keys mounts keys/ of the claim" "mount seed-keys /data/keys keys" "$facts"
expect_contains "copies without replacing" "seed cp -Rn /var/lib/ambari-server/keys/. /data/keys/" "$facts"
expect_absent "does not try to keep the times of the kubelet's directory" "cp -a" "$facts"
expect_contains "runs with the server's security context" "seed-security True" "$facts"
expect_equal "init containers, in order" "passwd-shim seed-keys" "$(sed -n 's/^init //p' <<<"$facts" | tr '\n' ' ' | sed 's/ $//')"

echo "==> defaults: the release notes say what is on the claim"
out=$(notes)
expect_contains "claim named" "Data     : claim ambari: the KDPS internal CA" "$out"
expect_contains "back it up" "Back it" "$out"
expect_absent "no warning" "WARNING -- no claim" "$out"

echo "==> an existing claim"
facts=$(render --set persistence.existingClaim=ambari-data | pod_facts)
expect_contains "existing claim referenced" "volume ambari-data" "$facts"
expect_absent "no claim created" "pvc ambari " "$facts"
expect_contains "keys/ still on the claim" "mount ambari /var/lib/ambari-server/keys keys" "$facts"
expect_contains "and still seeded" "init seed-keys" "$facts"
expect_contains "notes name it" "Data     : claim ambari-data:" "$(notes --set persistence.existingClaim=ambari-data)"

echo "==> keys/ is seeded even when no other init container runs"
facts=$(render --set passwdShim.enabled=false | pod_facts)
expect_equal "seed-keys alone" "seed-keys" "$(sed -n 's/^init //p' <<<"$facts" | tr '\n' ' ' | sed 's/ $//')"
facts=$(render --set passwdShim.enabled=false --set api.tls.enabled=true --set api.tls.existingSecret=ambari-api-tls \
    --set route.tls.mode=passthrough | pod_facts)
expect_equal "after the keystore conversion" "https-keystore seed-keys" \
    "$(sed -n 's/^init //p' <<<"$facts" | tr '\n' ' ' | sed 's/ $//')"

echo "==> no claim: refused unless acknowledged"
expect_refused "persistence off" "set persistence.acknowledgeEphemeral=true" --set persistence.enabled=false
expect_refused "persistence off, even with an existing claim named" "set persistence.acknowledgeEphemeral=true" \
    --set persistence.enabled=false --set persistence.existingClaim=ambari-data
expect_refused "persistence off, rendering only the claim" "set persistence.acknowledgeEphemeral=true" \
    --set persistence.enabled=false --show-only templates/pvc.yaml

echo "==> no claim, acknowledged: nothing mounted, and the notes warn"
out=$(render --set persistence.enabled=false --set persistence.acknowledgeEphemeral=true)
facts=$(pod_facts <<<"$out")
expect_absent "no claim" "pvc " "$facts"
expect_absent "no data volume" "volume " "$facts"
expect_absent "nothing mounted from it" "mount " "$facts"
expect_absent "nothing seeded" "init seed-keys" "$facts"
expect_absent "no keys/ mount at all" "mountPath: /var/lib/ambari-server/keys" "$out"
out=$(notes --set persistence.enabled=false --set persistence.acknowledgeEphemeral=true)
expect_contains "notes warn" "Data     : WARNING -- no claim (persistence.acknowledgeEphemeral=true)" "$out"
expect_contains "and say what is lost" "new KDPS internal CA" "$out"
facts=$(render --set persistence.enabled=false --set persistence.acknowledgeEphemeral=true \
    --set passwdShim.enabled=false | pod_facts)
expect_absent "no init containers left" "init " "$facts"

echo "==> the seed script, on local stand-ins for the image's keys/ and the claim's"
script=$(render | pod_facts | sed -n 's/^seed //p')
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/image/db/newcerts" "$work/claim"
echo "ca config" > "$work/image/ca.config"
echo "01" > "$work/image/db/serial"
: > "$work/image/db/index.txt"
echo "*" > "$work/image/db/newcerts/.gitignore"
echo "image password" > "$work/image/pass.txt"
seed() {
    sed -e "s#/var/lib/ambari-server/keys#$work/image#g" -e "s#/data/keys#$work/claim#g" <<<"$script" | sh
}

if out=$(seed 2>&1); then ok "first start: exits 0"; else not_ok "first start: exited non-zero: $out"; fi
expect_contains "first start: says what the claim holds" "keys/ on the claim holds: ca.config db pass.txt" "$out"
for f in ca.config pass.txt db/serial db/index.txt db/newcerts/.gitignore; do
    if [ -f "$work/claim/$f" ]; then ok "first start: $f copied"; else not_ok "first start: $f missing"; fi
done

# What the server and the view wrote since, and a file a later image ships.
echo "the server's own password" > "$work/claim/pass.txt"
echo "02" > "$work/claim/db/serial"
echo "the credential store" > "$work/claim/credentials.jceks"
echo "a later image" > "$work/image/new-in-image.txt"
if out=$(seed 2>&1); then ok "next start: exits 0"; else not_ok "next start: exited non-zero: $out"; fi
expect_equal "next start: credential store kept" "the credential store" "$(cat "$work/claim/credentials.jceks")"
expect_equal "next start: pass.txt not replaced" "the server's own password" "$(cat "$work/claim/pass.txt")"
expect_equal "next start: db/serial not replaced" "02" "$(cat "$work/claim/db/serial")"
expect_equal "next start: a file only the image has is added" "a later image" "$(cat "$work/claim/new-in-image.txt")"

if [ "$FAILED" -ne 0 ]; then
    echo "ambari persistence checks FAILED"
    exit 1
fi
echo "ambari persistence checks passed"
