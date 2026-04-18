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
    tailscale up --hostname="$TS_HOSTNAME"
  fi
}

case "$1" in
  auth)
    bun run dist/main.mjs auth
    ;;
  setup-claude-code)
    shift
    bun run dist/main.mjs setup-claude-code "$@"
    ;;
  tailscale-auth)
    start_tailscaled
    connect_tailscale
    echo "Tailscale connected as $TS_HOSTNAME"
    ;;
  tailscale-start)
    shift
    start_tailscaled
    connect_tailscale
    exec bun run dist/main.mjs start "$@"
    ;;
  start)
    shift
    exec bun run dist/main.mjs start "$@"
    ;;
  *)
    exec "$@"
    ;;
esac
