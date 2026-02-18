#!/usr/bin/env bash
set -euo pipefail

ACTIVE_DOCS=(
  "README.md"
  "IMPLEMENTATION_PLAN.md"
  "PRODUCTION_READINESS.md"
  "docs/TELEGRAM_SETUP.md"
  "docs/SECURITY.md"
)

PATTERNS=(
  "whatsapp|baileys|grammy"
  "npm run dev"
  "src/telegram-bot\.ts"
  "src/whatsapp-auth\.ts"
  "build-swift\.sh"
  "scripts/download-linux-binary\.sh"
)

FAILED=0

for doc in "${ACTIVE_DOCS[@]}"; do
  if [[ ! -f "$doc" ]]; then
    echo "[docs-check] missing file: $doc"
    FAILED=1
    continue
  fi

  for pattern in "${PATTERNS[@]}"; do
    if rg -n -i "$pattern" "$doc" >/tmp/nanoclaw-docs-check.out 2>/dev/null; then
      echo "[docs-check] stale pattern '$pattern' found in $doc"
      cat /tmp/nanoclaw-docs-check.out
      FAILED=1
    fi
  done
done

if [[ $FAILED -ne 0 ]]; then
  echo "[docs-check] failed"
  exit 1
fi

echo "[docs-check] passed"
