#!/usr/bin/env bash

# Render-only checks (no cluster needed) for who can reach the Ambari console and how its traffic is encrypted:
# networkPolicy admits the router's or ingress controller's namespaces and the configured address ranges, to the
# server's port only, and never everybody; an empty route.tls.mode follows api.tls.enabled, so a server serving HTTPS
# gets a Route that passes TLS through (or re-encrypts it when given the CA) rather than a refusal; an Ingress sends
# the traffic to the port the server listens on; and the release notes say when the last hop is plain HTTP or any
# pod can connect.

set -euo pipefail

CHART="$(cd "$(dirname "$0")/../../charts/ambari" && pwd)"
NAMESPACE=kdps
FAILED=0

COMMON=(--namespace "$NAMESPACE" --set database.host=postgres.example.svc --set database.password=changeme
        --set masterKey.value=a-master-key --set adminPassword.existingSecret=ambari-admin
        --set route.host=ambari.apps.example.com)
API_TLS=(--set api.tls.enabled=true --set api.tls.existingSecret=ambari-api-tls)
OPENSHIFT=(--api-versions route.openshift.io/v1)
INGRESS=(--set route.enabled=false --set ingress.enabled=true --set ingress.host=ambari.example.com)

render() {
    helm template ambari "$CHART" "${COMMON[@]}" "$@"
}

# The release notes, which helm template does not print. Rendered client-side; the Ingress shape is used where the
# notes are checked, so that what they say does not depend on the API groups of whatever cluster is configured.
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

# Absent as a whole line, for a needle that is also the beginning of another fact.
expect_no_line() {
    local label=$1 line=$2 text=$3
    if grep -qxF -- "$line" <<<"$text"; then not_ok "$label: did not expect the line '$line'"; else ok "$label"; fi
}

expect_refused() {
    local label=$1 needle=$2 out
    shift 2
    if out=$(render "$@" 2>&1); then
        not_ok "$label: rendered"
    elif grep -qF -- "$needle" <<<"$out"; then
        ok "$label"
    else
        not_ok "$label: refused, but without '$needle': $out"
    fi
}

# What the rendered manifests say about reaching the server, one line per fact, read with a YAML parser:
#   policy <name> types <types> pods <selector labels>
#   rules <n>                      the number of ingress rules of the NetworkPolicy
#   from-empty                     a rule without peers, which would admit every pod in the cluster
#   peer ns <k=v,...>              a namespaceSelector peer
#   peer cidr <cidr>               an ipBlock peer
#   peer other <json>              any other peer
#   port <protocol> <port>         a port a rule admits
#   route <termination> <target port> <has destinationCACertificate>
#   ingress-backend <port name>
reach_facts() {
    python3 -c '
import json, sys, yaml
for d in yaml.safe_load_all(sys.stdin):
    if not d:
        continue
    kind, spec = d["kind"], d.get("spec", {})
    if kind == "NetworkPolicy":
        pods = ",".join("%s=%s" % kv for kv in sorted(spec["podSelector"]["matchLabels"].items()))
        print("policy", d["metadata"]["name"], "types", ",".join(spec["policyTypes"]), "pods", pods)
        rules = spec.get("ingress") or []
        print("rules", len(rules))
        for r in rules:
            if not r.get("from"):
                print("from-empty")
            for p in r.get("from", []):
                if set(p) == {"namespaceSelector"}:
                    print("peer ns", ",".join("%s=%s" % kv for kv in sorted(p["namespaceSelector"]["matchLabels"].items())))
                elif set(p) == {"ipBlock"}:
                    print("peer cidr", p["ipBlock"]["cidr"])
                else:
                    print("peer other", json.dumps(p, sort_keys=True))
            for p in r.get("ports", []):
                print("port", p["protocol"], p["port"])
    if kind == "Route":
        tls = spec["tls"]
        print("route", tls["termination"], spec["port"]["targetPort"], "destinationCACertificate" in tls)
    if kind == "Ingress":
        for rule in spec["rules"]:
            for p in rule["http"]["paths"]:
                print("ingress-backend", p["backend"]["service"]["port"]["name"])
'
}

echo "==> defaults: no NetworkPolicy, and the notes say so"
facts=$(render | reach_facts)
expect_absent "no NetworkPolicy" "policy " "$facts"
out=$(notes "${INGRESS[@]}")
expect_contains "notes warn that any pod can connect" \
    "WARNING -- any pod in the cluster can connect to the server (networkPolicy.enabled=false)" "$out"

echo "==> networkPolicy.enabled: the OpenShift routers only, to the HTTP port"
facts=$(render --set networkPolicy.enabled=true | reach_facts)
expect_contains "a policy for the server's pod, on incoming traffic only" \
    "policy ambari types Ingress pods app.kubernetes.io/instance=ambari,app.kubernetes.io/name=ambari" "$facts"
expect_contains "one rule" "rules 1" "$facts"
expect_contains "the OVN-Kubernetes router namespaces" "peer ns policy-group.network.openshift.io/ingress=" "$facts"
expect_contains "the OpenShift SDN router namespaces" "peer ns network.openshift.io/policy-group=ingress" "$facts"
expect_absent "no address range" "peer cidr" "$facts"
expect_contains "to the port the server listens on" "port TCP http" "$facts"
expect_no_line "not the HTTPS port, which nothing listens on" "port TCP https" "$facts"

echo "==> with api.tls, the policy admits the HTTPS port"
facts=$(render --set networkPolicy.enabled=true "${API_TLS[@]}" | reach_facts)
expect_contains "the HTTPS port" "port TCP https" "$facts"
expect_no_line "not the plain one" "port TCP http" "$facts"

echo "==> address ranges, an ingress controller's namespace and verbatim peers"
facts=$(render --set networkPolicy.enabled=true \
    --set 'networkPolicy.ingressNamespaceSelectors[0].kubernetes\.io/metadata\.name=ingress-nginx' \
    --set 'networkPolicy.allowedCIDRs={10.20.0.0/16,192.168.10.5/32}' \
    --set 'networkPolicy.extraFrom[0].namespaceSelector.matchLabels.team=platform' \
    --set 'networkPolicy.extraFrom[0].podSelector.matchLabels.app=bastion' | reach_facts)
expect_contains "the named namespace" "peer ns kubernetes.io/metadata.name=ingress-nginx" "$facts"
expect_absent "in place of the OpenShift defaults" "peer ns policy-group" "$facts"
expect_contains "the first range" "peer cidr 10.20.0.0/16" "$facts"
expect_contains "the second range" "peer cidr 192.168.10.5/32" "$facts"
expect_contains "the verbatim peer, as it is" \
    'peer other {"namespaceSelector": {"matchLabels": {"team": "platform"}}, "podSelector": {"matchLabels": {"app": "bastion"}}}' \
    "$facts"
out=$(notes "${INGRESS[@]}" --set networkPolicy.enabled=true \
    --set 'networkPolicy.ingressNamespaceSelectors[0].kubernetes\.io/metadata\.name=ingress-nginx' \
    --set 'networkPolicy.allowedCIDRs={10.20.0.0/16}')
expect_contains "notes name the policy and the port" "NetworkPolicy ambari admits connections to port http only from" "$out"
expect_contains "notes name the namespaces" "namespaces labelled kubernetes.io/metadata.name=ingress-nginx" "$out"
expect_contains "notes name the range" "10.20.0.0/16" "$out"
expect_absent "notes no longer warn" "any pod in the cluster can connect" "$out"

echo "==> no peer at all: the policy admits nobody, never everybody"
facts=$(render --set networkPolicy.enabled=true --set 'networkPolicy.ingressNamespaceSelectors=null' | reach_facts)
expect_contains "the policy is there" "policy ambari" "$facts"
expect_contains "with no rule" "rules 0" "$facts"
expect_absent "and no rule without peers" "from-empty" "$facts"
out=$(notes "${INGRESS[@]}" --set networkPolicy.enabled=true --set 'networkPolicy.ingressNamespaceSelectors=null')
expect_contains "notes say only port-forward reaches it" "admits no connection at all" "$out"
expect_refused "an empty label set, which would match every namespace, is refused" \
    "an empty selector matches every namespace" \
    --set networkPolicy.enabled=true --set 'networkPolicy.ingressNamespaceSelectors[0]=null'

echo "==> the Route follows api.tls when route.tls.mode is empty"
facts=$(render "${OPENSHIFT[@]}" | reach_facts)
expect_contains "plain server: edge, to the HTTP port" "route edge http False" "$facts"
facts=$(render "${OPENSHIFT[@]}" "${API_TLS[@]}" | reach_facts)
expect_contains "HTTPS server: passed through, to the HTTPS port" "route passthrough https False" "$facts"
facts=$(render "${OPENSHIFT[@]}" "${API_TLS[@]}" \
    --set-string 'route.tls.destinationCACertificate=-----BEGIN CERTIFICATE-----' | reach_facts)
expect_contains "HTTPS server and its CA: re-encrypted, verified" "route reencrypt https True" "$facts"
facts=$(render "${OPENSHIFT[@]}" "${API_TLS[@]}" --set route.tls.mode=reencrypt | reach_facts)
expect_contains "an explicit mode is kept" "route reencrypt https False" "$facts"
facts=$(render "${OPENSHIFT[@]}" --set route.tls.mode=edgeWithCert | reach_facts)
expect_contains "edgeWithCert is still the router's own TLS" "route edge http False" "$facts"
expect_refused "an edge Route in front of an HTTPS-only server is still refused" \
    "route.tls.mode must be reencrypt or passthrough" "${API_TLS[@]}" --set route.tls.mode=edge
expect_refused "passthrough to a plain server is still refused" \
    "route.tls.mode=passthrough needs the server to serve TLS" --set route.tls.mode=passthrough
expect_refused "a misspelt mode is refused" "route.tls.mode must be edge, edgeWithCert, passthrough or reencrypt" \
    --set route.tls.mode=Edge

echo "==> the Ingress sends the traffic to the port the server listens on"
facts=$(render "${INGRESS[@]}" | reach_facts)
expect_contains "plain server: HTTP" "ingress-backend http" "$facts"
facts=$(render "${INGRESS[@]}" "${API_TLS[@]}" | reach_facts)
expect_contains "HTTPS server: HTTPS" "ingress-backend https" "$facts"
out=$(notes "${INGRESS[@]}")
expect_contains "notes warn that the last hop is plain HTTP" \
    "from the ingress controller to the pod the traffic is plain HTTP" "$out"
out=$(notes "${INGRESS[@]}" "${API_TLS[@]}")
expect_contains "notes say how the controller must speak to an HTTPS server" \
    "nginx.ingress.kubernetes.io/backend-protocol: HTTPS" "$out"
expect_absent "and do not warn" "traffic is plain HTTP" "$out"

if [ "$FAILED" -ne 0 ]; then
    echo "ambari network and TLS checks FAILED"
    exit 1
fi
echo "ambari network and TLS checks passed"
