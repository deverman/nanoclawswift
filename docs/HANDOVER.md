# Handover: Container 0.9.0 Runtime Status

## Snapshot

**Date**: 2026-02-06  
**CLI**: `container` 0.9.0  
**Host**: macOS 26.x

## Agent Runtime Migration Status (2026-02-11)

- `NanoClawAgent` now uses Swarm `ToolCallingAgent` as the single tool execution loop.
- Raw pseudo-tool blocks (for example ````tool ...````) are rejected by guardrails and never executed.
- `ArchivingHooks` remains as compatibility run-hook persistence for `.nanoclaw/archive`.
- Swarm `0.3.4` was evaluated but is currently blocked in this environment by an upstream transitive `Hive` package resolution failure (`/Package.swift` missing). Repo stays pinned to `0.3.1` until upstream fix.

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
- `nanoclaw-host` startup now performs stale `nanoclaw-*` container cleanup and logs session startup failures with daemon log tails.

## Tailscale Interaction (Important)

On hosts where the default route is a `utun*` interface (for example Tailscale exit-node mode), Apple Container VM outbound internet may fail even when host internet works.

Observed pattern:

- Container DNS/egress to public LLM endpoints fails or times out.
- Container can still reach host-local addresses like `192.168.64.1`.

Runtime mitigation now in this repo:

- `src/index.ts` starts `src/host-relay.ts` before launching `nanoclaw-host`.
- Adapter startup logs default route interface (`route -n get default`) and relay mode.
- In `CONTAINER_LLM_RELAY_MODE=auto` and no explicit `BASE_URL`, startup sets container `BASE_URL` to:
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

- Replaced one-shot Node container orchestration with Swift host orchestration:
  - `/Users/deverman/Documents/Code/nanoclawswift/Sources/NanoClawHost/NanoClawHostService.swift`
  - `/Users/deverman/Documents/Code/nanoclawswift/Sources/NanoClawHost/ContainerSessionManager.swift`
- Added Node channel adapter host bridge:
  - `/Users/deverman/Documents/Code/nanoclawswift/src/host-client.ts`
  - `/Users/deverman/Documents/Code/nanoclawswift/src/index.ts`
- Added host relay + web broker for container traffic:
  - `/Users/deverman/Documents/Code/nanoclawswift/src/host-relay.ts`
- Added Tailscale-aware relay bootstrap in adapter startup (`src/index.ts`) so `BASE_URL` and `NANOCLAW_WEB_BROKER_URL` are set before `nanoclaw-host` starts.
- Added `/Users/deverman/Documents/Code/nanoclawswift/scripts/container-smoke.sh` and `npm run container:smoke` for repeatable runtime validation.

## Recommended Ongoing Maintenance Step (Host)

If digest metadata drift recurs:

1. Restart services: `container system stop && container system start`
2. Re-pull stale tags and re-check: `container image ls`
3. Re-run smoke validation: `npm run container:smoke`

## Notes

Previous docs that attributed all API failures to Apple Container DNS are outdated for 0.9.0 and should not be used for triage.
