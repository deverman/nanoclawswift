# CronEngineKit

`CronEngineKit` is a standalone Swift library target that powers NanoClaw host scheduling.

## Design goals

- Small public API surface
- No project-specific dependencies
- Deterministic timezone-aware next-run calculation
- Easy extraction into a separate repository/package

## Public API

- `CronEngine` protocol
- `CronEngineError`
- `VixieCronEngine` (default implementation)

## Supported syntax

- 5-field cron: `minute hour day-of-month month day-of-week`
- Lists: `1,2,3`
- Ranges: `1-5`
- Steps: `*/15`, `1-30/2`
- Month names: `JAN..DEC`
- Weekday names: `SUN..SAT`
- Macros: `@yearly`, `@monthly`, `@weekly`, `@daily`, `@hourly`
- `?` in day-of-month/day-of-week (treated as wildcard)

## Non-goals

- Quartz-specific tokens such as `L`, `W`, `#`
- Seconds/year cron fields

## Extracting later

To publish as a separate package:

1. Move `Sources/CronEngineKit` and `Tests/CronEngineKitTests` into a new repo.
2. Add a standalone `Package.swift` with one library product.
3. Keep semantic-versioned tags for dependency consumers.
