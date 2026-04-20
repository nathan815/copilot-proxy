#!/bin/sh
# Copilot Proxy Remote Setup
# Configures Claude Code on this device to use your proxy.
#
# Usage:
#   curl -s http://copilot-proxy:4141/setup | sh         # enable (default)
#   sh copilot-proxy-setup.sh disable                    # disable (restore direct Anthropic)

set -e

MODE="${1:-enable}"
PROXY_HOST="{{.Req.Host}}"
AUTH_TOKEN="{{placeholder "http.request.uri.query.token"}}"

CLAUDE_DIR="$HOME/.claude"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"

mkdir -p "$CLAUDE_DIR"

if command -v python3 >/dev/null 2>&1; then
    python3 -c "
import json, os

path = os.path.expanduser('$SETTINGS_FILE')
try:
    with open(path) as f:
        s = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    s = {}

s.setdefault('env', {})

if '$MODE' == 'disable':
    s['env'].pop('ANTHROPIC_BASE_URL', None)
    s['env'].pop('ANTHROPIC_AUTH_TOKEN', None)
else:
    s['env']['ANTHROPIC_BASE_URL'] = 'http://$PROXY_HOST'
    s['env']['ANTHROPIC_AUTH_TOKEN'] = '$AUTH_TOKEN'

with open(path, 'w') as f:
    json.dump(s, f, indent=2)
"
elif command -v node >/dev/null 2>&1; then
    node -e "
const fs = require('fs');
const path = '$SETTINGS_FILE'.replace('~', process.env.HOME);
let s = {};
try { s = JSON.parse(fs.readFileSync(path, 'utf8')); } catch {}
s.env = s.env || {};

if ('$MODE' === 'disable') {
    delete s.env.ANTHROPIC_BASE_URL;
    delete s.env.ANTHROPIC_AUTH_TOKEN;
} else {
    s.env.ANTHROPIC_BASE_URL = 'http://$PROXY_HOST';
    s.env.ANTHROPIC_AUTH_TOKEN = '$AUTH_TOKEN';
}

fs.mkdirSync(require('path').dirname(path), { recursive: true });
fs.writeFileSync(path, JSON.stringify(s, null, 2));
"
else
    echo "Error: python3 or node required" >&2
    exit 1
fi

echo ""
if [ "$MODE" = "disable" ]; then
    echo "Done! Claude Code restored to direct Anthropic API."
else
    echo "Done! Claude Code configured to use your proxy at http://$PROXY_HOST"
    echo "Auth token saved to $SETTINGS_FILE"
fi
echo ""
echo "Restart Claude Code for changes to take effect."
