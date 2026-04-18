# copilot-proxy

Dockerized [copilot-api-js](https://github.com/puxu-msft/copilot-api-js) reverse proxy that exposes GitHub Copilot's API as OpenAI/Anthropic compatible endpoints. Runs in an isolated container for supply chain safety, with optional Tailscale networking.

## Quick Start

```powershell
# 1. Authenticate with GitHub (interactive OAuth device flow)
.\copilotproxy.ps1 auth

# 2. Start the proxy
.\copilotproxy.ps1 start

# 3. Configure Claude Code to use the proxy
.\copilotproxy.ps1 setup-claude-code
```

The proxy will be available at **http://localhost:4141**.

## Commands

| Command | Description |
|---------|-------------|
| `auth` | GitHub OAuth login (interactive device flow) |
| `setup-claude-code` | Configure Claude Code to use this proxy |
| `start` | Start the proxy locally (detached) |
| `stop` | Stop the proxy |
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

## Architecture

```
┌─────────────────────────────────┐
│ copilot-proxy (unprivileged)    │
│ ┌─────────────────────────────┐ │
│ │ copilot-api-js (bun)        │ │
│ │ :4141                       │ │
│ └─────────────────────────────┘ │
└────────────┬────────────────────┘
             │ localhost:4141
             │
┌────────────┴────────────────────┐  (optional)
│ tailscale sidecar (NET_ADMIN)   │
│ shared network namespace        │
└─────────────────────────────────┘
```

- **Dockerfile** — Multi-stage build: clones and builds copilot-api-js, runtime has no Tailscale deps
- **Dockerfile.tailscale** — Lightweight sidecar based on `tailscale/tailscale`
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
