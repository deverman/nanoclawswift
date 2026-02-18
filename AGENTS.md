# Repository Agent Rules

## Primary Direction
- Swift is the source of truth for all new runtime behavior.
- Prefer implementing orchestration, channel behavior, and tool/runtime logic in Swift targets.

## TypeScript/Node Constraints
- Do not add new product features in TypeScript unless explicitly requested by the user for a temporary bridge.
- If a temporary TypeScript bridge is unavoidable, mark it as transitional and create a Swift replacement step in `IMPLEMENTATION_PLAN.md` in the same change.
- No new long-lived control loops (retry loops, heartbeats, routing policy, approval policy) in TypeScript.

## Testing Policy
- Use Swift Testing (`import Testing`) for regression coverage of behavior.
- TypeScript tests are allowed only for existing adapter compatibility surfaces that have not yet been migrated.

## Configuration Policy
- Use Apple's `swift-configuration` package (`Configuration`, `ConfigReader`, `EnvironmentVariablesProvider`) for configuration and environment variable access in Swift code.
- Do not add new direct `ProcessInfo.processInfo.environment` reads in runtime code.
- If an availability fallback is required, isolate it inside a small configuration loader instead of spreading raw environment access throughout the codebase.

## Migration Hygiene
- Prefer moving behavior to Swift first, then deleting equivalent TypeScript paths in the same or immediately-following step.
- Keep architecture channel-extensible, but implement only Telegram behavior until further notice.

## Container Rebuild and Restart Policy
- If a code change touches `Sources/NanoClawAgent/**` or container build/runtime files (`container/**`, `Package.swift`, `Package.resolved`), rebuild the container image before Telegram/runtime validation:
  - `swift run nanoclaw-devctl build-agent-image slim`
- If a code change touches host runtime behavior (`Sources/NanoClawHost/**`), restart `nanoclaw-host` before validation:
  - `swift run nanoclaw-hostctl restart`
- For end-to-end behavior changes that involve both host and agent paths, do both: rebuild image and restart host.
- Preferred single command for end-to-end runtime updates:
  - `swift run nanoclaw-devctl rebuild-and-restart slim`
- Use serialized `nanoclaw-devctl` flows (or run commands sequentially) to avoid concurrent SwiftPM build-db contention.
- Do not claim a runtime fix is validated until the required rebuild/restart steps above have been completed.
