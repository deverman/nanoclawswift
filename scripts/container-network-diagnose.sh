#!/usr/bin/env bash
set -euo pipefail

echo "[container-netcheck] Host default route:"
DEFAULT_ROUTE_IFACE="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}' || true)"
echo "  interface=${DEFAULT_ROUTE_IFACE:-unknown}"

echo "[container-netcheck] Host DNS summary (scutil --dns):"
scutil --dns 2>/dev/null | awk '
  /^resolver #/ { resolver=$0; next }
  /nameserver\[[0-9]+\]/ { print "  " resolver " -> " $0 }
' | head -n 12 || true

echo "[container-netcheck] Container resolver and outbound probe:"
container run --rm --dns 8.8.8.8 alpine/curl sh -lc '
  echo "  /etc/resolv.conf:"
  sed "s/^/    /" /etc/resolv.conf
  echo "  nslookup api.openai.com:"
  nslookup api.openai.com 2>/dev/null | sed -n "1,10p" | sed "s/^/    /" || true
  echo "  curl -4 https://api.openai.com/v1/models (5s timeout):"
  curl -4 -sS -m 5 -o /dev/null -w "    code=%{http_code} ip=%{remote_ip} err=%{errormsg}\n" https://api.openai.com/v1/models || true
'

if [[ "${DEFAULT_ROUTE_IFACE:-}" == utun* ]]; then
  cat <<'EOF'
[container-netcheck] NOTE: default route is utun* (likely Tailscale/other VPN tunnel).
  This can break container VM outbound egress on macOS even if host internet works.
  Runtime workaround in this repo:
    CONTAINER_LLM_RELAY_MODE=auto   (auto-enables on utun default route)
  Optional manual overrides:
    CONTAINER_LLM_RELAY_MODE=force|off
    CONTAINER_LLM_RELAY_DNS_SERVERS=1.1.1.1,8.8.8.8
EOF
fi

echo "[container-netcheck] done"
