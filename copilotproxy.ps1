param(
    [Parameter(Position = 0)]
    [string]$Command,

    [Parameter(Position = 1, ValueFromRemainingArguments)]
    [string[]]$ExtraArgs
)

$ErrorActionPreference = "Stop"
Push-Location $PSScriptRoot

try {
    switch ($Command) {
        "auth" {
            Write-Host "Starting GitHub OAuth + Tailscale login..."
            docker compose run --rm -it copilot-proxy auth
        }
        "start" {
            docker compose up -d @ExtraArgs
            Write-Host "Copilot proxy running at http://localhost:4141"
            $hostname = if ($env:TS_HOSTNAME) { $env:TS_HOSTNAME } else { "copilot-proxy" }
            Write-Host "Tailscale hostname: $hostname"
        }
        "stop" {
            docker compose down
        }
        "logs" {
            docker compose logs -f @ExtraArgs
        }
        "restart" {
            docker compose restart
        }
        "build" {
            docker compose build
        }
        default {
            Write-Host "copilotproxy - GitHub Copilot API proxy with Tailscale"
            Write-Host ""
            Write-Host "Usage: .\copilotproxy.ps1 <command>"
            Write-Host ""
            Write-Host "Commands:"
            Write-Host "  auth     Interactive setup: GitHub OAuth + Tailscale login (first-time)"
            Write-Host "  start    Start the proxy (detached)"
            Write-Host "  stop     Stop the proxy"
            Write-Host "  restart  Restart the proxy"
            Write-Host "  logs     Tail container logs"
            Write-Host "  build    Rebuild the container"
            Write-Host ""
            Write-Host "First-time setup:"
            Write-Host "  1. .\copilotproxy.ps1 build"
            Write-Host "  2. .\copilotproxy.ps1 auth     # opens browser for GitHub + Tailscale"
            Write-Host "  3. .\copilotproxy.ps1 start"
            Write-Host ""
            Write-Host "Proxy will be available at http://localhost:4141"
            Write-Host "and via Tailscale at http://copilot-proxy:4141"
            exit 1
        }
    }
} finally {
    Pop-Location
}
