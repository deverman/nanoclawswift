# NanoClawSwift Production + Refactor Plan (Dual View)

Updated: 2026-02-19

## Summary

This plan is intentionally dual-view:

1. Operator plan (readable for project ownership and execution tracking)
2. Implementation blueprint (detailed enough for direct engineering execution)

Primary objective:
- reach production-ready operational reliability
- reduce architectural complexity
- improve SOLID alignment without changing product scope (Telegram-first, MCP-first, multi-channel deferred)

---

## 1) Operator Plan (Readable View)

### Milestone A: Reliability Baseline Lock

Goal:
- freeze a release-candidate baseline before deeper refactor.

Actions:
1. Commit and tag current stable state.
2. Run production readiness checklist from `PRODUCTION_READINESS.md`.
3. Complete pending scheduler soak evidence from `IMPLEMENTATION_PLAN.md`.

Evidence required:
- `swift test` pass
- `swift run nanoclaw-devctl rebuild-and-restart slim` pass
- `swift run nanoclaw-hostctl status` healthy
- scheduler diagnostics and DB evidence captured
- Telegram smoke for `/tasks`, `/skills`, `/mcp-status`, pagination `/more`

Exit:
- baseline is reproducible and green.

### Milestone B: Runtime Simplification

Goal:
- reduce coupling and separate responsibilities in agent runtime.

Actions:
1. split intent routing, planning, execution, rendering, policy concerns.
2. enforce one unified tool contract for native + MCP + CLI tools.
3. move deterministic operations to explicit non-LLM path.

Exit:
- fewer loop overruns
- clearer error handling
- no behavior regressions.

### Milestone C: User-Facing Consistency

Goal:
- improve response quality and consistency in Telegram.

Actions:
1. centralize formatting for status/list/error/task responses.
2. keep MCP results human-readable by default.
3. standardize pagination continuation semantics.

Exit:
- no raw JSON leakage for normal user-facing MCP outputs
- stable page continuation behavior.

### Milestone D: Dependency and Release Hardening

Goal:
- ensure durable, reproducible builds and clear release decision.

Actions:
1. maintain pinned remote dependencies (Swarm/Conduit fork path currently active).
2. upstream forked fixes and repin to upstream revisions/tags when merged.
3. run final go/no-go checklist and publish decision.

Exit:
- clean-machine reproducibility
- final GO/NO-GO report completed.

---

## 2) Implementation Blueprint (Extended View)

## Target Runtime Decomposition

Refactor to pipeline:

`Inbound -> IntentResolver -> RunPlanner -> ToolExecutor -> ResponseRenderer -> ChannelAdapter`

Policy modules (separate units):
- `IterationPolicy`
- `RetryPolicy`
- `TimeoutPolicy`
- `ApprovalPolicy`
- `PaginationPolicy`

## Public Interfaces / Internal Contracts

Introduce or formalize:
1. `RunRequest`, `RunContext`, `RunResult`, `RunStopReason`
2. `IntentResolution`
   - `deterministicAction`
   - `llmRoute` (`toolCalling` / `planExecute`)
3. `ToolInvocationEnvelope`
4. `ToolResultEnvelope`
   - `structuredPayload`
   - `renderHints`
   - `paginationState`
5. `ResponseRenderable`
   - channel-specific rendering hooks
6. `PaginationSessionStore`
   - cursor ownership + TTL + stale handling

## File-Level Refactor Map

Primary extraction from:
- `Sources/NanoClawAgent/NanoClawAgent.swift`

New runtime modules:
1. `Sources/NanoClawAgent/Runtime/IntentResolver.swift`
2. `Sources/NanoClawAgent/Runtime/RunPlanner.swift`
3. `Sources/NanoClawAgent/Runtime/ToolExecutor.swift`
4. `Sources/NanoClawAgent/Runtime/ResponseRenderer.swift`
5. `Sources/NanoClawAgent/Runtime/PaginationSessionStore.swift`
6. `Sources/NanoClawAgent/Runtime/Policies/*`

Tool integration consolidation:
1. `Sources/NanoClawAgent/Tools/ToolRegistry.swift`
2. `Sources/NanoClawAgent/MCP/*` adapters return same envelope types
3. `Sources/NanoClawAgent/Tools/*` native tools return same envelope types

Context pipeline:
1. `Sources/NanoClawAgent/Runtime/ContextProviders/MemoryContextProvider.swift`
2. `Sources/NanoClawAgent/Runtime/ContextProviders/SkillsContextProvider.swift`
3. `Sources/NanoClawAgent/Runtime/ContextProviders/MCPRuntimeContextProvider.swift`

## Deterministic Intent Fast-Path Coverage

Keep explicit deterministic path for slash commands:
1. task operations (`/tasks`, `/schedule`, `/pause`, `/resume`, `/cancel`)
2. skill operations (`/skills`, `/reload-skills`)
3. MCP operations (`/mcp-status`, `/mcp-reload`, `/mcp-cli`)
4. pagination continuations (`/more`, `/more N`)

Rule:
- deterministic intents should not enter long multi-iteration LLM loop unless fallback is explicitly required.

## SOLID Refactor Rules

1. SRP: execution, rendering, routing, policy separated.
2. OCP: new tools/providers added via registry, not switch statements in core loop.
3. LSP: native/MCP/CLI tool adapters conform to same invocation/result contract.
4. ISP: narrow protocols for execution vs rendering vs pagination vs policy.
5. DIP: orchestrator depends on protocols, not transport/provider concretes.

## Testing Strategy

### Unit Tests

1. intent routing coverage:
   - deterministic path selection
   - fallback behavior
2. tool envelope conversion:
   - native/MCP/CLI parity
3. renderer formatting:
   - status/list/error/pagination
4. pagination store:
   - cursor lifecycle, TTL, stale invalidation
5. policy enforcement:
   - loop limits, retries, stop reasons

### Integration Tests

1. Telegram deterministic command latency/regression checks
2. MCP human-readable rendering tests
3. `/more` and `/more N` multi-page continuity
4. skill/memory context ordering + token budget clipping

### End-to-End Gates

1. `swift run nanoclaw-devctl rebuild-and-restart slim`
2. host health + scheduler diagnostics
3. Telegram smoke for ops + MCP paths
4. scheduled task advancement evidence in SQLite

## Acceptance Criteria

1. no iteration-exceeded failures for deterministic ops flows in regression suite
2. MCP outputs are human-readable by default in Telegram
3. scheduler proves due-task advancement across two consecutive cycles
4. dependency graph and runtime behavior are reproducible
5. production readiness gate remains green after refactor

## Rollout Sequence

1. lock baseline
2. extract runtime modules (no behavior change pass)
3. migrate deterministic intent logic
4. migrate unified tool result envelopes
5. migrate renderer/pagination to centralized layer
6. rerun full tests and smoke checks
7. publish go/no-go report

## Assumptions and Defaults

1. Telegram remains the only active channel in this milestone.
2. MCP remains prioritized before multi-channel work.
3. loop profile remains balanced default (`16/40/60`) unless validated data indicates adjustment.
4. `write_memory` remains side-effectful and approval-gated.
5. Apple Containers runtime model remains.
6. Swift Testing remains mandatory for regression coverage.
