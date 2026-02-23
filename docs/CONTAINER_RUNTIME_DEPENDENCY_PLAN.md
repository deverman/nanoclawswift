# Container Runtime and Dependency Plan

Updated: 2026-02-19

## Purpose

Define a low-risk path to reduce dependency complexity while preserving runtime stability in the Swift-first host/agent architecture.

This plan addresses:
- Whether to replace `container` CLI orchestration with Apple `containerization` Swift APIs.
- Whether the `apple/containerization` package dependency should remain in `Package.swift`.
- How to avoid reinventing the wheel while keeping production behavior stable.

## Current State (Facts)

1. Runtime container lifecycle in host code is CLI-driven via `Process` and `container` commands:
   - `Sources/NanoClawHost/ContainerSessionManager.swift`
2. Requests are handled by long-running per-group container sessions with file IPC:
   - startup/stop/sweep use CLI
   - per-request path does not shell out to `container run`
3. `apple/containerization` is declared in root `Package.swift` but is not imported by app sources.
4. Host relay and MCP bridge behavior are currently stable and independent from direct Containerization APIs.

## Decision Summary

1. Keep CLI-based runtime orchestration for now.
2. Treat direct `containerization` API integration as a future optional migration, not a production-readiness blocker.
3. Plan to remove the unused `apple/containerization` Swift package dependency after a guarded validation pass.

Rationale:
- Immediate user-facing latency gains from switching to APIs are expected to be minimal because request handling already reuses long-running sessions.
- Rewriting lifecycle and VM/container controls to APIs introduces large migration surface and potential regressions.
- Dropping unused dependencies reduces build graph size and operational complexity.

## Goals

1. Reduce unnecessary dependency weight in the active build graph.
2. Preserve all current runtime behavior and diagnostics.
3. Create an abstraction seam so direct Containerization APIs can be added later without major rewrites.

## Non-Goals

1. No full rewrite of `ContainerSessionManager` to direct Containerization APIs in this milestone.
2. No change to Telegram/MCP feature scope.
3. No change to agent loop policy as part of this dependency task.

## Phased Plan

### Phase 1: Dependency Safety Audit (Non-breaking)

1. Confirm no compile-time imports of `Containerization` exist across source/test targets.
2. Record transitive dependency impact baseline (`swift package show-dependencies` snapshot).
3. Confirm runtime ownership boundaries:
   - host runtime still depends on external `container` CLI availability
   - no hidden coupling to Containerization Swift symbols

Deliverables:
- Audit note in `IMPLEMENTATION_PLAN.md` with evidence commands and findings.

### Phase 2: Remove Unused `apple/containerization` Dependency

1. Remove `.package(url: "https://github.com/apple/containerization.git", ...)` from root `Package.swift`.
2. Run `swift package resolve` and capture lockfile delta in `Package.resolved`.
3. Run test/build gates:
   - `swift test`
   - `swift build --product nanoclaw-host`
   - `swift build --product nanoclaw-agent`
4. Run runtime validation:
   - `swift run nanoclaw-devctl rebuild-and-restart slim`
   - `swift run nanoclaw-hostctl status`
  - Telegram smoke (`/tasks`, `/skills`, `/mcp-status`)

Exit criteria:
- All tests/builds pass.
- Runtime behaviors unchanged.
- No missing-symbol or startup regressions.

### Phase 3: Introduce Container Runtime Abstraction Seam

1. Add a protocol boundary for runtime operations (no behavior changes yet):
   - `ContainerRuntime` interface for start/stop/remove/list operations.
2. Implement `ContainerCLIRuntime` as the default production implementation.
3. Move direct `Process` command wiring behind this interface.

Expected benefit:
- Enables future migration to `Containerization` APIs without rewriting business logic.

### Phase 4: Optional Spike — Direct Containerization APIs

Only run if Phase 2 and 3 are stable and there is a clear need (not speculative).

1. Build a prototype `ContainerizationRuntime` behind the same interface.
2. Scope to parity subset only:
   - start long-running process
   - stop/remove
   - list/sweep support
   - mount/env parity
3. Compare vs CLI on:
   - startup reliability
   - error quality
   - operational complexity
   - measurable latency impact

Decision gate:
- Keep CLI if gains are marginal.
- Promote API runtime only if reliability/maintainability materially improve.

## Test Plan

### Unit

1. `ContainerRuntime` contract tests:
   - start/stop/remove/list semantics
   - deterministic container naming and sweep planner behavior
2. Error mapping tests:
   - CLI exit/status -> typed host errors
   - ensure logs include actionable context

### Integration

1. Host startup with prewarm enabled.
2. Request flow through existing file IPC and watchdog.
3. Stale session sweep and cleanup behavior.
4. MCP host bridge still reachable after restart.

### End-to-End

1. `nanoclaw-devctl rebuild-and-restart slim` completes cleanly.
2. Telegram commands respond with no regression:
   - `/tasks`
   - `/skills`
   - `/mcp-status`
3. Scheduled task loop still advances `next_run`.

## Risks and Mitigations

1. Risk: Hidden dependency on `containerization` package.
   - Mitigation: full compile/test/runtime gate before merge.
2. Risk: Runtime instability from refactor churn.
   - Mitigation: phase separation and no behavior changes in Phase 3.
3. Risk: Over-architecture.
   - Mitigation: keep abstraction thin and CLI-first until clear data supports API migration.

## Rollback Plan

1. If Phase 2 fails, restore removed package dependency in `Package.swift` and rerun resolve/build.
2. If Phase 3 causes regressions, revert abstraction commit and keep current direct CLI wiring.
3. Do not proceed to Phase 4 unless all Phase 2/3 gates pass.

## Acceptance Criteria

1. `apple/containerization` removed from active root dependencies without regressions.
2. Full test + runtime gates pass using existing CLI-driven behavior.
3. `ContainerRuntime` seam in place with default CLI implementation.
4. Production readiness checklist remains green after change.

## Commands Reference

1. Dependency graph:
   - `swift package show-dependencies --format text`
2. Resolve and build:
   - `swift package resolve`
   - `swift test`
   - `swift build --product nanoclaw-host`
   - `swift build --product nanoclaw-agent`
3. Runtime validation:
   - `swift run nanoclaw-devctl rebuild-and-restart slim`
   - `swift run nanoclaw-hostctl status`
   - `swift run nanoclaw-hostctl scheduler-diagnostics`
