#!/usr/bin/env bash

# Checks for the gate that holds the ambari chart back from release until its appVersion names an
# ambari-kdps image whose entrypoint does what the chart relies on
# (.github/scripts/ambari-image-supported.sh). Both release workflows ask it, so a gate that waves an
# old image through releases a chart whose pod never becomes Ready.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GATE="$ROOT/.github/scripts/ambari-image-supported.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILED=0

ok() { echo "ok   - $1"; }
not_ok() { echo "FAIL - $1"; FAILED=1; }

# The chart's own Chart.yaml with its appVersion line replaced by $1.
chart_with() {
    mkdir -p "$WORK/ambari"
    sed "s/^appVersion:.*/$1/" "$ROOT/charts/ambari/Chart.yaml" > "$WORK/ambari/Chart.yaml"
}

expect_released() {
    local label=$1 out
    chart_with "$2"
    if out=$("$GATE" "$WORK/ambari" 2>&1); then ok "$label"; else not_ok "$label: held back: $out"; fi
}

expect_held() {
    local label=$1 needle=$3 out
    chart_with "$2"
    if out=$("$GATE" "$WORK/ambari" 2>&1); then
        not_ok "$label: released: $out"
    elif grep -qF -- "$needle" <<<"$out"; then
        ok "$label"
    else
        not_ok "$label: held back, but not with '$needle': $out"
    fi
}

echo "==> an image without the entrypoint the chart relies on holds the chart back"
expect_held "the last image without it" 'appVersion: "2.8.2.0-160"' \
    "Set appVersion to an image built after 2.8.2.0-160 from the current entrypoint"
expect_held "an earlier build, compared as a number" 'appVersion: "2.8.2.0-99"' "appVersion 2.8.2.0-99 is an ambari-kdps image"
expect_held "an earlier release" "appVersion: '2.8.1.0-300'" "appVersion 2.8.1.0-300 is an ambari-kdps image"
expect_held "no appVersion at all" '# no appVersion' "has no appVersion"

echo "==> a later image releases it"
expect_released "the next build" 'appVersion: "2.8.2.0-161"'
expect_released "a later build, compared as a number" 'appVersion: 2.8.2.0-1000'
expect_released "a later release" "appVersion: '2.8.3.0-1'"

if [ "$FAILED" -ne 0 ]; then
    echo "release gate checks FAILED"
    exit 1
fi
echo "release gate checks passed"
