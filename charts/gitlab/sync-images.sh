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
#   Source registries used here are public; no login needed.
#
# What this script does:
#   1. Copies GitLab CNG images          registry.gitlab.com/gitlab-org/build/cng → clemlabprojects/cng
#   2. Copies Bitnami legacy images      docker.io/bitnamilegacy → clemlabprojects/bitnamilegacy
#   3. Copies MinIO images               docker.io/minio → clemlabprojects/minio
#
# After this script completes, update Chart.yaml annotations.images with the
# exact digests for a fully reproducible offline install.
# ---------------------------------------------------------------------------
set -euo pipefail

DEST_REGISTRY="${DEST_REGISTRY:-${HARBOR_NS:-registry.clemlab.com/clemlabprojects}}"
GITLAB_VERSION="${GITLAB_VERSION:-v17.11.2}"
CNG_SRC="registry.gitlab.com/gitlab-org/build/cng"
BITNAMI_LEGACY_SRC="docker.io/bitnamilegacy"

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
  "gitlab-base:${GITLAB_VERSION}"
  "gitlab-webservice-ce:${GITLAB_VERSION}"
  "gitlab-workhorse-ce:${GITLAB_VERSION}"
  "gitlab-sidekiq-ce:${GITLAB_VERSION}"
  "gitlab-toolbox-ce:${GITLAB_VERSION}"
  "gitaly:${GITLAB_VERSION}"
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
GITLAB_EXPORTER_VERSION="${GITLAB_EXPORTER_VERSION:-15.3.0}"
KUBECTL_VERSION="${KUBECTL_VERSION:-${GITLAB_VERSION}}"
CERTS_VERSION="${CERTS_VERSION:-${GITLAB_VERSION}}"
CFSSL_VERSION="${CFSSL_VERSION:-${GITLAB_VERSION}}"

copy_image "${CNG_SRC}/gitlab-shell:${SHELL_VERSION}"             "${DEST_REGISTRY}/cng/gitlab-shell:${SHELL_VERSION}"
copy_image "${CNG_SRC}/gitlab-exporter:${GITLAB_EXPORTER_VERSION}" "${DEST_REGISTRY}/cng/gitlab-exporter:${GITLAB_EXPORTER_VERSION}"
copy_image "${CNG_SRC}/kubectl:${KUBECTL_VERSION}"                "${DEST_REGISTRY}/cng/kubectl:${KUBECTL_VERSION}"
copy_image "${CNG_SRC}/certificates:${CERTS_VERSION}"             "${DEST_REGISTRY}/cng/certificates:${CERTS_VERSION}"
copy_image "${CNG_SRC}/cfssl-self-sign:${CFSSL_VERSION}"          "${DEST_REGISTRY}/cng/cfssl-self-sign:${CFSSL_VERSION}"

# ---------------------------------------------------------------------------
# 2. Bitnami legacy images used by bundled PostgreSQL & Redis
#    Source:  docker.io/bitnamilegacy/<image>:<tag>
#    Dest:    registry.clemlab.com/clemlabprojects/bitnamilegacy/<image>:<tag>
# ---------------------------------------------------------------------------
echo "=== Bitnami legacy images (bundled PostgreSQL + Redis) ==="

POSTGRESQL_VERSION="${POSTGRESQL_VERSION:-14.8.0}"
POSTGRES_EXPORTER_VERSION="${POSTGRES_EXPORTER_VERSION:-0.14.0-debian-11-r2}"
REDIS_VERSION="${REDIS_VERSION:-7.2.4-debian-12-r9}"
REDIS_EXPORTER_VERSION="${REDIS_EXPORTER_VERSION:-1.58.0-debian-12-r4}"

copy_image "${BITNAMI_LEGACY_SRC}/postgresql:${POSTGRESQL_VERSION}" \
           "${DEST_REGISTRY}/bitnamilegacy/postgresql:${POSTGRESQL_VERSION}"
copy_image "${BITNAMI_LEGACY_SRC}/postgres-exporter:${POSTGRES_EXPORTER_VERSION}" \
           "${DEST_REGISTRY}/bitnamilegacy/postgres-exporter:${POSTGRES_EXPORTER_VERSION}"
copy_image "${BITNAMI_LEGACY_SRC}/redis:${REDIS_VERSION}" \
           "${DEST_REGISTRY}/bitnamilegacy/redis:${REDIS_VERSION}"
copy_image "${BITNAMI_LEGACY_SRC}/redis-exporter:${REDIS_EXPORTER_VERSION}" \
           "${DEST_REGISTRY}/bitnamilegacy/redis-exporter:${REDIS_EXPORTER_VERSION}"

# ---------------------------------------------------------------------------
# 3. MinIO (object storage — artifacts, LFS, uploads, packages)
#    Source:  docker.io/minio/<image>:<tag>
#    Dest:    registry.clemlab.com/clemlabprojects/minio/<image>:<tag>
#
#    MinIO tags use date-based release names. Pin the tag used by the chart:
#      helm show values gitlab/gitlab | grep -A2 minio
# ---------------------------------------------------------------------------
echo "=== MinIO ==="

MINIO_TAG="${MINIO_TAG:-RELEASE.2017-12-28T01-21-00Z}"
MC_TAG="${MC_TAG:-RELEASE.2018-07-13T00-53-22Z}"

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
