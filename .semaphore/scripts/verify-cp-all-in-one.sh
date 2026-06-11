#!/usr/bin/env bash
#
# Smoke-test the PR-built docker images by booting cp-all-in-one with them and
# polling control-center, prometheus, and alertmanager for HTTP 200.
#
# Addresses MMA-17737 / INC-6655 by automating the manual screenshot step in
# .github/PULL_REQUEST_TEMPLATE.md.
#
# Exit code contract (the semaphore.yml wrapper translates these):
#   0   verification ran and passed
#   1   verification ran and failed (real regression — pipeline shows FAILED)
#   88  "nothing to verify yet" — no matching cp-all-in-one branch, or
#       platform images not in internal ECR. The wrapper turns this into
#       SEMAPHORE_JOB_RESULT=stopped + return 130 so the Semaphore UI shows
#       the block as Stopped (not Passed — avoids false-positive green).
#
# The Semaphore block is structured to depend on the last publish block, so
# by the time we run there is nothing in-flight for fail_fast to cancel.
#
# Usage:
#   verify-cp-all-in-one.sh up    # clone, sed-patch, compose up, poll healthchecks
#   verify-cp-all-in-one.sh down  # tear down (run in always-epilogue) — dumps
#                                 # ps + per-service logs, then `compose down -v`.
#
# Required env vars (exported by the global Semaphore prologue):
#   DOCKER_DEV_REGISTRY   e.g. 519856050701.dkr.ecr.us-west-2.amazonaws.com/docker/dev/
#   DOCKER_PROD_REGISTRY  e.g. 519856050701.dkr.ecr.us-west-2.amazonaws.com/docker/prod/
#   DOCKER_DEV_TAG        e.g. dev-2.3.x-327c2d06
#   AMD_ARCH              e.g. .amd64

set -euo pipefail

AIO_DIR=/tmp/cp-all-in-one
AIO_COMPOSE_DIR="$AIO_DIR/cp-all-in-one"
CP_ALL_IN_ONE_REPO=https://github.com/confluentinc/cp-all-in-one.git
HEALTH_TIMEOUT_TRIES=60
HEALTH_TIMEOUT_SLEEP=10

# Derive the CP version from this repo's pom.xml parent <version>.
# Example: "[8.0.4-0, 8.0.5-0)"  ->  "8.0.4"
derive_cp_version() {
  local pom="$1"
  local parent_version
  parent_version=$(awk '/<parent>/,/<\/parent>/' "$pom" \
    | sed -nE 's|.*<version>([^<]+)</version>.*|\1|p' \
    | head -1)
  echo "$parent_version" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

# Resolve a cp-all-in-one branch for a given CP version.
# Preference: "<cp>-post" (released-patch pin) > "<cp major.minor>.x" (active-dev).
# Returns the branch name on stdout, or empty string if neither branch exists
# (caller treats empty as a soft-skip — too early in the CP release cycle).
resolve_branch() {
  local cp_version="$1"
  local cp_post="${cp_version}-post"
  local cp_x
  cp_x="$(echo "$cp_version" | grep -oE '^[0-9]+\.[0-9]+').x"

  if git ls-remote --exit-code --heads "$CP_ALL_IN_ONE_REPO" "$cp_post" >/dev/null 2>&1; then
    echo "$cp_post"
  elif git ls-remote --exit-code --heads "$CP_ALL_IN_ONE_REPO" "$cp_x" >/dev/null 2>&1; then
    echo "$cp_x"
  fi
  # else: silent, empty stdout, caller soft-skips
}

# Check whether the internal ECR prod registry has the <line>.x-latest-ubi9
# multi-arch manifests for all four CP platform images we will sed-patch.
# Returns 0 if every probe succeeds. On failure, echoes a space-separated list
# of missing image names to stdout and returns 1.
ecr_has_cp_line_images() {
  local cp_line="$1"  # e.g. "8.3"
  local tag="${cp_line}.x-latest-ubi9"
  local missing=()
  local img url
  for img in cp-server cp-kafka-rest cp-ksqldb-server cp-schema-registry; do
    url="${DOCKER_PROD_REGISTRY}confluentinc/${img}:${tag}"
    if ! docker manifest inspect "$url" >/dev/null 2>&1; then
      missing+=("$img")
    fi
  done
  if [ ${#missing[@]} -gt 0 ]; then
    echo "${missing[*]}"
    return 1
  fi
}

# Patch an image ref in docker-compose.yml from the upstream public repo to a
# substitute URL. Fails loudly (exit 1) if either:
#   - the expected upstream image ref isn't present in the compose file
#     (cp-all-in-one upstream may have renamed/removed the service)
#   - the substitution doesn't land (the regex matched something we didn't
#     expect, or sed silently no-op'd)
# Without these asserts, a non-matching sed would silently leave the upstream
# image in place and the smoke test would falsely pass against images this PR
# didn't build.
patch_image() {
  local image_repo="$1"          # e.g. "confluentinc/cp-enterprise-prometheus"
  local replacement_url="$2"     # full registry URL with tag

  if ! grep -qE "^[[:space:]]*image:[[:space:]]*${image_repo}:" docker-compose.yml; then
    echo "ERROR: docker-compose.yml has no image ref for '${image_repo}'." >&2
    echo "       cp-all-in-one upstream may have renamed or removed this service." >&2
    exit 1
  fi
  sed -i -E "s|image:[[:space:]]*${image_repo}:[^[:space:]]+|image: ${replacement_url}|g" docker-compose.yml
  if ! grep -qF "${replacement_url}" docker-compose.yml; then
    echo "ERROR: sed substitution for '${image_repo}' did not land in docker-compose.yml." >&2
    exit 1
  fi
}

# Print a loud SKIP banner. Used when there's nothing meaningful to verify yet
# (no matching cp-all-in-one branch, or no published CP platform images for
# this CP line).
skip_banner() {
  local reason="$1"
  echo ""
  echo "================================================================================"
  echo "SKIP: cp-all-in-one verification cannot run yet"
  echo "  reason: $reason"
  echo "  this is non-blocking: image publish/promote continues normally"
  echo "================================================================================"
}

cmd_up() {
  local repo_root="$PWD"
  local cp_version cp_line branch
  cp_version=$(derive_cp_version "$repo_root/pom.xml")
  if [ -z "$cp_version" ]; then
    echo "Could not derive CP version from $repo_root/pom.xml parent.version"
    exit 1
  fi
  cp_line="$(echo "$cp_version" | grep -oE '^[0-9]+\.[0-9]+')"

  branch=$(resolve_branch "$cp_version")
  if [ -z "$branch" ]; then
    skip_banner "no -post or ${cp_line}.x cp-all-in-one branch exists for CP $cp_version yet (likely too early in the CP release cycle)"
    # Sentinel exit code 88 signals "skip" to the wrapper in semaphore.yml,
    # which translates it into SEMAPHORE_JOB_RESULT=stopped so the block
    # shows as Stopped (not Passed) in the UI — no false-positive green.
    exit 88
  fi

  # For .x dev branches, cp-all-in-one's compose pins CP platform services to
  # <line>.x-latest tags which only exist in the internal Confluent ECR (not
  # public Docker Hub). Probe all 4 platform images we will sed-patch; if any
  # are missing, skip non-fatally with the specific missing names called out.
  case "$branch" in
    *.x)
      local missing_imgs
      # `set -e` doesn't propagate cmd-sub failure into a bare assignment, so
      # use `if !` to catch a non-zero exit from ecr_has_cp_line_images.
      if ! missing_imgs=$(ecr_has_cp_line_images "$cp_line"); then
        skip_banner "cp-all-in-one '${branch}' exists but these ${cp_line}.x-latest-ubi9 images aren't in ${DOCKER_PROD_REGISTRY} yet: ${missing_imgs}"
        exit 88
      fi
      ;;
  esac

  echo "Using cp-all-in-one branch: $branch (CP_VERSION=$cp_version, from pom.xml parent.version)"

  local arch_tag="-ubi9${AMD_ARCH}"
  local dev_c3="${DOCKER_DEV_REGISTRY}confluentinc/cp-enterprise-control-center-next-gen:${DOCKER_DEV_TAG}${arch_tag}"
  local dev_prom="${DOCKER_DEV_REGISTRY}confluentinc/cp-enterprise-prometheus:${DOCKER_DEV_TAG}${arch_tag}"
  local dev_am="${DOCKER_DEV_REGISTRY}confluentinc/cp-enterprise-alertmanager:${DOCKER_DEV_TAG}${arch_tag}"
  echo "Using PR-built images:"
  echo "  C3:   $dev_c3"
  echo "  PROM: $dev_prom"
  echo "  AM:   $dev_am"

  rm -rf "$AIO_DIR"
  git clone --depth 1 -b "$branch" "$CP_ALL_IN_ONE_REPO" "$AIO_DIR"
  cd "$AIO_COMPOSE_DIR"

  # Always: redirect the 3 enterprise images to the PR's dev ECR build.
  patch_image "confluentinc/cp-enterprise-control-center-next-gen" "$dev_c3"
  patch_image "confluentinc/cp-enterprise-prometheus"               "$dev_prom"
  patch_image "confluentinc/cp-enterprise-alertmanager"             "$dev_am"

  # On .x dev branches only: cp-all-in-one's compose references CP platform
  # tags that don't exist on Docker Hub (e.g. cp-server:8.3.x-latest). Redirect
  # those to the equivalent <line>.x-latest-ubi9 multi-arch manifests in
  # internal ECR, which the agent is already authed to.
  if [[ "$branch" == *.x ]]; then
    local prod_tag="${cp_line}.x-latest-ubi9"
    echo "Dev branch detected — also redirecting CP platform images to internal ECR (${prod_tag})"
    patch_image "confluentinc/cp-server"          "${DOCKER_PROD_REGISTRY}confluentinc/cp-server:${prod_tag}"
    patch_image "confluentinc/cp-kafka-rest"      "${DOCKER_PROD_REGISTRY}confluentinc/cp-kafka-rest:${prod_tag}"
    patch_image "confluentinc/cp-ksqldb-server"   "${DOCKER_PROD_REGISTRY}confluentinc/cp-ksqldb-server:${prod_tag}"
    patch_image "confluentinc/cp-schema-registry" "${DOCKER_PROD_REGISTRY}confluentinc/cp-schema-registry:${prod_tag}"
  fi

  echo "Patched image refs:"
  grep -E "^[[:space:]]*image:" docker-compose.yml

  docker compose pull
  docker compose up -d

  echo "Waiting up to $((HEALTH_TIMEOUT_TRIES * HEALTH_TIMEOUT_SLEEP / 60)) minutes for control-center, prometheus, and alertmanager to become healthy..."
  local healthy=0 c3 prom am
  for i in $(seq 1 "$HEALTH_TIMEOUT_TRIES"); do
    c3=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:9021/ || true)
    prom=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:9090/-/ready || true)
    am=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:9093/-/ready || true)
    echo "[try $i] control-center=${c3:-000} prometheus=${prom:-000} alertmanager=${am:-000}"
    if [ "$c3" = "200" ] && [ "$prom" = "200" ] && [ "$am" = "200" ]; then
      healthy=1
      break
    fi
    sleep "$HEALTH_TIMEOUT_SLEEP"
  done
  if [ "$healthy" != "1" ]; then
    echo "Verification failed: services did not all become healthy within the timeout."
    exit 1
  fi
  echo "Verification passed: control-center, prometheus, and alertmanager are healthy."
}

cmd_down() {
  if [ ! -d "$AIO_COMPOSE_DIR" ]; then
    echo "cp-all-in-one compose dir not found, nothing to tear down"
    return 0
  fi
  cd "$AIO_COMPOSE_DIR"
  echo "=== docker compose ps ==="
  docker compose ps || true
  echo "=== control-center logs ==="
  docker compose logs --no-color --tail=300 control-center || true
  echo "=== prometheus logs ==="
  docker compose logs --no-color --tail=100 prometheus || true
  echo "=== alertmanager logs ==="
  docker compose logs --no-color --tail=100 alertmanager || true
  docker compose down -v || true
}

case "${1:-}" in
  up) cmd_up ;;
  down) cmd_down ;;
  *) echo "usage: $0 up|down" >&2; exit 2 ;;
esac