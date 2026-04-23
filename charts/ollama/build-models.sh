#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# build-models.sh — Build and push Ollama model seeder images to the
#                   clemlab registry for air-gapped Kubernetes deployments.
#
# A "model seeder" image is an ollama/ollama image with models pre-pulled
# into /root/.ollama/models at build time.  When deployed as a Kubernetes
# initContainer it copies the model blobs to the Ollama PVC before the
# main server starts, so no internet access is needed at runtime.
#
# Usage:
#   ./build-models.sh [OPTIONS]
#
# Options:
#   --model MODEL    Ollama model to bake in  (default: sqlcoder:7b)
#                    May be specified multiple times for multiple models.
#   --ollama-tag V   Base ollama/ollama tag   (default: 0.5.13)
#   --registry R     Destination registry     (default: registry.clemlab.com/clemlabprojects)
#   --dry-run        Print commands without executing
#   --help
#
# Examples:
#   ./build-models.sh
#   ./build-models.sh --model sqlcoder:7b --model llama3.1:8b
#   ./build-models.sh --model sqlcoder:7b --dry-run
#
# Requirements:
#   docker >= 20 with buildx  (multi-arch support)
#   docker login registry.clemlab.com
#
# Output image tag pattern:
#   <registry>/ollama/ollama-models:<model-slug>-<ollama-tag>
#   e.g. registry.clemlab.com/clemlabprojects/ollama/ollama-models:sqlcoder-7b-0.5.13
#
# NOTE: Model weights are the same GGUF blobs across CPU architectures.
# We build a multi-arch image (amd64 + arm64) so the seeder works on both.
# The build must run on a machine with internet access (or a build cache).
# ---------------------------------------------------------------------------
set -euo pipefail

REGISTRY="${REGISTRY:-registry.clemlab.com/clemlabprojects}"
OLLAMA_TAG="${OLLAMA_TAG:-0.5.13}"
DRY_RUN=false
MODELS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model)      MODELS+=("$2"); shift 2 ;;
    --ollama-tag) OLLAMA_TAG="$2"; shift 2 ;;
    --registry)   REGISTRY="$2";  shift 2 ;;
    --dry-run)    DRY_RUN=true;   shift ;;
    --help)
      sed -n '2,30p' "$0" | grep '^#' | sed 's/^# \?//'
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# Default: just sqlcoder:7b (the SQL Assistant default model)
if [[ ${#MODELS[@]} -eq 0 ]]; then
  MODELS=("sqlcoder:7b")
fi

BASE_IMAGE="${REGISTRY}/ollama/ollama:${OLLAMA_TAG}"

run() {
  echo "  $ $*"
  [[ "${DRY_RUN}" == "false" ]] && "$@"
}

echo "========================================================="
echo " Ollama model seeder image builder"
echo "  Base image  : ${BASE_IMAGE}"
echo "  Models      : ${MODELS[*]}"
echo "  Dry run     : ${DRY_RUN}"
echo "========================================================="
echo ""

for MODEL in "${MODELS[@]}"; do
  # Sanitize model name to a valid Docker tag component (replace : and / with -)
  MODEL_SLUG="${MODEL//[:\/ ]/-}"
  DEST_TAG="${REGISTRY}/ollama/ollama-models:${MODEL_SLUG}-${OLLAMA_TAG}"

  echo "--- Building seeder for model: ${MODEL} ---"
  echo "    Destination: ${DEST_TAG}"
  echo ""

  TMPDIR="$(mktemp -d)"
  trap 'rm -rf "${TMPDIR}"' EXIT

  # Write a temporary Dockerfile for this model
  cat > "${TMPDIR}/Dockerfile" <<EOF
FROM ${BASE_IMAGE}
# Pull the model at build time so it is embedded in the image layer.
# The RUN layer will contain /root/.ollama/models/{blobs,manifests}.
RUN ollama serve & \\
    SERVER_PID=\$! && \\
    echo "Waiting for Ollama to start..." && \\
    sleep 10 && \\
    ollama pull ${MODEL} && \\
    echo "Model pulled successfully." && \\
    kill \$SERVER_PID && \\
    wait \$SERVER_PID 2>/dev/null || true
EOF

  echo "    Dockerfile:"
  sed 's/^/      /' "${TMPDIR}/Dockerfile"
  echo ""

  # Build multi-arch and push in one step via buildx
  run docker buildx build \
    --platform linux/amd64,linux/arm64 \
    --push \
    -t "${DEST_TAG}" \
    "${TMPDIR}"

  echo ""
  echo "  Pushed: ${DEST_TAG}"
  echo ""
done

echo "========================================================="
echo " Done. Add the seeder image to your values.yaml:"
echo ""
for MODEL in "${MODELS[@]}"; do
  MODEL_SLUG="${MODEL//[:\/ ]/-}"
  DEST_TAG="${REGISTRY}/ollama/ollama-models:${MODEL_SLUG}-${OLLAMA_TAG}"
  echo "  models:"
  echo "    pull: []          # disable online pull"
  echo "    seederImage: \"${DEST_TAG}\""
  echo ""
done
echo "========================================================="
