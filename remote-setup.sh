#!/bin/sh
# Copilot Proxy Remote Setup
# All-in-one script: installs devtunnel, connects, configures Claude Code.
#
# Usage:
#   sh claude-copilot-proxy.sh                # Full setup (devtunnel + claude config)
#   sh claude-copilot-proxy.sh reconnect      # Restart devtunnel connect
#   sh claude-copilot-proxy.sh stop           # Stop devtunnel connect
#   sh claude-copilot-proxy.sh disable        # Remove claude proxy config

set -e

MODE="${1:-enable}"
PROXY_HOST="{{PROXY_HOST}}"
AUTH_TOKEN="{{AUTH_TOKEN}}"
DEVTUNNEL_ID="{{DEVTUNNEL_ID}}"

STATE_DIR="$HOME/.copilot-proxy"
PID_FILE="$STATE_DIR/devtunnel.pid"
LOG_FILE="$STATE_DIR/devtunnel.log"
CLAUDE_DIR="$HOME/.claude"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"

mkdir -p "$STATE_DIR"
mkdir -p "$CLAUDE_DIR"

# --- Devtunnel helpers ---

stop_devtunnel() {
    if [ -f "$PID_FILE" ]; then
        pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            echo "Stopped devtunnel wrapper (PID $pid)"
        else
            echo "devtunnel wrapper not running (stale PID $pid)"
        fi
        rm -f "$PID_FILE"
    fi
    # Also kill any lingering devtunnel connect for this tunnel
    if [ -n "$DEVTUNNEL_ID" ]; then
        pkill -f "devtunnel connect $DEVTUNNEL_ID" 2>/dev/null || true
    fi
}

start_devtunnel() {
    # Stop existing if running
    stop_devtunnel 2>/dev/null

    echo "Starting devtunnel connect (background, auto-reconnect)..."
    # Start devtunnel connect with watchdog that restarts on port forwarding failure
    (
        echo "[$(date)] Wrapper started (PID $$)" >> "$LOG_FILE"
        while true; do
            echo "[$(date)] Starting devtunnel connect $DEVTUNNEL_ID..." >> "$LOG_FILE"
            devtunnel connect "$DEVTUNNEL_ID" >> "$LOG_FILE" 2>&1 &
            dt_pid=$!
            echo "[$(date)] devtunnel connect PID: $dt_pid" >> "$LOG_FILE"
            # Watchdog: check port 4141 every 15s, restart if unreachable
            while kill -0 "$dt_pid" 2>/dev/null; do
                sleep 15
                if ! curl -s --connect-timeout 3 --max-time 5 http://127.0.0.1:4141/health >/dev/null 2>&1; then
                    echo "[$(date)] Port 4141 unreachable, restarting devtunnel..." >> "$LOG_FILE"
                    kill "$dt_pid" 2>/dev/null || true
                    wait "$dt_pid" 2>/dev/null || true
                    # Kill any lingering devtunnel processes for this tunnel
                    pkill -f "devtunnel connect $DEVTUNNEL_ID" 2>/dev/null || true
                    sleep 5
                    break
                fi
            done
            echo "[$(date)] devtunnel disconnected, reconnecting in 3s..." >> "$LOG_FILE"
            sleep 3
        done
    ) &
    echo $! > "$PID_FILE"
    echo "devtunnel connect running in background (PID $!)"
    echo "  Logs: $LOG_FILE"
    echo "  Stop: sh $0 stop"
    echo "  Reconnect: sh $0 reconnect"
    # Give it a moment to connect
    sleep 3
}

install_devtunnel() {
    if command -v devtunnel >/dev/null 2>&1; then
        echo "devtunnel CLI already installed."
        return
    fi

    echo "Installing devtunnel CLI..."
    case "$(uname -s)" in
        Darwin)
            if command -v brew >/dev/null 2>&1; then
                brew install --cask devtunnel
            else
                echo "Error: brew not found. Install devtunnel manually:"
                echo "  https://learn.microsoft.com/azure/developer/dev-tunnels/get-started"
                exit 1
            fi
            ;;
        Linux)
            curl -sL https://aka.ms/DevTunnelCliInstall | bash
            ;;
        *)
            echo "Error: unsupported OS. Install devtunnel manually:"
            echo "  https://learn.microsoft.com/azure/developer/dev-tunnels/get-started"
            exit 1
            ;;
    esac

    if ! command -v devtunnel >/dev/null 2>&1; then
        echo "Error: devtunnel installation failed."
        exit 1
    fi
    echo "devtunnel CLI installed."
}

login_devtunnel() {
    # Check if already logged in
    if devtunnel list >/dev/null 2>&1; then
        echo "Already logged in to devtunnel."
        return
    fi
    echo "Please log in to devtunnel (use the same account as the tunnel owner)..."
    devtunnel login
}

configure_claude() {
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
}

# --- Main ---

case "$MODE" in
    enable)
        if [ -n "$DEVTUNNEL_ID" ]; then
            echo "=== Copilot Proxy Remote Setup (Dev Tunnel) ==="
            echo ""
            install_devtunnel
            echo ""
            login_devtunnel
            echo ""
            start_devtunnel
            echo ""
        fi

        echo "Configuring Claude Code..."
        configure_claude
        echo ""
        echo "Done! Claude Code configured to use proxy at http://$PROXY_HOST"
        echo "Auth token saved to $SETTINGS_FILE"
        echo ""
        echo "Restart Claude Code for changes to take effect."
        ;;

    reconnect)
        if [ -z "$DEVTUNNEL_ID" ]; then
            echo "No devtunnel configured."
            exit 1
        fi
        start_devtunnel
        ;;

    stop)
        stop_devtunnel
        ;;

    disable)
        stop_devtunnel 2>/dev/null || true
        configure_claude
        echo ""
        echo "Done! Claude Code restored to direct Anthropic API."
        echo "Restart Claude Code for changes to take effect."
        ;;

    *)
        echo "Usage: sh $0 [enable|reconnect|stop|disable]"
        exit 1
        ;;
esac
