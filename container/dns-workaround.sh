#!/bin/bash
# DNS workaround for statically-linked Swift binary in Apple Containers
# This script ensures DNS resolution works properly

# Copy host's resolv.conf if available
if [ -f /etc/resolv.conf ]; then
    cp /etc/resolv.conf /tmp/resolv.conf
    # Ensure it contains proper nameservers
    if ! grep -q "nameserver" /tmp/resolv.conf; then
        echo "nameserver 8.8.8.8" >> /tmp/resolv.conf
        echo "nameserver 8.8.4.4" >> /tmp/resolv.conf
    fi
fi

# Export environment for DNS
export RES_OPTIONS="timeout:5 attempts:3"

# Run the actual agent
exec /app/nanoclaw-agent "$@"
