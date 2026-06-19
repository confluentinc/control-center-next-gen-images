#!/usr/bin/env bash
#
# Smoke-test PR-built docker images by booting cp-all-in-one with them and
# polling control-center, prometheus, and alertmanager for HTTP 200.
#
# Usage: verify-cp-all-in-one.sh up | down
#
# Required env: DOCKER_DEV_REGISTRY, DOCKER_DEV_TAG, AMD_ARCH

set -euo pipefail

AIO_DIR=/tmp/cp-all-in-one
AIO_COMPOSE_DIR="$AIO_DIR/cp-all-in-one"
CP_ALL_IN_ONE_REPO=https://github.com/confluentinc/cp-all-in-one.git
HEALTH_TIMEOUT_TRIES=60
HEALTH_TIMEOUT_SLEEP=10

derive_cp_version() {
  local pom="$1"
  local parent_version
  parent_version=$(awk '/<parent>/,/<\/parent>/' "$pom" \
    | sed -nE 's|.*<version>([^<]+)</version>.*|\1|p' \
    | head -1)
  echo "$parent_version" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

# Resolve to the highest <X.Y.Z>-post branch <= the target CP version. The
# released -post branches pin real published images; cp-all-in-one's master
# and .x branches reference unpublished <line>.x-latest tags and don't work,
# so we always fall back to the closest released line. Echoes empty if none.
resolve_branch() {
  local target="$1" best="" v
  while read -r v; do
    [ -z "$v" ] && continue
    if [ "$(printf '%s\n%s\n' "$v" "$target" | sort -V | head -1)" = "$v" ]; then
      best="$v"
    fi
  done < <(git ls-remote --heads "$CP_ALL_IN_ONE_REPO" \
    | sed -nE 's#.*refs/heads/([0-9]+\.[0-9]+\.[0-9]+)-post$#\1#p' | sort -V)
  [ -n "$best" ] && echo "${best}-post"
}

# Asserts catch silent zero-match seds — a no-op sed would leave the public
# image in place and falsely pass the test.
patch_image() {
  local image_repo="$1"
  local replacement_url="$2"

  if ! grep -qE "^[[:space:]]*image:[[:space:]]*${image_repo}:" docker-compose.yml; then
    echo "ERROR: docker-compose.yml has no image ref for '${image_repo}'." >&2
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

  branch=$(resolve_branch "$cp_version")
  if [ -z "$branch" ]; then
    echo "ERROR: no <X.Y.Z>-post branch <= CP $cp_version found on $CP_ALL_IN_ONE_REPO"
    exit 1
  fi
  echo "Using cp-all-in-one branch: $branch (target CP $cp_version, from pom.xml parent.version)"

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