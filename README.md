# copilot-proxy

Dockerized [copilot-api-js](https://github.com/puxu-msft/copilot-api-js) reverse proxy that exposes GitHub Copilot's API as OpenAI/Anthropic compatible endpoints. Secured with Caddy reverse proxy (Bearer token auth + UI basic auth), with optional Tailscale networking for remote device access.

## Quick Start

```powershell
# Full setup (generates tokens, OAuth login, configures Claude Code)
.\copilotproxy.ps1 init

# Start the proxy (choose one)
.\copilotproxy.ps1 start            # Local only
# OR
.\copilotproxy.ps1 tailscale-auth   # One-time Tailscale login
.\copilotproxy.ps1 tailscale-start  # Start with Tailscale (accessible on tailnet)
```

Or run each step individually:

```powershell
.\copilotproxy.ps1 token         # Generate proxy auth token
.\copilotproxy.ps1 ui-password   # Set UI basic auth password
.\copilotproxy.ps1 login         # GitHub OAuth device flow
.\copilotproxy.ps1 setup-claude  # Configure Claude Code
.\copilotproxy.ps1 start         # Start the proxy (local only)
# OR
.\copilotproxy.ps1 tailscale-start  # Start with Tailscale (accessible on tailnet)
```

The proxy will be available at **http://localhost:4141** (or **http://copilot-proxy:4141** on your tailnet).

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
| `stop` | Stop all containers (proxy + tailscale) |
| `restart` | Restart the proxy |
| `logs` | Tail container logs |
| `build` | Rebuild the container |

### Tailscale (optional)

Tailscale runs as a separate sidecar container — the proxy container stays unprivileged.

| Command | Description |
|---------|-------------|
| `tailscale-auth` | Interactive Tailscale login |
| `tailscale-start` | Start proxy + Tailscale sidecar |
| `tailscale-stop` | Stop proxy + Tailscale sidecar |
| `tailscale-build` | Rebuild both containers |

## Security

- **Caddy reverse proxy** fronts copilot-api-js — all traffic goes through Caddy
- **Bearer token auth** on all API endpoints (v1/models, chat/completions, etc.)
- **Basic auth** on UI, models, and history pages
- **CORS headers stripped** to prevent browser-based token theft
- **copilot-proxy binds to localhost** in Tailscale mode (only Caddy can reach it)
- Health endpoint (`/health`) is unauthenticated for monitoring

## Remote Device Setup

Set up Claude Code on your other devices through the tailnet:

```powershell
# On your main machine — starts an interactive approval server
.\copilotproxy.ps1 setup-claude-remote
```

```sh
# On the remote device — waits for your approval
curl -s copilot-proxy:4143 | sh
```

The approval server shows the remote device's IP and hostname, and waits for your y/N confirmation before serving the setup script with credentials.

## Architecture

```
┌─────────────────────────────────────────────────┐
│              shared network namespace            │
│                                                  │
│  ┌───────────────────────────────────────────┐   │
│  │ Caddy (reverse proxy)                     │   │
│  │ :4141 — Bearer auth, basic auth, CORS     │   │
│  │        ↓                                  │   │
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
│  │ publishes :4141 and :4143 to tailnet      │   │
│  └───────────────────────────────────────────┘   │
└─────────────────────────────────────────────────┘
```

- **Caddyfile** — Reverse proxy config: Bearer auth, basic auth, CORS stripping
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
