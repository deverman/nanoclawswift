# Handover: Container 0.9.0 Runtime Status

## Snapshot

**Date**: 2026-02-06  
**CLI**: `container` 0.9.0  
**Host**: macOS 26.x

## What Was Verified

### 1. Core runtime works

- `container system status` reports API server running.
- `container run --rm docker.io/alpine:3.20 echo ok` succeeds.

### 2. Env passing with interactive stdin works in 0.9.0

Both commands below succeeded:

- `printf 'x' | container run -i --rm -e TEST_ENV=hello docker.io/alpine:3.20 sh -lc 'cat >/dev/null; echo TEST_ENV=$TEST_ENV'`
- `printf 'x' | container run -i --rm --env-file /tmp/container-env-test.env docker.io/alpine:3.20 sh -lc 'cat >/dev/null; echo TEST_ENV=$TEST_ENV'`

### 3. DNS option works

- `container run --rm --dns 8.8.8.8 docker.io/alpine:3.20 cat /etc/resolv.conf` showed `nameserver 8.8.8.8`.

## Local Host State (Current)

The previously observed stale digest metadata mismatch was repaired on this host.

- `container image ls` now succeeds.
- `container run` and env injection checks continue to pass.
- A runtime preflight now checks `container image inspect <CONTAINER_IMAGE>` and warns with recovery steps if `container image ls` reports digest metadata failures.

## Tailscale Interaction (Important)

On hosts where the default route is a `utun*` interface (for example Tailscale exit-node mode), Apple Container VM outbound internet may fail even when host internet works.

Observed pattern:

- Container DNS/egress to public LLM endpoints fails or times out.
- Container can still reach host-local addresses like `192.168.64.1`.

Runtime mitigation now in this repo:

- `src/container-runner.ts` auto-detects default route interface.
- In `CONTAINER_LLM_RELAY_MODE=auto` and no explicit `BASE_URL`, if default route is `utun*` it enables a host LLM relay and sets container `BASE_URL` to:
  - `http://192.168.64.1:18081/relay/openai/v1`
  - `http://192.168.64.1:18081/relay/kimi/v1`
  - `http://192.168.64.1:18081/relay/anthropic/v1`
- Relay DNS uses explicit resolvers (`CONTAINER_LLM_RELAY_DNS_SERVERS`, default `1.1.1.1,8.8.8.8`).

Operational knobs:

- `CONTAINER_LLM_RELAY_MODE=auto|force|off`
- `CONTAINER_LLM_RELAY_DNS_SERVERS=...`
- `CONTAINER_LLM_RELAY_PORT=18081`
- `CONTAINER_DNS_SERVERS=...`

Quick diagnostics:

- `npm run container:netcheck` (prints host default route, DNS chain, and container outbound probe)

## Code Changes Applied In This Repo

- Updated `/Users/deverman/Documents/Code/nanoclawswift/src/container-runner.ts` to generate a per-group env file under `data/env/` and pass it with `container run --env-file`.
- Removed the old mounted `env-dir` workaround path from runtime mounts.
- Added a container preflight in `/Users/deverman/Documents/Code/nanoclawswift/src/container-runner.ts` to fail fast if the configured image is missing and to surface digest-drift recovery guidance.
- Added Tailscale-aware relay fallback in `/Users/deverman/Documents/Code/nanoclawswift/src/container-runner.ts` for `utun` default-route environments.
- Added `/Users/deverman/Documents/Code/nanoclawswift/scripts/container-smoke.sh` and `npm run container:smoke` for repeatable runtime validation.

## Recommended Ongoing Maintenance Step (Host)

If digest metadata drift recurs:

1. Restart services: `container system stop && container system start`
2. Re-pull stale tags and re-check: `container image ls`
3. Re-run smoke validation: `npm run container:smoke`

## Notes

Previous docs that attributed all API failures to Apple Container DNS are outdated for 0.9.0 and should not be used for triage.
