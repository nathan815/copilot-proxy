#!/bin/sh
set -e

case "$1" in
  auth)
    bun run dist/main.mjs auth
    ;;
  setup-claude-code)
    shift
    bun run dist/main.mjs setup-claude-code "$@"
    ;;
  start)
    shift
    exec bun run dist/main.mjs start "$@"
    ;;
  *)
    # Default to start if no recognized command
    exec bun run dist/main.mjs start "$@"
    ;;
esac
