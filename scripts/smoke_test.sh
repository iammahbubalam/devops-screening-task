#!/usr/bin/env bash
#
# smoke_test.sh - start a container from IMAGE and check that it really works:
# it runs as a non-root user and "/" returns the expected JSON.
#
# Usage: scripts/smoke_test.sh <image>
#
# CI runs this on every build, and `make smoke` runs the same check locally.
# The container gets a host port other than 8080 so it does not collide with
# a stack started by `docker compose up`.

set -euo pipefail

readonly EXPECTED_BODY='{"message":"Hello from DevOps Intern Task!","status":"running"}'
readonly HOST_PORT="${HOST_PORT:-18080}"
readonly MAX_ATTEMPTS=10

die() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

main() {
  local image="${1:-}"
  [[ -n "$image" ]] || die "usage: ${0##*/} <image>"

  local container="smoke-test-$$"
  # Unquoted on purpose: expand $container now, while it is in scope.
  # shellcheck disable=SC2064
  trap "docker rm --force '$container' >/dev/null 2>&1 || true" EXIT

  local user
  user="$(docker image inspect --format '{{.Config.User}}' "$image")"
  [[ -n "$user" && "$user" != "root" && "${user%%:*}" != "0" ]] ||
    die "image runs as root (USER='$user')"
  echo "ok: image runs as user $user"

  docker run --detach --name "$container" \
    --read-only --cap-drop ALL --security-opt no-new-privileges:true \
    --publish "127.0.0.1:${HOST_PORT}:8080" \
    "$image" >/dev/null

  local body="" attempt
  for ((attempt = 1; attempt <= MAX_ATTEMPTS; attempt++)); do
    if body="$(curl --silent --fail --max-time 2 "http://127.0.0.1:${HOST_PORT}/")"; then
      break
    fi
    sleep 1
  done

  if [[ "$body" != "$EXPECTED_BODY" ]]; then
    docker logs "$container" >&2 || true
    die "GET / returned '${body}', want '${EXPECTED_BODY}'"
  fi
  echo "ok: GET / returned ${body}"
}

main "$@"
