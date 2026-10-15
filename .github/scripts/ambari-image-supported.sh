#!/usr/bin/env bash

# Whether the ambari chart names, as its appVersion, an ambari-kdps image it can run on. The clean
# stop (stopTimeoutSeconds), the [ambari-audit] lines in the pod logs and the first administrator
# password (adminPassword) are done by the image's entrypoint, and ambari-kdps 2.8.2.0-160 and
# earlier do none of them. A chart released on one of them would promise all three in its notes and
# documentation while the pod does none -- and, since its readiness check waits for the password to
# be set, would never become Ready. So every workflow that releases the chart asks this first, and
# holds back this chart only, not the release of the others.
#
# Usage: ambari-image-supported.sh [chart directory]    (default: charts/ambari)
# Exits 0 when appVersion is later than LAST_UNSUPPORTED, and 1, saying why, otherwise.

set -euo pipefail

CHART_DIR="${1:-charts/ambari}"
# The last image whose entrypoint lacks something the chart relies on. Raise it when the chart starts
# relying on something the entrypoint has only just learnt to do.
LAST_UNSUPPORTED="2.8.2.0-160"

APP_VERSION=$(awk '/^appVersion:/ { v = $2; gsub(/["'\'']/, "", v); print v; exit }' "${CHART_DIR}/Chart.yaml")
if [ -z "${APP_VERSION}" ]; then
    echo "${CHART_DIR}/Chart.yaml has no appVersion: it has to name the ambari-kdps image the chart runs by default."
    exit 1
fi
NEWER=$(printf '%s\n%s\n' "${LAST_UNSUPPORTED}" "${APP_VERSION}" | sort -V | tail -n 1)
if [ "${APP_VERSION}" = "${LAST_UNSUPPORTED}" ] || [ "${NEWER}" != "${APP_VERSION}" ]; then
    echo "appVersion ${APP_VERSION} is an ambari-kdps image that neither stops the server cleanly, nor copies the audit log to the pod logs, nor sets the first administrator password. Set appVersion to an image built after ${LAST_UNSUPPORTED} from the current entrypoint, then release."
    exit 1
fi
echo "appVersion ${APP_VERSION} is later than ${LAST_UNSUPPORTED}"
