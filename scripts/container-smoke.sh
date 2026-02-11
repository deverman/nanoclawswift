#!/usr/bin/env bash
set -euo pipefail

IMAGE="${CONTAINER_IMAGE:-nanoclawswift-agent:slim}"
ALPINE_IMAGE="${NANOCLAW_SMOKE_ALPINE_IMAGE:-docker.io/alpine:3.20}"

echo "[container-smoke] Checking container system status..."
container system status >/dev/null

echo "[container-smoke] Verifying configured image exists: ${IMAGE}"
container image inspect "${IMAGE}" >/dev/null

echo "[container-smoke] Checking image store metadata..."
if ! container image ls >/dev/null; then
  echo "[container-smoke] ERROR: 'container image ls' failed (possible stale digest metadata)."
  echo "[container-smoke] Recovery: restart services and re-pull stale image tags."
  exit 1
fi

echo "[container-smoke] Verifying --env-file with -i runtime behavior..."
tmp_env="$(mktemp)"
trap 'rm -f "${tmp_env}"' EXIT
printf 'NANOCLAW_SMOKE=ok\n' > "${tmp_env}"

output="$(container run --rm -i --env-file "${tmp_env}" "${ALPINE_IMAGE}" sh -lc 'cat >/dev/null; echo "NANOCLAW_SMOKE=$NANOCLAW_SMOKE"' <<<"x")"
if [[ "${output}" != "NANOCLAW_SMOKE=ok" ]]; then
  echo "[container-smoke] ERROR: env-file + interactive check failed. Output: ${output}"
  exit 1
fi

echo "[container-smoke] PASS"
