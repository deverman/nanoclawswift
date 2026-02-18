# NanoClawSwift Requirements

Updated: 2026-02-17

## Product Requirements

1. Swift is the source of truth for new runtime behavior.
2. Telegram is the only active channel in current milestone.
3. Agent execution runs inside Apple Container sessions.
4. Host runtime must support persistent queueing, scheduling, and session lifecycle recovery.
5. Tool invocation must be structured (no pseudo-tool text parsing).

## Capability Requirements

1. Continuous typing indicator for long-running requests.
2. Telegram-safe message splitting.
3. Multi-step execution via dual-route model (`ToolCallingAgent` and `PlanAndExecuteAgent`).
4. Skills lifecycle support (`list`, `activate`, `deactivate`, `sync`).
5. Parity tools (`todo_*`, `sub_agent`, `get_task_history`, `export_chat`).
6. Memory tools with chat/global scope (`read_memory`, `write_memory`).
7. `send_message` attachment support (path + caption).
8. MCP runtime integration with startup tool registration.

## Safety and Reliability Requirements

1. Side-effectful tools require approval/idempotency handling.
2. Provider request throttling must reduce sustained 429 risk.
3. Loop budgets must have hard ceilings and clear failure messaging.
4. Container watchdog/janitor/reaper controls must prevent stale-session deadlocks.
5. Startup catch-up should process missed scheduled tasks once after host restart.

## Testing Requirements

1. Regression coverage uses Swift Testing (`import Testing`).
2. New behavior is implemented tests-first where practical.
3. Coverage includes unit + integration surfaces for:
   - loop policies and retries
   - memory scopes and writes
   - attachment path safety and delivery queue
   - MCP parse/registration/error paths
   - Telegram runtime smoke paths

## Configuration Requirements

1. Swift runtime env/config reads use `swift-configuration` patterns.
2. `TELEGRAM_OWNER_ID` remains required for owner-gated direct messaging.
3. Runtime must tolerate optional fallback provider config for outage/rate-limit resilience.

## Deferred Requirements

1. Multi-channel expansion is deferred until after MCP stabilization.
2. Wax production backend decision is deferred pending compatibility packet.
