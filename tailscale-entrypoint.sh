#!/bin/sh
set -e

TS_HOSTNAME="${TS_HOSTNAME:-copilot-proxy}"

tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscale/tailscaled.sock &
sleep 2

if [ "$1" = "auth" ]; then
  tailscale up --hostname="$TS_HOSTNAME"
  echo "Tailscale connected as $TS_HOSTNAME"
  exit 0
fi

# Default: connect and stay running as sidecar
if [ -n "$TS_AUTHKEY" ]; then
  tailscale up --authkey="$TS_AUTHKEY" --hostname="$TS_HOSTNAME"
else
  tailscale up --hostname="$TS_HOSTNAME"
fi

echo "Tailscale connected as $TS_HOSTNAME"

# Keep container alive
wait
