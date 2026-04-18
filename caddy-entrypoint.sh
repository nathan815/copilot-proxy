#!/bin/sh
# Hash the UI password and inject into Caddyfile at startup
set -e

if [ -n "$UI_PASSWORD" ]; then
    HASH=$(caddy hash-password --plaintext "$UI_PASSWORD")
    export UI_PASSWORD_HASH="$HASH"
fi

exec caddy run --config /etc/caddy/Caddyfile
