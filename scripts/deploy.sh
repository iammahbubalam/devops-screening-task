#!/usr/bin/env bash
#
# deploy.sh - runs ON THE SERVER. Starts one image tag with Docker Compose,
# waits until the container is healthy, and goes back to the previous tag if
# it never becomes healthy.
#
# Usage (from the folder that holds docker-compose.yml):
#   IMAGE_REPO=docker.io/user/devops-screening-task IMAGE_TAG=sha-abc1234 ./deploy.sh
#
# Variables:
#   IMAGE_REPO  image to run, without a tag                 (required)
#   IMAGE_TAG   tag to deploy                               (required)
#   HOST_PORT   server port that maps to the app            (default: 80)
#
# State: after a successful deploy the three values are saved to .env next to
# docker-compose.yml. That file is how a failed deploy knows which tag to roll
# back to, and it lets you run `docker compose ps` or `logs` on the server
# without setting anything.
#
# Exit status: 0 deployed, 1 failed. A failed deploy rolls back when an earlier
# release exists. Note: Compose replaces the single container, so each deploy
# causes a few seconds of downtime.
#
# Requires: Docker Engine 24+ with the Compose plugin (v2.17+ for --wait).

set -euo pipefail

# The image's own health check decides "healthy". Docker 24 runs the first
# check after one 30 s interval, so allow plenty of time.
readonly WAIT_TIMEOUT_SECONDS=90

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

validate_config() {
  [[ -n "${IMAGE_REPO:-}" ]] || die "IMAGE_REPO is required"
  [[ -n "${IMAGE_TAG:-}" ]] || die "IMAGE_TAG is required"
  HOST_PORT="${HOST_PORT:-80}"

  # These values end up in .env and in image names, so accept only what
  # Docker itself allows.
  [[ "$IMAGE_REPO" =~ ^[a-z0-9][a-z0-9._:/-]*$ ]] ||
    die "IMAGE_REPO '$IMAGE_REPO' is not a valid image name"
  [[ "$IMAGE_TAG" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] ||
    die "IMAGE_TAG '$IMAGE_TAG' is not a valid tag"
  if [[ ! "$HOST_PORT" =~ ^[1-9][0-9]{0,4}$ ]] || ((HOST_PORT > 65535)); then
    die "HOST_PORT must be a number from 1 to 65535, got '$HOST_PORT'"
  fi
  [[ -f docker-compose.yml ]] || die "docker-compose.yml not found in $PWD"
  command -v docker >/dev/null || die "docker is not installed"
}

# Tag of the last successful deploy, or nothing on the first deploy.
read_previous_tag() {
  if [[ -f .env ]]; then
    sed -n 's/^IMAGE_TAG=//p' .env
  fi
}

save_state() {
  printf 'IMAGE_REPO=%s\nIMAGE_TAG=%s\nHOST_PORT=%s\n' \
    "$IMAGE_REPO" "$IMAGE_TAG" "$HOST_PORT" >.env.tmp
  mv .env.tmp .env
}

# Delete older tags of this image. The new tag and the previous one stay, so
# a rollback never needs to download anything.
prune_old_images() {
  local previous="$1" tag
  while read -r tag; do
    if [[ "$tag" == "$IMAGE_TAG" || "$tag" == "$previous" || "$tag" == "<none>" ]]; then
      continue
    fi
    docker image rm "${IMAGE_REPO}:${tag}" >/dev/null 2>&1 || true
  done < <(docker image ls "$IMAGE_REPO" --format '{{.Tag}}')
}

wait_until_healthy() {
  docker compose up --detach --remove-orphans --wait --wait-timeout "$WAIT_TIMEOUT_SECONDS"
}

main() {
  cd "$(dirname "${BASH_SOURCE[0]}")"
  validate_config

  # Exported so Compose reads them from the environment, which takes priority
  # over .env. That keeps .env unchanged until the new release is proven.
  export IMAGE_REPO IMAGE_TAG HOST_PORT

  local previous
  previous="$(read_previous_tag)"
  printf 'Deploying %s:%s (previous release: %s)\n' "$IMAGE_REPO" "$IMAGE_TAG" "${previous:-none}"

  # A failed pull (wrong tag, registry down) stops here, before the running
  # container is touched.
  docker compose pull --quiet || die "could not pull ${IMAGE_REPO}:${IMAGE_TAG}; the running release was not changed"

  if wait_until_healthy; then
    save_state
    prune_old_images "$previous"
    docker compose ps
    printf 'Deployed %s\n' "$IMAGE_TAG"
    return 0
  fi

  printf 'ERROR: %s did not become healthy. Last container logs:\n' "$IMAGE_TAG" >&2
  docker compose logs --tail 30 >&2 || true

  if [[ -z "$previous" || "$previous" == "$IMAGE_TAG" ]]; then
    die "no earlier release to roll back to"
  fi
  printf 'Rolling back to %s\n' "$previous" >&2
  if IMAGE_TAG="$previous" wait_until_healthy; then
    die "deploy of $IMAGE_TAG failed; rolled back to $previous"
  fi
  die "deploy of $IMAGE_TAG failed and rollback to $previous failed too; check the server"
}

main "$@"
