#!/usr/bin/env bash

# Render-only checks (no cluster needed) for the OpenMetadata credentials: with the Secrets the KDPS view generates,
# the server and both bundled PostgreSQL databases read their passwords from them, the Airflow administrator and the
# server share one password, the basic-auth administrators get theirs from a Secret, and no well-known password
# ("openmetadata", "airflow_pass", "admin") is rendered.

set -euo pipefail

CHART="$(cd "$(dirname "$0")/../../charts/openmetadata" && pwd)"
FAILED=0

render() {
    helm template om "$CHART" --namespace meta "$@"
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

# The documents rendered from one template (a path under the chart, sub-charts included).
documents_of() {
    local template=$1 text=$2
    awk -v source="$template" '
        /^---/ { if (index(doc, "# Source: " source "\n")) printf "%s", doc; doc = ""; next }
        { doc = doc $0 "\n" }
        END { if (index(doc, "# Source: " source "\n")) printf "%s", doc }
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

# What the KDPS view sends: the names of the Secrets it generated, never their content.
KDPS_ARGS=(
    --set dependencies.enabled=true
    --set 'openmetadata.config.authorization.adminPrincipals[0]=admin\,alice'
    --set postgresql.auth.existingSecret=om-openmetadata-db
    --set openmetadata.config.authorization.adminPassword.existingSecret=om-openmetadata-admin
    --set openmetadata.config.pipelineServiceClientConfig.auth.existingSecret=om-airflow-admin
    --set dependencies.airflow.postgresql.auth.existingSecret=om-airflow-db
    --set dependencies.airflow.data.metadataSecretName=om-airflow-db
    --set dependencies.airflow.webserver.defaultUser.password=
    --set 'dependencies.airflow.createUserJob.env[0].name=AIRFLOW_ADMIN_PASSWORD'
    --set 'dependencies.airflow.createUserJob.env[0].valueFrom.secretKeyRef.name=om-airflow-admin'
    --set 'dependencies.airflow.createUserJob.env[0].valueFrom.secretKeyRef.key=password'
)

echo "==> chart defaults: unchanged wiring, no administrator password Job"
out=$(render --set dependencies.enabled=true)
server=$(documents_of openmetadata/templates/deployment.yaml "$out")
expect_count "server reads the bundled PostgreSQL's own Secret" "name: om-postgresql" 3 "$server"
expect_absent "no Airflow password env without a Secret" "AIRFLOW_PASSWORD" "$server"
expect_absent "no administrator password Job" "om-openmetadata-admin-password" "$out"

echo "==> KDPS Secrets: every password is read from them"
out=$(render "${KDPS_ARGS[@]}")
server=$(documents_of openmetadata/templates/deployment.yaml "$out")
expect_count "server, migrate and auth sync read the generated database Secret" "name: om-openmetadata-db" 3 "$server"
expect_absent "server no longer reads the sub-chart's Secret" "name: om-postgresql" "$server"
expect_contains "Airflow account of the server" 'name: "om-airflow-admin"' "$(grep -A4 -- '- name: AIRFLOW_PASSWORD' <<<"$server")"
expect_contains "Airflow user name of the server" 'value: "admin"' "$(grep -A1 -- '- name: AIRFLOW_USERNAME' <<<"$server")"
expect_absent "no db-password in the credentials Secret" "db-password" "$(documents_of openmetadata/templates/secret-credentials.yaml "$out")"
expect_contains "OpenMetadata PostgreSQL reads the generated Secret" "secretName: om-openmetadata-db" \
    "$(documents_of openmetadata/charts/postgresql/templates/primary/statefulset.yaml "$out")"
expect_absent "OpenMetadata PostgreSQL Secret not rendered" "# Source: openmetadata/charts/postgresql/templates/secrets.yaml" "$out"
expect_contains "Airflow PostgreSQL reads the generated Secret" "secretName: om-airflow-db" \
    "$(documents_of openmetadata/charts/dependencies/charts/airflow/charts/postgresql/templates/primary/statefulset.yaml "$out")"
expect_absent "Airflow connection Secret not rendered" "name: om-airflow-metadata" "$(documents_of_kind Secret "$out")"
expect_contains "Airflow reads its connection from the generated Secret" "name: om-airflow-db" \
    "$(documents_of openmetadata/charts/dependencies/charts/airflow/templates/scheduler/scheduler-deployment.yaml "$out")"
# airflow_pass and "openmetadata" (base64 in a Secret's data), the chart defaults of the two databases
for password in airflow_pass 'b3Blbm1ldGFkYXRh' 'YWlyZmxvd19wYXNz' 'password: "openmetadata"'; do
    expect_absent "well-known password $password not rendered" "$password" "$out"
done

echo "==> Airflow administrator: from the Secret, created then set, no fallback password in the pod spec"
job=$(documents_of openmetadata/charts/dependencies/charts/airflow/templates/jobs/create-user-job.yaml "$out")
expect_contains "password from AIRFLOW_ADMIN_PASSWORD" 'password="${AIRFLOW_ADMIN_PASSWORD:-}"' "$job"
expect_contains "the env var comes from the Secret" "name: om-airflow-admin" "$job"
expect_contains "an existing administrator gets the password too" 'airflow users reset-password -u "admin" -p "$password"' "$job"
expect_absent "no password in the arguments" "-p admin" "$job"

echo "==> basic authentication: a Job sets each bootstrap administrator's password from the Secret"
admin=$(documents_of openmetadata/templates/job-admin-password.yaml "$out")
expect_contains "post-install hook" '"helm.sh/hook": post-install' "$admin"
expect_absent "not after an upgrade by default" "post-upgrade" "$admin"
expect_contains "admin reset" 'reset-password -e "admin@${domain}" -p "$OM_ADMIN_PASSWORD"' "$admin"
expect_contains "alice reset" 'reset-password -e "alice@${domain}" -p "$OM_ADMIN_PASSWORD"' "$admin"
expect_contains "password from the Secret" 'name: "om-openmetadata-admin"' "$admin"
expect_contains "database password from the generated Secret" "name: om-openmetadata-db" "$admin"
expect_count "own name label on the Job and its pod" "app.kubernetes.io/name: openmetadata-admin-password" 2 "$admin"
if grep -qE '^\s+app.kubernetes.io/name: openmetadata$' <<<"$admin"; then
    echo "FAIL - the server's Service would select the Job's pod"; FAILED=1
else
    echo "ok   - the server's Service does not select the Job's pod"
fi
out=$(render "${KDPS_ARGS[@]}" --set openmetadata.config.authorization.adminPassword.resetOnUpgrade=true)
expect_contains "after an upgrade too with resetOnUpgrade" '"helm.sh/hook": post-install,post-upgrade' \
    "$(documents_of openmetadata/templates/job-admin-password.yaml "$out")"
for mode in ldap oidc; do
    out=$(render "${KDPS_ARGS[@]}" --set global.security.auth.mode=$mode)
    expect_absent "no administrator password Job with $mode" "job-admin-password.yaml" "$out"
done

echo "==> no two resources share a kind and a name"
out=$(render "${KDPS_ARGS[@]}")
dupes=$(awk '/^kind: /{k=$2} /^  name: /{if (k) {print k "/" $2; k=""}}' <<<"$out" | sort | uniq -d)
if [ -z "$dupes" ]; then echo "ok   - unique names"; else echo "FAIL - duplicated resources: $dupes"; FAILED=1; fi

if [ "$FAILED" -ne 0 ]; then
    echo "Some openmetadata credentials template tests failed."
    exit 1
fi
echo "All openmetadata credentials template tests passed."
