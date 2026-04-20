# copilot-proxy

Dockerized [copilot-api-js](https://github.com/puxu-msft/copilot-api-js) reverse proxy that exposes GitHub Copilot's API as OpenAI/Anthropic compatible endpoints. Secured with Caddy reverse proxy (Bearer token auth + UI basic auth), with optional Dev Tunnel or Tailscale networking for remote device access.

## Quick Start

```powershell
# Full setup (generates tokens, OAuth login, configures Claude Code) (token + ui-password + login + setup-claude)
./copilotproxy.ps1 init

# Start the proxy (local only)
./copilotproxy.ps1 start
```

The proxy will be available at **http://localhost:4141**. UI is available at **http://localhost:4141/ui**.

## Quick Start - Remote Access

### Remote Option 1: Dev Tunnel

Dev Tunnel runs locally on your host machine and tunnels port 4141 to remote devices.

On host:
```powershell
./copilotproxy.ps1 devtunnel-auth        # One-time: login + create tunnel (saved to .env)
./copilotproxy.ps1 start                 # Start the proxy
./copilotproxy.ps1 devtunnel-start       # Host the tunnel in background
./copilotproxy.ps1 setup-claude-remote   # Start setup approval server
```

On remote device:
Install the devtunnel CLI (one-time):
- **Windows:** `winget install Microsoft.devtunnel`
- **macOS:** `brew install --cask devtunnel`
- **Linux:** `curl -sL https://aka.ms/DevTunnelCliInstall | bash`

```sh
devtunnel connect <tunnel-id>   # Printed by devtunnel-start on host
```

This forwards localhost:4141 on the remote device to the proxy.

Navigate to **http://localhost:4141/setup** for step-by-step instructions with copy buttons. Or run:
```sh
curl -s http://localhost:4141/setup.sh > claude-copilot-proxy.sh
cat claude-copilot-proxy.sh   # Review the script
sh claude-copilot-proxy.sh    # Run it
```

Approve on the host machine when prompted.

### Remote Option 2: Tailscale

Tailscale runs as a sidecar container — the proxy container stays unprivileged.

On host:
```powershell
./copilotproxy.ps1 tailscale-auth        # One-time Tailscale login
./copilotproxy.ps1 tailscale-start       # Start with Tailscale sidecar
./copilotproxy.ps1 setup-claude-remote   # Start setup approval server
```

On remote device (must have [Tailscale installed](https://tailscale.com/download) and joined to the same tailnet):

Navigate to **http://copilot-proxy:4141/setup** for step-by-step instructions with copy buttons. Or run:
```sh
curl -s http://copilot-proxy:4141/setup.sh > claude-copilot-proxy.sh
cat claude-copilot-proxy.sh   # Review the script
sh claude-copilot-proxy.sh    # Run it
```

Approve on the host machine when prompted.

## Commands

### Setup

| Command | Description |
|---------|-------------|
| `init` | Full setup: token + ui-password + login + setup-claude |
| `login` | GitHub OAuth login (interactive device flow) |
| `token` | Generate proxy auth token (saved to .env) |
| `ui-password` | Set or change the UI basic auth password |
| `setup-claude` | Configure Claude Code to use this proxy |
| `setup-claude-remote` | Start approval server for remote device setup |

### Operations

| Command | Description |
|---------|-------------|
| `start` | Start the proxy locally (detached) |
| `stop` | Stop all containers |
| `restart` | Restart the proxy |
| `logs` | Tail container logs |
| `build` | Rebuild the container |

### Dev Tunnel (optional)

Dev Tunnel runs locally on the host (not in Docker). Requires the [devtunnel CLI](https://learn.microsoft.com/azure/developer/dev-tunnels/get-started) (`winget install Microsoft.devtunnel`).

| Command | Description |
|---------|-------------|
| `devtunnel-auth` | Login + create tunnel (saved to .env) |
| `devtunnel-start` | Host tunnel in background |
| `devtunnel-stop` | Stop the tunnel |
| `devtunnel-status` | Show tunnel status + tail logs |

### Tailscale (optional)

Tailscale runs as a separate sidecar container — the proxy container stays unprivileged.

| Command | Description |
|---------|-------------|
| `tailscale-auth` | Interactive Tailscale login |
| `tailscale-start` | Start proxy + Tailscale sidecar |
| `tailscale-stop` | Stop proxy + Tailscale sidecar |
| `tailscale-build` | Rebuild both containers |

## Security

copilot-api-js has no built-in authentication or access control — anyone who can reach it gets full access to your Copilot API. Caddy sits in front as a security layer to lock it down:

- **Bearer token auth** on all API endpoints (v1/models, chat/completions, etc.)
- **Basic auth** on UI, models, and history pages
- **CORS headers stripped** — copilot-api-js adds `Access-Control-Allow-Origin: *` by default; Caddy strips these headers to enforce same-origin policy, preventing any external website from making requests to your proxy
- **copilot-proxy binds to localhost** — only Caddy can reach it, not the network directly
- Health endpoint (`/health`) is unauthenticated for monitoring
- `/setup` serves a static instructions page (no credentials); `/setup.sh` only works when the approval server is running and requires interactive approval

### Remote Access Security

Both remote access options add a network-level authentication layer on top of Caddy's auth:

- **Dev Tunnel** — Tunnels are private by default: only the Microsoft/GitHub account that created the tunnel can `devtunnel connect` to it. Remote devices must authenticate with `devtunnel login` using the same account. Widening access (org/public) is **not allowed or endorsed by this project** — the proxy is intended for single-user access only. See [Dev Tunnel access control](https://learn.microsoft.com/en-us/azure/developer/dev-tunnels/access-control) for details.
- **Tailscale** — Only devices joined to your tailnet can reach the proxy. Tailscale uses WireGuard for encrypted point-to-point connections. No ports are exposed to the public internet. Sharing the proxy with others via Tailscale sharing or ACLs is **not allowed or endorsed by this project**.

## Architecture

```
┌─────────────────────────────────────────────────┐
│              shared network namespace            │
│                                                  │
│  ┌───────────────────────────────────────────┐   │
│  │ Caddy (reverse proxy)                     │   │
│  │ :4141 — Bearer auth, basic auth, CORS     │   │
│  │   /setup    → static HTML instructions    │   │
│  │   /setup.sh → setup-server (approval)     │   │
│  │   /*        → copilot-api-js              │   │
│  └───────────────────────────────────────────┘   │
│                                                  │
│  ┌───────────────────────────────────────────┐   │
│  │ copilot-api-js (bun)                      │   │
│  │ :4142 (localhost only, via Caddy)          │   │
│  └───────────────────────────────────────────┘   │
│                                                  │
│  ┌───────────────────────────────────────────┐   │
│  │ setup-server (ephemeral, on-demand)       │   │
│  │ :4143 — interactive device approval       │   │
│  │ serves remote-setup.sh after approval     │   │
│  └───────────────────────────────────────────┘   │
│                                                  │
│  ┌───────────────────────────────────────────┐   │  (optional)
│  │ tailscale sidecar (NET_ADMIN)             │   │
│  │ publishes :4141 to tailnet                │   │
│  └───────────────────────────────────────────┘   │
│                                                  │
│         devtunnel (runs on host, not Docker)     │  (optional)
│         tunnels :4141 to remote devices          │
└─────────────────────────────────────────────────┘
```

- **Caddyfile** — Reverse proxy config: Bearer auth, basic auth, CORS stripping, /setup routing
- **setup.html** — Static setup instructions page served by Caddy at /setup
- **Dockerfile** — Multi-stage build: clones and builds copilot-api-js at pinned commit
- **Dockerfile.tailscale** — Lightweight sidecar based on `tailscale/tailscale:v1.96.5`
- **docker-compose.yaml** — Local-only, no elevated privileges
- **docker-compose.tailscale.yaml** — Overlay that adds sidecar + `network_mode: service:tailscale`

## Configuration

Edit `config.yaml` to customize model overrides, rate limiting, timeouts, and more. See the [upstream config.example.yaml](https://github.com/puxu-msft/copilot-api-js/blob/main/config.example.yaml) for all options.

### Model Overrides

The default config upgrades model aliases:

```yaml
model_overrides:
  opus: claude-opus-4.6-1m
  haiku: claude-sonnet-4.6
  claude-haiku-4.5: claude-sonnet-4.6
```

## Why Docker?

Running in a container isolates npm/bun dependencies from your host machine, mitigating supply chain risks. The proxy handles your GitHub token — keeping that in an isolated container with no host filesystem access is a good security practice.

## Pre-built Images

Images are published to GHCR on every push to `main`:

```
ghcr.io/nathan815/copilot-proxy:latest
ghcr.io/nathan815/copilot-proxy-tailscale:latest
```
