# Telegram Runtime Status

Updated: 2026-02-17

## Current State

Telegram runtime is Swift-native and active.

Implemented:

1. Inbound polling adapter in Swift host.
2. Outbound queue delivery via Swift Telegram adapter.
3. Continuous typing heartbeat lifecycle.
4. Message splitting for Telegram message limits.
5. Task commands (schedule/list/pause/resume/cancel).
6. Skills and parity tools exposed through agent tool catalog.
7. Provider throttle controls to reduce 429 bursts.

## Known Constraints

1. Direct message access is owner-gated by `TELEGRAM_OWNER_ID`.
2. Scheduled tasks run only when host runtime is active (with startup catch-up for misses).
3. Provider/API rate limits can still occur during burst traffic.

## Recommended Validation Commands

```bash
swift run nanoclaw-hostctl status
tail -n 200 /tmp/nanoclaw-host.log
swift run nanoclaw-devctl verify-telegram-soak --since-minutes 15 --min-events 1
```
