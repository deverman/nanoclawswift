# Telegram Integration Status

## Current State (2026-02-06)

### Working

1. Telegram bot connectivity and owner-only gating are implemented.
2. Message routing to registered Telegram direct chat is implemented.
3. Container invocation path for the Swift agent is wired.

### Updated Container Findings

Container runtime is not globally broken:

- `container run` works on this host.
- Env injection with `-i` works with both `-e` and `--env-file` in `container` 0.9.0.
- `--dns` is applied correctly in runtime tests.

### Local Host Stability

The previously observed local image metadata/content-store mismatch was mitigated.

- `container image ls` succeeds on current host state.
- Startup now uses Swift host session management (`Sources/NanoClawHost/ContainerSessionManager.swift`) with stale-container cleanup on boot and per-group daemon logs.

### Tailscale + Container Networking Findings

Observed on this host:

- Default route is via `utun` (`route -n get default` -> `interface: utun41`).
- In this mode, `container` VMs can reach the local gateway (`192.168.64.1`) but outbound internet egress can fail intermittently or completely.
- This impacted direct LLM API calls from inside the container.

Mitigation now implemented in runtime:

- `src/index.ts` boots `src/host-relay.ts`, reports default-route interface, and configures relay/web-broker environment for `nanoclaw-host` before host startup.
- `nanoclaw-host` passes `BASE_URL`/`NANOCLAW_WEB_BROKER_URL` into long-running container sessions.
- Relay DNS resolution uses explicit resolvers (`1.1.1.1,8.8.8.8` by default) to avoid split-DNS surprises from tunnel-scoped resolvers.
- If upstream returns non-200, relay returns a JSON completion-shaped fallback so the Swift agent does not crash in provider error paths.

Relevant env knobs:

- `CONTAINER_LLM_RELAY_MODE=auto|force|off` (default: `auto`; `BASE_URL` is set to relay when unset, or always in `force`)
- `CONTAINER_LLM_RELAY_DNS_SERVERS=1.1.1.1,8.8.8.8`
- `CONTAINER_LLM_RELAY_HOST=192.168.64.1`
- `CONTAINER_LLM_RELAY_PORT=18081`
- `CONTAINER_DNS_SERVERS=8.8.8.8` (or comma-separated list)

## Practical Next Checks For Telegram Failures

1. Verify model/provider env values are present for the host process.
2. Verify container image exists and runs directly with a minimal prompt.
3. Verify per-group mounts and IPC directories are created and writable.
4. Inspect `groups/telegram-direct/logs/daemon-*.log` for long-running container agent stderr/output.
5. Run `npm run container:smoke` when suspecting container runtime regressions.
6. Run `npm run container:netcheck` to confirm route/DNS/egress behavior under VPN/Tailscale.
7. If Tailscale exit-node mode is enabled, verify app setting "Allow LAN access" and/or disable exit node for direct container egress tests.

## Conclusion

Telegram integration is now robust against common Tailscale/`utun` egress failures via host relay fallback, but host VPN policy still determines whether direct container egress is possible.
