# Wax Memory Decision Packet

Updated: 2026-02-17

## Decision Scope

Determine whether to adopt Wax as the production memory backend for NanoClawSwift now, given the current runtime model:

- host on macOS 26
- agent in Linux container sessions
- memory tools (`read_memory`, `write_memory`) already shipping on `MemoryStore` abstraction

## Current Baseline

- Production backend: `FileMemoryStore`
- Chat scope path: `/workspace/group/.nanoclaw/memory/chat.md`
- Global scope path: `/workspace/shared-memory/global.md`
- Adapter seam already exists (`MemoryStore` protocol)

## Options Evaluated

1. Host-side Wax memory service + agent RPC bridge
2. Direct Wax runtime dependency in container agent
3. Stay on file backend until Wax Linux/runtime fit is proven

## Go/No-Go Criteria

1. Compile compatibility in this repo’s runtime targets
2. Startup overhead impact on request latency
3. Retrieval/write latency under realistic tool-call load
4. Operational complexity (new service/process/failure modes)
5. Testability with Swift Testing in current CI/runtime setup

## Assessment

### Option 1: Host-side Wax service

Pros:
- Keeps container agent simple
- Could leverage platform-native capabilities on host

Cons:
- Adds another runtime boundary and failure mode
- Requires new RPC contract and deployment lifecycle
- Increases operational complexity for limited immediate gain

Status: Not recommended for immediate rollout.

### Option 2: Direct Wax in container

Pros:
- Cleaner architecture if fully supported
- No extra host service boundary

Cons:
- Compatibility/runtime fit for Linux container path is not yet a confirmed low-risk drop-in for this project
- May introduce dependency and startup risk before parity goals are fully stabilized

Status: Not ready for production adoption now.

### Option 3: Keep file backend now (current)

Pros:
- Already implemented, stable, and tested
- Works in Linux container runtime today
- Preserves clear migration seam through `MemoryStore`

Cons:
- Less advanced retrieval semantics than potential Wax integration

Status: Recommended now.

## Decision

Use `FileMemoryStore` as production backend for this milestone. Keep Wax as a follow-up spike behind the existing `MemoryStore` seam.

## Trigger Conditions to Reopen

Re-open Wax adoption decision when all are true:

1. Verified compatibility with this repo’s runtime targets and CI.
2. No measurable startup regression in agent sessions.
3. End-to-end tests show stable read/write behavior under Telegram load.
4. Operational complexity is acceptable without reducing reliability.

## Implementation Impact

No runtime behavior changes required now.

- Existing memory tool APIs remain stable.
- Existing tests remain valid.
- Future backend swap can occur behind `MemoryStore` without changing tool contracts.
