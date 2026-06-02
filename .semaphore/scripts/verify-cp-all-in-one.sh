#!/usr/bin/env bash
#
# Smoke-test the PR-built docker images by booting cp-all-in-one with them and
# polling control-center, prometheus, and alertmanager for HTTP 200.
#
# Addresses MMA-17737 / INC-6655 by automating the manual screenshot step in
# .github/PULL_REQUEST_TEMPLATE.md.
#
# Usage:
#   verify-cp-all-in-one.sh up    # clone, sed-patch, compose up, poll healthchecks
#   verify-cp-all-in-one.sh down  # tear down (run in always-epilogue) — dumps
#                                 # ps + per-service logs, then `compose down -v`.
#
# Required env vars (exported by the global Semaphore prologue):
#   DOCKER_DEV_REGISTRY  e.g. 519856050701.dkr.ecr.us-west-2.amazonaws.com/docker/dev/
#   DOCKER_DEV_TAG       e.g. dev-2.3.x-327c2d06
#   AMD_ARCH             e.g. .amd64

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
# If neither exists, fails loudly (exit 1) rather than silently testing against
# cp-all-in-one master — testing C3 images against a non-matching CP version
# would give a misleading verification signal.
resolve_branch() {
  local cp_version="$1"
  local cp_post="${cp_version}-post"
  local cp_x
  cp_x="$(echo "$cp_version" | grep -oE '^[0-9]+\.[0-9]+').x"

  if git ls-remote --exit-code --heads "$CP_ALL_IN_ONE_REPO" "$cp_post" >/dev/null 2>&1; then
    echo "$cp_post"
  elif git ls-remote --exit-code --heads "$CP_ALL_IN_ONE_REPO" "$cp_x" >/dev/null 2>&1; then
    echo "$cp_x"
  else
    echo "ERROR: Neither '$cp_post' nor '$cp_x' exists on $CP_ALL_IN_ONE_REPO." >&2
    echo "       Coordinate with cp-all-in-one maintainers to create a branch" >&2
    echo "       matching CP $cp_version before this PR can be verified." >&2
    return 1
  fi
}

# Patch an image ref in docker-compose.yml from the upstream public repo to
# the PR's dev ECR URL. Fails loudly (exit 1) if either:
#   - the expected upstream image ref isn't present in the compose file
#     (cp-all-in-one upstream may have renamed/removed the service)
#   - the substitution doesn't land (the regex matched something we didn't
#     expect, or sed silently no-op'd)
# Without these asserts, a non-matching sed would silently leave the
# upstream image in place and the smoke test would falsely pass against
# images this PR didn't build.
patch_image() {
  local image_repo="$1"          # e.g. "confluentinc/cp-enterprise-prometheus"
  local replacement_url="$2"     # full dev ECR URL with tag

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

cmd_up() {
  local repo_root="$PWD"
  local cp_version branch
  cp_version=$(derive_cp_version "$repo_root/pom.xml")
  if [ -z "$cp_version" ]; then
    echo "Could not derive CP version from $repo_root/pom.xml parent.version"
    exit 1
  fi

  # `set -e` doesn't propagate command-substitution failure into a bare assignment,
  # so we use `if !` to explicitly catch a non-zero exit from resolve_branch.
  if ! branch=$(resolve_branch "$cp_version"); then
    exit 1
  fi
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

  patch_image "confluentinc/cp-enterprise-control-center-next-gen" "$dev_c3"
  patch_image "confluentinc/cp-enterprise-prometheus"               "$dev_prom"
  patch_image "confluentinc/cp-enterprise-alertmanager"             "$dev_am"

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