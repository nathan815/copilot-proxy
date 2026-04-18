#!/bin/sh
set -e

TS_HOSTNAME="${TS_HOSTNAME:-copilot-proxy}"

start_tailscaled() {
  tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscale/tailscaled.sock &
  sleep 2
}

connect_tailscale() {
  if [ -n "$TS_AUTHKEY" ]; then
    tailscale up --authkey="$TS_AUTHKEY" --hostname="$TS_HOSTNAME"
  else
    # Interactive login — prints a URL for browser auth
    tailscale up --hostname="$TS_HOSTNAME"
  fi
}

case "$1" in
  auth)
    # Step 1: GitHub OAuth device flow
    echo "=== GitHub OAuth ==="
    bun run dist/main.mjs auth

    # Step 2: Tailscale interactive login
    echo ""
    echo "=== Tailscale Login ==="
    start_tailscaled
    connect_tailscale
    echo "Tailscale connected as $TS_HOSTNAME"
    ;;
  start)
    shift
    start_tailscaled
    connect_tailscale
    exec bun run dist/main.mjs start "$@"
    ;;
  *)
    exec "$@"
    ;;
esac
