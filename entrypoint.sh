#!/bin/sh
set -e

# Start Tailscale daemon in the background
tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscale/tailscaled.sock &

# Wait for tailscaled to be ready
sleep 2

# Authenticate with Tailscale using the auth key
if [ -n "$TS_AUTHKEY" ]; then
  tailscale up --authkey="$TS_AUTHKEY" --hostname="${TS_HOSTNAME:-copilot-proxy}"
else
  echo "WARNING: No TS_AUTHKEY set. Tailscale will not connect."
fi

# If "auth" is passed as first arg, run the GitHub OAuth device flow
if [ "$1" = "auth" ]; then
  exec bun run dist/main.mjs auth
fi

# Start copilot-api (token is read from ~/.local/share/copilot-api/github_token)
exec bun run dist/main.mjs start "$@"
