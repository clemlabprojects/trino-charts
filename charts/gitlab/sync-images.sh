#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# sync-images.sh — Mirror all GitLab CE chart images to registry.clemlab.com
#
# Usage:
#   ./sync-images.sh [OPTIONS]
#
# Options:
#   --dry-run     Print skopeo commands without executing them
#   --version V   Override GITLAB_VERSION (default: v17.11.2)
#   --help        Show this help
#
# Requirements:
#   skopeo >= 1.9  (dnf install skopeo / apt install skopeo)
#
# Authentication:
#   Log in to the destination registry before running:
#     skopeo login registry.clemlab.com -u <user> -p <token>
#   Source registries (gitlab, docker hub, minio) are public; no login needed.
#
# What this script does:
#   1. Copies GitLab CNG images          registry.gitlab.com/gitlab-org/build/cng → clemlabprojects/cng
#   2. Copies GitLab mirror images       registry.gitlab.com/gitlab-org/cloud-native/mirror → clemlabprojects/gitlab-mirror
#   3. Copies MinIO images               docker.io/minio → clemlabprojects/minio
#
# After this script completes, update Chart.yaml annotations.images with the
# exact digests for a fully reproducible offline install.
# ---------------------------------------------------------------------------
set -euo pipefail

DEST_REGISTRY="registry.clemlab.com/clemlabprojects"
GITLAB_VERSION="${GITLAB_VERSION:-v17.11.2}"
CNG_SRC="registry.gitlab.com/gitlab-org/build/cng"
MIRROR_SRC="registry.gitlab.com/gitlab-org/cloud-native/mirror"

DRY_RUN=false

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)   DRY_RUN=true; shift ;;
    --version)   GITLAB_VERSION="$2"; shift 2 ;;
    --help)
      sed -n '2,30p' "$0" | grep '^#' | sed 's/^# \?//'
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

echo "GitLab version : ${GITLAB_VERSION}"
echo "Destination    : ${DEST_REGISTRY}"
echo "Dry run        : ${DRY_RUN}"
echo ""

# ---------------------------------------------------------------------------
# Helper: copy one image, preserving all platform manifests (--all)
# ---------------------------------------------------------------------------
copy_image() {
  local src="$1"
  local dst="$2"
  echo "  ${src}"
  echo "  → ${dst}"
  if [[ "${DRY_RUN}" == "false" ]]; then
    skopeo copy --all \
      --retry-times 3 \
      "docker://${src}" \
      "docker://${dst}"
  fi
  echo ""
}

# ---------------------------------------------------------------------------
# 1. GitLab CNG images
#    Source:  registry.gitlab.com/gitlab-org/build/cng/<component>:<tag>
#    Dest:    registry.clemlab.com/clemlabprojects/cng/<component>:<tag>
# ---------------------------------------------------------------------------
echo "=== GitLab CNG images (${GITLAB_VERSION}) ==="

CNG_IMAGES=(
  "gitlab-webservice-ce:${GITLAB_VERSION}"
  "gitlab-workhorse-ce:${GITLAB_VERSION}"
  "gitlab-sidekiq-ce:${GITLAB_VERSION}"
  "gitlab-toolbox-ce:${GITLAB_VERSION}"
  "gitaly:${GITLAB_VERSION}"
  "gitlab-exporter:${GITLAB_VERSION}"
  "gitlab-pages:${GITLAB_VERSION}"
  "gitlab-kas:${GITLAB_VERSION}"
)

for img in "${CNG_IMAGES[@]}"; do
  name="${img%%:*}"
  tag="${img##*:}"
  copy_image "${CNG_SRC}/${img}" "${DEST_REGISTRY}/cng/${name}:${tag}"
done

# Shell and kubectl versions are independent of the GitLab release tag.
# Update these when upgrading the chart (check: helm show values gitlab/gitlab | grep -E 'shell|kubectl')
SHELL_VERSION="${SHELL_VERSION:-v14.42.0}"
KUBECTL_VERSION="${KUBECTL_VERSION:-v1.32.2-gitlab.1}"
CERTS_VERSION="${CERTS_VERSION:-20240705-r0}"
CFSSL_VERSION="${CFSSL_VERSION:-1.6.6}"

copy_image "${CNG_SRC}/gitlab-shell:${SHELL_VERSION}"             "${DEST_REGISTRY}/cng/gitlab-shell:${SHELL_VERSION}"
copy_image "${CNG_SRC}/kubectl:${KUBECTL_VERSION}"                "${DEST_REGISTRY}/cng/kubectl:${KUBECTL_VERSION}"
copy_image "${CNG_SRC}/alpine-certificates:${CERTS_VERSION}"      "${DEST_REGISTRY}/cng/alpine-certificates:${CERTS_VERSION}"
copy_image "${CNG_SRC}/cfssl-self-sign:${CFSSL_VERSION}"          "${DEST_REGISTRY}/cng/cfssl-self-sign:${CFSSL_VERSION}"

# ---------------------------------------------------------------------------
# 2. GitLab cloud-native mirror images (bundled PostgreSQL & Redis)
#    Source:  registry.gitlab.com/gitlab-org/cloud-native/mirror/<image>:<tag>
#    Dest:    registry.clemlab.com/clemlabprojects/gitlab-mirror/<image>:<tag>
# ---------------------------------------------------------------------------
echo "=== GitLab cloud-native mirror (bundled PostgreSQL + Redis) ==="

PG_VERSION="${PG_VERSION:-16.8}"
REDIS_VERSION="${REDIS_VERSION:-7.0.15}"

copy_image "${MIRROR_SRC}/postgresql:${PG_VERSION}"   "${DEST_REGISTRY}/gitlab-mirror/postgresql:${PG_VERSION}"
copy_image "${MIRROR_SRC}/redis:${REDIS_VERSION}"     "${DEST_REGISTRY}/gitlab-mirror/redis:${REDIS_VERSION}"

# ---------------------------------------------------------------------------
# 3. MinIO (object storage — artifacts, LFS, uploads, packages)
#    Source:  docker.io/minio/<image>:<tag>
#    Dest:    registry.clemlab.com/clemlabprojects/minio/<image>:<tag>
#
#    MinIO tags use date-based release names. Pin the tag used by the chart:
#      helm show values gitlab/gitlab | grep -A2 minio
# ---------------------------------------------------------------------------
echo "=== MinIO ==="

MINIO_TAG="${MINIO_TAG:-RELEASE.2024-07-04T14-25-45Z}"
MC_TAG="${MC_TAG:-RELEASE.2024-07-04T14-25-45Z}"

copy_image "docker.io/minio/minio:${MINIO_TAG}"   "${DEST_REGISTRY}/minio/minio:${MINIO_TAG}"
copy_image "docker.io/minio/mc:${MC_TAG}"          "${DEST_REGISTRY}/minio/mc:${MC_TAG}"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo "=== Sync complete ==="
echo ""
echo "Next steps:"
echo "  1. Verify images in Harbor: https://registry.clemlab.com/harbor/projects"
echo "  2. Update Chart.yaml annotations.images with digests for reproducible installs:"
echo "     skopeo inspect docker://<image> | jq .Digest"
echo "  3. Run: helm dependency update charts/gitlab && helm lint charts/gitlab"
